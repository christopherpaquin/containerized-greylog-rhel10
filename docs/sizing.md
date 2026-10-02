# Sizing

Tested configuration: 4 vCPU, 7.5 GB RAM, 33 GB disk (RHEL 10.2 VM).

## Automatic heap sizing

If `GRAYLOG_SERVER_JAVA_OPTS` / `DATANODE_OPENSEARCH_HEAP` are left blank in `.env`, `deploy.sh` detects total host RAM (`/proc/meminfo`) on first run and sizes them automatically, then persists the result back into `.env` so reruns reuse it (safe to hand-edit afterward - once non-blank, deploy.sh never overwrites it):

* **`DATANODE_OPENSEARCH_HEAP`** - 50% of total RAM, capped at `31g` (the JVM compressed-oops ceiling). This matches Graylog's own published guidance and the heap-size warning Graylog's UI shows if Data Node is under-provisioned.
* **`GRAYLOG_SERVER_JAVA_OPTS`** - `-Xms<N> -Xmx<N>` where N is 25% of total RAM, capped at `4g`. Graylog's message processing is mostly buffer/journal-bound, not heap-bound, so it rarely benefits from more.

On the tested 7.5 GB VM this produces `DATANODE_OPENSEARCH_HEAP=3g` and `GRAYLOG_SERVER_JAVA_OPTS="-Xms1g -Xmx1g"` (1.875 GB floors to 1g under the whole-GB rounding `heap_size_for_ram_mb` in `scripts/lib.sh` uses).

Both heaps together are intentionally well under 100% of RAM, leaving headroom for MongoDB's WiredTiger cache, the OS, and container overhead.

## Before increasing retention or ingest volume

* **OpenSearch heap**: if Graylog's own "Data Node Heap Size Warning" reappears after a rerun (e.g. because you'd previously pinned a small value), clear `DATANODE_OPENSEARCH_HEAP` back to blank and rerun `./deploy.sh` to re-detect, or set it explicitly.
* **Disk**: index data grows with retention × ingest rate - see "Partition sizing for the bind mounts" in the [README](../README.md#partition-sizing-for-the-bind-mounts) for per-directory sizes and the formula. `healthcheck.sh` warns at 85% and fails at 95% on each filesystem holding a bind mount.
* **vCPU**: OpenSearch indexing/search and Graylog message processing both benefit from more cores under sustained load; 4 is a reasonable floor, not a ceiling.

## Changing heap sizes manually

Edit `GRAYLOG_SERVER_JAVA_OPTS` / `DATANODE_OPENSEARCH_HEAP` in `.env` (or blank them out to re-trigger auto-detection), then `sudo ./deploy.sh` - it detects the changed Quadlet content and restarts only the affected service.
