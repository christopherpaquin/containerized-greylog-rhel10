# SELinux

This deployment keeps SELinux **Enforcing** for its entire lifecycle. `deploy.sh` checks `getenforce` and refuses to proceed if it's anything other than `Enforcing` - it never calls `setenforce 0`, and never adds a policy module that broadly weakens confinement.

## Bind mounts

Every host directory bind-mounted into a container gets:

1. A **persistent fcontext rule**, applied via `semanage fcontext -a -t container_file_t "<path>(/.*)?"` and `restorecon -Rv <path>` (`scripts/lib.sh:selinux_label_path`). This survives across reboots and `restorecon` runs triggered by anything else on the system - unlike Podman's own `:Z`/`:z` volume-suffix relabeling, which is applied by Podman at container start but isn't recorded as a persistent policy rule.
2. The `:Z` suffix on the `Volume=` line in each Quadlet unit, so Podman also relabels the mount at container start (belt-and-suspenders with #1). `:Z` (not `:z`) is used because each host directory is bind-mounted into exactly one container - none of them are shared between containers, so a private (non-shared) label is correct.

The TLS directory (`/var/lib/graylog-stack/tls`) is covered by the same rule and is mounted `:ro,Z` into the Graylog container only.

`uninstall.sh` removes exactly the fcontext rule this deployment added (`semanage fcontext -d`), and nothing else.

## Why not just `:Z` alone

`:Z` handles labeling for **that specific mount into that specific container** at the moment `podman run`/Quadlet starts it. `semanage fcontext` records the rule in SELinux's persistent policy database, so:

* `restorecon` run by anything else (a system-wide relabel, another tool) won't undo it
* the correct context is documented in policy, not just applied ad hoc
* removing the deployment (`uninstall.sh`) can cleanly remove exactly the rule it added

## Verifying

```bash
sudo semanage fcontext -l | grep graylog-stack
ls -Zd /var/lib/graylog-stack/*
getenforce
sudo ausearch -m avc -ts recent | grep -i graylog
```

`healthcheck.sh` runs all of the above (or `journalctl -k` fallback if `ausearch`/`audit` isn't installed) and reports `[FAIL]` if SELinux isn't Enforcing or an AVC denial mentioning this deployment's paths/containers is found.

## Custom policy

None is used. No custom SELinux policy module was required for this deployment - `container_file_t` (from the stock `container-selinux` policy, already required by Podman itself) is sufficient for every bind mount. If a future change genuinely requires a custom policy, keep it as narrowly scoped as possible and document the specific denial it resolves here.
