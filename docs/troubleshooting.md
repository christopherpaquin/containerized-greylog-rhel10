# Troubleshooting

Always start with:

```bash
./healthcheck.sh
```

It pinpoints which layer (systemd unit, container health, SELinux, network, API, syslog port) is failing, without needing to guess.

## Service won't start

```bash
sudo systemctl status mongodb.service graylog-datanode.service graylog.service
sudo journalctl -u <service> -n 100 --no-pager
sudo podman logs <container-name>          # mongodb | graylog-datanode | graylog
sudo podman ps -a                           # check exit codes / restart loops
```

Common causes seen during development of this repo (already fixed here, documented for reference):

* **`Permission denied` in MongoDB/Data Node logs on a fresh bind mount** - the container's entrypoint runs as root briefly to `chown` the data directory before dropping privileges; if `DropCapability=ALL` is set without `AddCapability=CHOWN DAC_OVERRIDE FOWNER SETGID SETUID`, even uid 0 can't bypass file permission checks. Already handled in `quadlet/mongodb.container` and `quadlet/graylog-datanode.container`.
* **`/opt/java/openjdk/bin/java: Operation not permitted`** - Graylog's bundled JRE has a `cap_net_bind_service` file capability; with `NoNewPrivileges=true` and `DropCapability=ALL`, the kernel refuses to exec it unless that capability is explicitly added back (`AddCapability=NET_BIND_SERVICE` in `quadlet/graylog.container`), even though this deployment never binds a privileged port.
* **`Failed to enable unit: ... is transient or generated`** - Quadlet-generated units must never be `systemctl enable`d directly; their `[Install]` section is processed by the generator on every `daemon-reload`/boot. Use `systemctl start`/`restart` only (this is what `deploy.sh` does).

## Data Node stuck at "starting" / unhealthy

Data Node's status API (port 8999) serves plain HTTP before Graylog provisions its TLS certificate, then HTTPS-only afterward. If it seems stuck:

```bash
sudo podman logs graylog-datanode | tail -50
```

Look for `"security configuration is missing"` (normal, pre-provisioning - waiting on `graylog.service`) vs. a genuine OpenSearch startup failure (heap/memory issues, `vm.max_map_count` too low).

## Graylog API unreachable

```bash
curl -v http://127.0.0.1:9000/api/system/lbstatus
sudo ss -tlnp | grep 9000
sudo firewall-cmd --list-ports
```

## SELinux denials

```bash
sudo ausearch -m avc -ts recent
sudo sealert -a /var/log/audit/audit.log   # if setroubleshoot is installed
```

If a denial mentions one of this deployment's bind-mount paths, verify the fcontext rule and relabel:

```bash
sudo semanage fcontext -l | grep graylog-stack
sudo restorecon -Rv /var/lib/graylog-stack
```

## Inter-container DNS breaks after a firewalld reload

Symptom: containers were working, then after some firewalld change (a manual `firewall-cmd --reload`, or repeated `./deploy.sh`/`./uninstall.sh` cycles) MongoDB/Data Node connectivity fails with `Temporary failure in name resolution` or `No route to host` inside a container (e.g. `podman exec graylog getent hosts mongodb`), even though the containers themselves are still running.

Root cause: Podman's bridge interface for `graylog-net` has no firewalld zone by default on this platform. Traffic on a zone-less interface can be silently dropped/rejected once firewalld (re)evaluates its rules, which breaks aardvark-dns (container-name resolution) between containers on that bridge.

Fix: `deploy.sh` assigns the bridge interface to firewalld's `trusted` zone (both runtime and `--permanent`) as part of `step_firewall`. If you hit this on a deployment predating that fix, or after manual firewalld surgery:

```bash
iface="$(sudo podman network inspect graylog-net --format '{{.NetworkInterface}}')"
sudo firewall-cmd --zone=trusted --add-interface="${iface}"
sudo firewall-cmd --permanent --zone=trusted --add-interface="${iface}"
```

Or simply rerun `sudo ./deploy.sh` - it checks and reapplies this on every run.

## No syslog messages arriving

1. Confirm the input exists and is running: Graylog UI → System → Inputs, or `curl -u <token>:token http://127.0.0.1:9000/api/system/inputs`.
2. Confirm the port is actually listening: `sudo ss -tlnp | grep 1514` (TCP) / `sudo ss -ulnp | grep 1514` (UDP).
3. Confirm firewalld allows it: `sudo firewall-cmd --list-ports`.
4. Test locally first (bypasses network/firewall entirely): `logger -n 127.0.0.1 -P 1514 -T -t test "hello"`.
5. Check Graylog's own logs for parse errors: `sudo podman logs graylog | grep -i syslog`.

## Resetting a forgotten admin password

Secrets are delivered to containers as Podman secrets referenced *by name*, and `deploy.sh` deliberately never overwrites an existing Podman secret (that's what makes reruns non-rotating). So editing `.env` alone is not enough - the old secret must be removed first:

```bash
NEW_PASSWORD='choose-a-strong-password'
NEW_HASH="$(echo -n "${NEW_PASSWORD}" | sha256sum | cut -d' ' -f1)"

sudo podman secret rm graylog-stack-root-password-sha2
sed -i "s|^GRAYLOG_ROOT_PASSWORD_SHA2=.*|GRAYLOG_ROOT_PASSWORD_SHA2=${NEW_HASH}|" .env
sudo ./deploy.sh
sudo systemctl restart graylog.service   # secret value changed, but the unit file text didn't -
                                          # deploy.sh's change-detection only restarts on unit-file
                                          # changes, so a secret-only rotation needs an explicit restart
```
