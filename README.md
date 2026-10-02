# containerized-graylog-rhel10

![RHEL 10](https://img.shields.io/badge/RHEL-10-EE0000?logo=redhat&logoColor=white)
![Podman](https://img.shields.io/badge/Podman-Quadlets-892CA0?logo=podman&logoColor=white)
![Graylog](https://img.shields.io/badge/Graylog-7.1-2E7D32)
![SELinux](https://img.shields.io/badge/SELinux-Enforcing-0066CC)
![Bash](https://img.shields.io/badge/Shell-Bash-4EAA25?logo=gnubash&logoColor=white)

One-click deployment of a **Graylog centralized syslog server** on **RHEL 10**, using **Podman** and **systemd Quadlets** - no Docker, no Kubernetes, no Ansible. SELinux stays Enforcing throughout.

Built and validated as a proof-of-concept, with production-quality habits: a TLS-only web UI/API (self-signed certificate, valid 10 years), idempotent deployment, generated secrets that persist across reruns, host bind mounts with correct SELinux labels, and a real health check that submits a syslog message end-to-end and confirms it was indexed.

## Architecture

```text
Network Devices / Servers
        |
        v
Centralized Syslog Server (this host)
        |
        | TCP/UDP syslog :1514
        v
+---------------------------------------------------------+
|  RHEL 10 host (Podman, systemd Quadlets, SELinux)        |
|                                                            |
|  [MongoDB] <--- [Graylog Data Node] <--- [Graylog]        |
|   internal        internal              :9000 web/API TLS |
|   only            only                  :1514 tcp/udp     |
|                                                            |
|  dedicated bridge network "graylog-net"                   |
+---------------------------------------------------------+
```

* **Graylog** - web UI and REST API (HTTPS only), syslog inputs. The only component exposed to the host.
* **Graylog Data Node** - embeds OpenSearch; there is no separate OpenSearch/Elasticsearch container.
* **MongoDB** - cluster/config metadata store.
* MongoDB and Data Node are on the internal `graylog-net` network only - never published to the host.

Component versions are pinned in `.env` (not `:latest`) and were chosen from Graylog's [compatibility matrix](https://go2docs.graylog.org/current/downloading_and_installing_graylog/compatibility_matrix.htm): Graylog 7.1.7, Data Node 7.1.7, MongoDB 8.2.12.

See [docs/architecture.md](docs/architecture.md) for the certificate provisioning flow, container UID/GID model, and dependency ordering.

## Prerequisites

* RHEL 10 (or a 10.x derivative), registered with `subscription-manager` so `dnf` has AppStream/BaseOS repos
* Root or passwordless `sudo`
* SELinux **Enforcing** (the default; deploy.sh refuses to run otherwise)
* Outbound internet access to pull container images on first deploy

### VM sizing

| | Minimum | Recommended (tested) |
|---|---|---|
| vCPU | 2 | 4 |
| RAM | 4 GB | 8 GB |
| Disk | 20 GB | 40 GB+ (grows with retention - see "Partition sizing" below) |

This was built and tested on a 4 vCPU / 7.5 GB RAM / 33 GB disk VM. `deploy.sh` auto-detects total host RAM on first run and sizes `DATANODE_OPENSEARCH_HEAP` (~50% of RAM, capped at 31g) and `GRAYLOG_SERVER_JAVA_OPTS` (~25% of RAM, capped at 4g) accordingly, then persists the result in `.env` - see [docs/sizing.md](docs/sizing.md) for the reasoning and how to override it.

### Partition sizing for the bind mounts

Everything persistent lives in host directories under `DATA_ROOT` (`/var/lib/graylog-stack`), bind mounted into the containers. By default they all sit on whatever filesystem holds `/var/lib` - usually the root filesystem, which the log index will eventually fill. For anything beyond a throwaway test, put at least the Data Node directory on its own filesystem.

| Host path (bind mount) | Mounted in | What grows it | Suggested size |
|---|---|---|---|
| `/var/lib/graylog-stack/datanode` | Data Node | The log index (OpenSearch). Grows with ingest volume x retention. **The only one that gets big.** | See formula below; dedicated filesystem |
| `/var/lib/graylog-stack/graylog` | Graylog | Message journal (on-disk buffer when indexing falls behind), capped at 5 GB by Graylog's default | 10 GB |
| `/var/lib/graylog-stack/mongodb` (`db`, `configdb`) | MongoDB | Configuration, users, dashboards, streams. Slow growth | 5 GB |
| `/var/lib/graylog-stack/tls`, `secrets` | Graylog (tls only) | Nothing - certificate, key, trust store, admin password, API token | Negligible (under 1 MB); leave on the parent filesystem |
| `/var/lib/containers` (not a bind mount) | Podman | The three images, about 3.5 GB, roughly double during an upgrade | 15 GB |

**Sizing the Data Node filesystem**

```text
size = daily ingest (GB) x retention (days) x 1.3 / 0.8
```

* `1.3` - index overhead on top of raw log size (single node, no replicas).
* `/ 0.8` - OpenSearch stops allocating new shards at 85% full and switches indices to read-only at 95%, so plan to stay under 80%.
* Retention is set in Graylog, not by this repo: System -> Indices -> Default index set. Graylog 7's default keeps roughly 30-40 days.

| Daily ingest | 30 days | 90 days |
|---|---|---|
| 1 GB/day | 50 GB | 150 GB |
| 5 GB/day | 245 GB | 735 GB |
| 20 GB/day | 975 GB | 2.9 TB |

For scale: the test VM this was validated on, receiving only its own occasional test messages for seven weeks, used 2.9 GB in `datanode`, 457 MB in `mongodb`, under 1 MB in `graylog`, and 6.5 GB in `/var/lib/containers`.

**Using separate filesystems**

Create and mount them at the paths above **before the first `deploy.sh`**, with an `/etc/fstab` entry so they are there at boot. `deploy.sh` then sets ownership and SELinux labels on the mount points itself. Example with LVM and XFS:

```bash
sudo lvcreate -L 250G -n graylog_datanode vg_data
sudo mkfs.xfs /dev/vg_data/graylog_datanode
sudo mkdir -p /var/lib/graylog-stack/datanode
echo '/dev/vg_data/graylog_datanode /var/lib/graylog-stack/datanode xfs defaults,nofail 0 0' | sudo tee -a /etc/fstab
sudo mount /var/lib/graylog-stack/datanode
```

* Use XFS (the RHEL default). ext4 puts a `lost+found` directory in the root of the filesystem, which the data directories should not contain.
* Keep the mount points under `DATA_ROOT`. The `*_DIR` variables in `.env` can point elsewhere, but the persistent SELinux rule `deploy.sh` installs only covers `DATA_ROOT`.
* To move an existing deployment: stop the stack (`sudo systemctl stop graylog graylog-datanode mongodb`), copy the directory onto the new filesystem with `cp -a`, mount it at the same path, and rerun `sudo ./deploy.sh`.
* `healthcheck.sh` checks free space on every filesystem that holds one of these directories (warning at 85%, failing at 95%).

JVM heap sizing is covered in [docs/sizing.md](docs/sizing.md).

## Deploying

```bash
git clone <this-repo>
cd containerized-graylog-rhel10
cp .env.example .env      # review/edit values - see "Configuration" below
sudo ./deploy.sh
```

`deploy.sh` is safe to run repeatedly - it verifies the platform, installs required packages, configures persistent kernel/SELinux/firewall settings, creates bind mounts, generates secrets and the TLS certificate (once), pulls the pinned images, installs the Quadlet units, starts everything, and finishes by running `./healthcheck.sh` for you.

A first deploy takes several minutes (Data Node's embedded OpenSearch JVM startup dominates). Reruns after the images are cached are much faster.

## Configuration (`.env`)

All configurable values live in one file: `.env` (gitignored - never commit it). Copy `.env.example` to `.env` and adjust before deploying. It covers:

* image names/versions, container/network names
* bind-mount paths (`DATA_ROOT` and subdirectories)
* ports (`GRAYLOG_HTTP_PORT`, `SYSLOG_TCP_PORT`, `SYSLOG_UDP_PORT`)
* TLS: certificate lifetime and extra names (`GRAYLOG_TLS_CERT_DAYS`, `GRAYLOG_TLS_EXTRA_SANS`), optional TLS syslog (`SYSLOG_TLS_ENABLED`, `SYSLOG_TLS_PORT`)
* Graylog admin username, JVM heap sizes, timezone
* MongoDB database/username (password is generated)
* firewall: management toggle, zone, and allowed source addresses (`FIREWALL_ALLOWED_SOURCES`)

Secrets (`GRAYLOG_PASSWORD_SECRET`, `GRAYLOG_ROOT_PASSWORD_SHA2`, `MONGO_INITDB_ROOT_PASSWORD`) are generated by `deploy.sh` on first run if left blank, then written back into `.env` and reused on every subsequent run - **rerunning `deploy.sh` never rotates credentials.** The one-time plaintext initial admin password is written to `/var/lib/graylog-stack/secrets/admin_password.txt` (root-only, `0600`); save it and delete the file when you're done.

## TLS

The web UI and REST API are served over **HTTPS only**, on port 9000, using Graylog's own TLS support (no reverse proxy).

* On first run `deploy.sh` generates a self-signed RSA-4096 certificate and key under `/var/lib/graylog-stack/tls/`, valid for **10 years** (`GRAYLOG_TLS_CERT_DAYS=3650`). Reruns never rotate it.
* The certificate covers `localhost`, `127.0.0.1`, the host in `GRAYLOG_HTTP_EXTERNAL_URI`, this machine's short and fully-qualified hostname, and anything listed in `GRAYLOG_TLS_EXTRA_SANS`. Set those **before the first deploy**; `deploy.sh` refuses to continue if the external URI's host is not on the certificate.
* Browsers will warn until you trust the certificate. Copy `/var/lib/graylog-stack/tls/cert.pem` to clients that should trust it (`curl --cacert cert.pem https://<host>:9000/...`). Safari and other Apple clients reject TLS certificates valid for more than 825 days even when trusted - lower `GRAYLOG_TLS_CERT_DAYS` before the first deploy if that matters to you.
* To replace the certificate (new names, new lifetime, or after expiry): delete `cert.pem` and `key.pem` in that directory and rerun `sudo ./deploy.sh`. `healthcheck.sh` warns 30 days before expiry.

**Syslog over TLS is optional and off by default.** Set `SYSLOG_TLS_ENABLED=true` in `.env` and rerun `deploy.sh` to add a TLS syslog TCP input on `SYSLOG_TLS_PORT` (default 6514) using the same certificate. The plaintext 1514 TCP/UDP inputs stay available either way. Setting it back to `false` and rerunning removes the input, the published port and the firewall rule.

Details: [docs/architecture.md](docs/architecture.md#tls--certificate-provisioning).

## Exposed ports

| Port | Protocol | Purpose | Exposed? |
|---|---|---|---|
| 9000 | TCP | Graylog web UI / REST API (HTTPS) | Host (firewalld-managed) |
| 1514 | TCP | Syslog input (plaintext) | Host (firewalld-managed) |
| 1514 | UDP | Syslog input (plaintext) | Host (firewalld-managed) |
| 6514 | TCP | Syslog input (TLS) | Host, only when `SYSLOG_TLS_ENABLED=true` |
| 27017 | TCP | MongoDB | Internal network only |
| 9200/9300/8999 | TCP | Data Node (OpenSearch + status API) | Internal network only |

## Directory layout

```text
.
├── deploy.sh              # one-click idempotent deployment
├── healthcheck.sh          # post-deploy / anytime health report
├── uninstall.sh             # removes deployment artifacts (data preserved by default)
├── .env.example             # copy to .env and configure
├── quadlet/                 # systemd Quadlet unit templates (rendered by deploy.sh)
├── scripts/                 # shared bash helper libraries
├── docs/                    # deep-dive documentation
└── tests/
    ├── unit/                 # BATS - logic tests, no root/VM required
    └── integration/          # BATS - exercises a real deployed system, requires root
```

Persistent data lives outside the repo, under `DATA_ROOT` (default `/var/lib/graylog-stack`):

```text
/var/lib/graylog-stack/
├── mongodb/{db,configdb}   # owned 999:999
├── datanode/                # owned 999:999
├── graylog/                 # owned 1100:1100
├── tls/                     # root:1100 0750 (certificate, key, JVM trust store)
└── secrets/                 # root-only (admin password, API token)
```

## Health checking

```bash
./healthcheck.sh
```

Checks Podman/systemd/container state, bind-mount ownership and SELinux labels, the TLS certificate (present, not expired, covers the external hostname, HTTPS verifies, plain HTTP refused), SELinux enforcing status and recent AVC denials, disk capacity, restart counts, Graylog's HTTP API, and both syslog ports - then performs an actual **end-to-end test**: sends a uniquely-tagged message over TCP and UDP with `logger`, and confirms via the Graylog search API that both were indexed. Exits non-zero if anything critical fails.

## Operator notes on the host

`deploy.sh` prints a short reference at the end of every run and installs the same text as a login banner (`/etc/motd.d/90-graylog-stack`), so anyone who SSHes to the box to troubleshoot sees the web UI URL, how to check health, and how to stop, start and restart the stack. It contains no secrets, and `uninstall.sh` removes it.

## systemd management

Everything runs as ordinary systemd services (MongoDB → Data Node → Graylog, in that dependency order, gated on real Podman health checks - not `sleep`):

```bash
systemctl status mongodb.service graylog-datanode.service graylog.service
journalctl -u graylog.service -f
podman ps
podman logs graylog-datanode
```

Services are enabled for boot automatically (Quadlet units carry their own `[Install]` section, refreshed by the generator on every `daemon-reload`/boot - don't `systemctl enable` them manually, it will error with "transient or generated").

## Troubleshooting

* `./healthcheck.sh` first - it pinpoints which layer is unhealthy.
* `sudo journalctl -u <service> -n 100 --no-pager` for the failing service.
* `sudo podman logs <container>` for application-level errors (Java stack traces, OpenSearch startup issues).
* `sudo ausearch -m avc -ts recent` if healthcheck flags an SELinux denial.

More detail: [docs/troubleshooting.md](docs/troubleshooting.md).

## Upgrades

Bump `GRAYLOG_VERSION` / `DATANODE_VERSION` / `MONGODB_VERSION` in `.env` (check the [compatibility matrix](https://go2docs.graylog.org/current/downloading_and_installing_graylog/compatibility_matrix.htm) first), then:

```bash
sudo ./deploy.sh
```

`deploy.sh` pulls the new images, re-renders only the units that changed, and restarts just those services - bind-mounted data is untouched.

## Uninstalling

```bash
sudo ./uninstall.sh              # removes services/config; DATA IS PRESERVED
sudo ./uninstall.sh --purge-data # also deletes all data + secrets (prompts for confirmation)
sudo ./uninstall.sh --purge-data --yes  # non-interactive purge
```

By default, uninstall removes Quadlet units, the Podman network, firewalld rules and sysctl/SELinux config it created - but leaves `/var/lib/graylog-stack` (data + generated secrets) untouched, so a subsequent `./deploy.sh` picks up exactly where you left off with the same credentials. `--purge-data` additionally deletes `/var/lib/graylog-stack` (data, certificate, generated secrets) and blanks the generated credentials in `.env`, so the next `deploy.sh` is a genuinely fresh install with a new admin password and certificate. Packages installed by `deploy.sh` are never removed automatically (shared system state); `uninstall.sh` reports what it installed so you can remove them yourself if desired.

## SELinux

SELinux stays **Enforcing** for the entire lifecycle - `deploy.sh` refuses to proceed otherwise, and never calls `setenforce 0`. Bind mounts get a persistent `container_file_t` context via `semanage fcontext` + `restorecon` (not just the `:Z` relabel-on-start Podman does automatically). See [docs/selinux.md](docs/selinux.md).

## Firewall

`deploy.sh` opens exactly three ports in firewalld: `9000/tcp`, `1514/tcp`, `1514/udp` - plus `6514/tcp` while `SYSLOG_TLS_ENABLED=true`. MongoDB and Data Node are never opened - they aren't published to the host at all. Set `MANAGE_FIREWALL=false` in `.env` to manage rules yourself.

* **Zone:** rules go into the zone of the interface carrying the default route (not blindly firewalld's default zone). Override with `FIREWALL_ZONE`.
* **Who can connect:** by default any source. Set `FIREWALL_ALLOWED_SOURCES` to a comma-separated list of addresses/CIDRs (e.g. `10.20.0.0/16,192.168.5.10`) and rerun `deploy.sh` to allow only those. The list applies to the web UI and all syslog ports alike; connections from the host itself are always allowed.
* **How the restriction is enforced:** firewalld rules alone cannot limit who reaches a Podman-published port - Podman forwards those ports with DNAT, and firewalld accepts DNAT'ed traffic before it looks at any zone, port or rich rule. So when a source list is set, `deploy.sh` also installs a small nftables table (`inet graylog_stack`, loaded at boot by `graylog-stack-source-filter.service`) that drops traffic to the published ports from anyone not on the list, before the DNAT happens. Clearing the list removes it again. This is not a host-wide firewalld setting and does not affect other containers on the host.
* **Ownership:** `deploy.sh` records each rule it adds (`/var/lib/graylog-stack/.manifest.firewall_rules`). Reruns and `uninstall.sh` remove only those; a rule that was already there is left alone. If such a pre-existing rule leaves a port open to everyone while you have a source list set, `deploy.sh` warns and prints the command to remove it.

It also assigns the Podman bridge interface for `graylog-net` to firewalld's `trusted` zone. Without this, the bridge interface has no zone at all, and inter-container traffic (including aardvark-dns container-name resolution - MongoDB/Data Node reaching each other by hostname) silently breaks the next time anything reloads firewalld. This was found and fixed via live testing - see [docs/troubleshooting.md](docs/troubleshooting.md#inter-container-dns-breaks-after-a-firewalld-reload). External exposure is controlled solely by the explicit port mappings above, not by this zone assignment - trusting the bridge does not widen what's reachable from outside the host.

## Syslog forwarding examples

Test locally with `logger` (TCP and UDP):

```bash
logger -n <graylog-host> -P 1514 -T -t test "hello over TCP"   # TCP
logger -n <graylog-host> -P 1514 -d -t test "hello over UDP"   # UDP
```

Example `rsyslog` config to forward from a centralized syslog server to Graylog (TCP preferred for reliability):

```text
# /etc/rsyslog.d/90-forward-to-graylog.conf
*.* action(type="omfwd" target="GRAYLOG_HOST" port="1514" protocol="tcp"
           action.resumeRetryCount="-1" queue.type="linkedList" queue.filename="graylog_fwd")
```

More examples (per-facility filtering, TLS-wrapped forwarding): [docs/syslog-forwarding.md](docs/syslog-forwarding.md).

## Backup considerations

* **MongoDB** (`/var/lib/graylog-stack/mongodb`) holds cluster config, users, dashboards, streams, and input definitions - back this up.
* **Data Node** (`/var/lib/graylog-stack/datanode`) holds the actual log index data - back this up per your retention/compliance requirements; it's the largest and fastest-growing directory.
* **Graylog** (`/var/lib/graylog-stack/graylog`) holds the node ID and journal - the journal is transient (in-flight messages), the node ID matters for cluster identity.
* **TLS** (`/var/lib/graylog-stack/tls`) holds the web certificate and key - small; back it up so clients that already trust the certificate keep working after a restore.
* **`.env`** contains generated secrets - losing it without a MongoDB backup means credentials can't be recovered (though the admin password can be reset via `GRAYLOG_ROOT_PASSWORD_SHA2`).

Stop the relevant service before a filesystem-level backup for consistency, or use each component's native backup tooling (`mongodump`, OpenSearch snapshots via Data Node). Not automated by this repo - see [docs/backup.md](docs/backup.md) for a suggested approach.

## Testing

```bash
bats tests/unit/                                # logic tests, any machine
sudo bats tests/integration/00_deployed_system.bats   # requires a live deployment
sudo bats tests/integration/01_idempotency.bats        # runs deploy.sh twice
sudo bats tests/integration/02_uninstall_roundtrip.bats # deploy/uninstall/deploy
```

## Known limitations / future work

* **Certificates are self-signed.** The web UI/API certificate is generated by `deploy.sh`; supplying your own CA-issued certificate is not yet wired into `.env` (you can replace `cert.pem`/`key.pem` by hand - the key must be unencrypted PKCS#8 - and rerun `deploy.sh`). Data Node TLS uses Graylog's built-in `GRAYLOG_SELFSIGNED_STARTUP` CA, with its certificate lifetime set to 10 years via the renewal policy API. See [docs/architecture.md](docs/architecture.md#tls--certificate-provisioning).
* **Plaintext syslog stays enabled** on 1514 TCP/UDP even when TLS syslog is on, and the TLS input does not require client certificates.
* **Single-node only** - this POC targets one VM; Graylog/Data Node clustering across multiple nodes is out of scope.
* **Authentication backend**: currently Graylog's built-in user database only. **FreeIPA/IDM integration is planned future work** - Graylog supports LDAP/Active Directory authentication backends that can point at a FreeIPA/IDM server for centralized user logins; this has not yet been implemented here.
* No automated backup/snapshot scheduling (see "Backup considerations" above).
