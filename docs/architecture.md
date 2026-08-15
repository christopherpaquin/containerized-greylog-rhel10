# Architecture deep dive

## Components and dependency ordering

```text
MongoDB  --->  Graylog Data Node  --->  Graylog
```

Each stage is gated on a real Podman health check, not a fixed `sleep`. The Quadlet units use `Notify=healthy`, which makes `systemctl start <unit>` block until the container's own `HealthCmd` reports healthy (or `TimeoutStartSec` is hit) - so `Requires=`/`After=` between the units in `quadlet/*.container` genuinely wait for readiness, not just "container process started."

* `mongodb.service` - `HealthCmd` runs `mongosh ... db.adminCommand('ping')` with the real credentials.
* `graylog-datanode.service` - see "TLS" below; the health check has to work in *both* the pre-TLS and post-TLS state, because Graylog (which provisions the TLS cert) itself depends on Data Node being healthy first.
* `graylog.service` - `HealthCmd` hits `/api/system/lbstatus`, Graylog's unauthenticated load-balancer status endpoint.

## Container user model

Bind-mount ownership must match each image's runtime UID/GID exactly, since these are rootful (system-level) Quadlets with no user-namespace remapping:

| Container | Image behavior | Host directory owner |
|---|---|---|
| MongoDB | Entrypoint starts as root, `chown`s the data dir, then drops to `mongodb` (uid/gid 999) via `gosu` | `999:999` |
| Data Node | Entrypoint starts as root, `chown`s the data dir, then drops via `setpriv` to uid/gid 999 (`GDN_USER`/`GDN_GROUP=graylog`) | `999:999` |
| Graylog | Image `USER graylog` (uid/gid 1100) - **runs as non-root from the very first process, never as root** | `1100:1100` |

Because MongoDB and Data Node briefly run as root during their entrypoint's chown step, their Quadlet units need `AddCapability=CHOWN DAC_OVERRIDE FOWNER SETGID SETUID` on top of `DropCapability=ALL` - otherwise `NoNewPrivileges`/dropped capabilities cause `Permission denied` even for uid 0, since Linux capabilities (not just the UID) gate that access.

Graylog's bundled JRE binary carries a `cap_net_bind_service` file capability (for binding privileged ports, unused here since every port here is >1024). With `NoNewPrivileges=true` set, the kernel refuses to `exec` a binary whose file capabilities would grant something the process doesn't already hold - so `AddCapability=NET_BIND_SERVICE` is required even though it's never exercised.

## TLS / certificate provisioning

Data Node needs TLS certificates for OpenSearch's HTTP/transport layers and its own status API. Graylog's `GRAYLOG_SELFSIGNED_STARTUP=true` (Graylog 6.2+) fully automates this: on first start, the Graylog server generates a self-signed CA, and MongoDB-mediated discovery pushes provisioning to Data Node automatically - no interactive preflight wizard, no manually-generated certs.

This creates a real ordering subtlety: Data Node's status API on port 8999 serves **plain HTTP before provisioning** and **HTTPS-only after** (once Graylog has issued its certificate). Since Graylog itself depends on Data Node being healthy before it can start (and therefore before it can provision Data Node's certs), Data Node's health check tries plain HTTP first and falls back to a TLS probe via `openssl s_client` (the image has no curl/wget, only bash + openssl):

```bash
(exec 3<>/dev/tcp/127.0.0.1/8999 && printf 'GET / HTTP/1.0\r\n\r\n' >&3 && head -1 <&3 | grep -qE '^HTTP/1\.[01] [0-9]{3}') \
  || (printf 'GET / HTTP/1.0\r\n\r\n' | timeout 5 openssl s_client -connect 127.0.0.1:8999 -quiet 2>/dev/null | grep -qE '^HTTP/1\.[01] [0-9]{3}')
```

A plain-HTTP-only check would deadlock (Data Node never "ready" once TLS kicks in); a TLS-only check would deadlock the other way (Data Node never provisioned because Graylog never gets to start). The hybrid check works throughout the container's lifecycle.

The default renewal policy is a 30-day automatic rotation. `deploy.sh` sets `certificate_lifetime` to 10 years (`DATANODE_CERT_LIFETIME=P3650D` in `.env`) via `PUT /api/system/cluster_config/org.graylog2.plugin.certificates.RenewalPolicy` after first boot - this is Graylog's generic cluster-config store (the same mechanism the Data Node preflight UI itself uses), keyed by the Java class name of the renewal policy config bean. Automatic renewal remains enabled, so a cert is still reissued if it's ever revoked or the CA changes.

## API automation identity

Graylog's built-in root user (`GRAYLOG_ROOT_USERNAME`, default `admin`) is a synthetic account with no real MongoDB-backed user ID - the personal access token API (`POST /api/users/{userId}/tokens/{name}`) requires a real 24-character hex user ID, which the root account doesn't have. `deploy.sh` therefore provisions a dedicated `graylog-stack-automation` user (Admin role) on first run using the one-time plaintext admin password, mints a token for *that* user, and stores the token (not the password) for all future runs. Token values are only ever returned at creation time - if the stored token is lost, `deploy.sh` mints a new one (using the admin password if still available) rather than trying to recover the old value.

## Why not a separate OpenSearch container

Graylog Data Node embeds and manages its own OpenSearch process - a standalone OpenSearch/Elasticsearch container is redundant and explicitly out of scope per this deployment's requirements. Data Node exposes the OpenSearch HTTP API on 9200 and transport on 9300, both internal-network-only.
