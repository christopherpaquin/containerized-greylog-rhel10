# Backup considerations

Not automated by this repo - this documents a suggested approach.

## What to back up, in priority order

1. **`.env`** - contains generated secrets. Without it (and without a MongoDB backup), the admin password can still be reset (see [troubleshooting.md](troubleshooting.md)), but the Data Node/Graylog password secret (`GRAYLOG_PASSWORD_SECRET`) cannot - losing it invalidates all existing user sessions and any values encrypted with it.
2. **MongoDB** (`/var/lib/graylog-stack/mongodb`) - cluster configuration, users, roles, streams, dashboards, alert definitions, input definitions. Small, changes infrequently, cheap to back up often.
3. **Data Node** (`/var/lib/graylog-stack/datanode`) - the actual log index data. Largest and fastest-growing directory; back up per your retention/compliance requirements.
4. **TLS** (`/var/lib/graylog-stack/tls`) - the web UI/API certificate and key. Tiny; restoring it avoids re-distributing a new certificate to every client that trusts the old one. Ownership is `root:1100` (`deploy.sh` re-asserts it).
5. **Graylog** (`/var/lib/graylog-stack/graylog`) - node ID (matters for cluster identity) and journal (transient in-flight messages - not critical to back up).

## Consistent backups

### Filesystem-level (simplest)

Stop the stack, snapshot/copy, restart:

```bash
sudo systemctl stop graylog.service graylog-datanode.service mongodb.service
sudo tar -czf /backup/graylog-stack-$(date +%F).tar.gz -C /var/lib graylog-stack
sudo systemctl start mongodb.service graylog-datanode.service graylog.service
# or simply: sudo ./deploy.sh (idempotent, brings everything back up)
```

Causes an outage for the duration of the copy - fine for small deployments, not ideal for anything latency-sensitive.

### Native tooling (no outage)

* **MongoDB**: `podman exec mongodb mongodump --authenticationDatabase admin -u <user> -p <password> --archive` piped to a file, or use `mongodump`'s native scheduling.
* **OpenSearch (via Data Node)**: use OpenSearch's snapshot API (`_snapshot`) against a repository mounted into the Data Node container - requires adding a snapshot repository path as an additional bind mount, which this POC does not configure by default. See Graylog's Data Node documentation for the exact settings if you need online, non-disruptive index backups.

## Restore

Stop the stack, restore the backed-up `DATA_ROOT` tree (and `.env` if it was lost) with matching ownership (`999:999` for `mongodb`/`datanode`, `1100:1100` for `graylog` - `deploy.sh` will also re-assert this on the next run), then `sudo ./deploy.sh`.
