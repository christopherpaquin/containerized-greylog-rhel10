#!/usr/bin/env bats
# deploy -> uninstall -> deploy roundtrip: uninstall must remove
# deployment/config artifacts but preserve data and credentials by
# default, and a subsequent deploy must succeed cleanly on top of that.
#
# Run with: sudo bats tests/integration/02_uninstall_roundtrip.bats
# Destructive to the current deployment's systemd/firewall/SELinux config
# (though not its data) - do not run against an environment you need to
# keep undisturbed.

load 'test_helper'

setup() {
  require_root_or_skip
  [[ -f "${ENV_FILE}" ]] || skip ".env not present - run ./deploy.sh once first"
}

@test "baseline deploy succeeds and is healthy" {
  run "${REPO_ROOT}/deploy.sh"
  [ "$status" -eq 0 ]
}

@test "snapshot admin password hash and a real MongoDB-backed record before uninstall" {
  load_deployed_env
  echo "${GRAYLOG_ROOT_PASSWORD_SHA2}" > /tmp/graylog-stack-test-sha2-before.txt
  # A raw `ls` of the data dir is the wrong check here - MongoDB's
  # WiredTiger journal/lock files legitimately change across every
  # start/stop even with no application data change. Instead confirm a
  # real MongoDB-backed record (the automation user Graylog stores its
  # own users collection in) survives the round-trip.
  podman exec "${MONGODB_CONTAINER_NAME}" mongosh --quiet -u "${MONGO_INITDB_ROOT_USERNAME}" -p "${MONGO_INITDB_ROOT_PASSWORD}" \
    --authenticationDatabase admin graylog --eval "db.users.countDocuments({username: 'graylog-stack-automation'})" \
    > /tmp/graylog-stack-test-automation-user-count-before.txt
}

@test "uninstall.sh (default, data-preserving) succeeds" {
  run "${REPO_ROOT}/uninstall.sh" --yes
  [ "$status" -eq 0 ]
}

@test "uninstall removed the systemd units" {
  for unit in mongodb.service graylog-datanode.service graylog.service graylog-network.service; do
    run systemctl is-active --quiet "${unit}"
    [ "$status" -ne 0 ]
  done
}

@test "uninstall removed the Quadlet files" {
  [ ! -d "/etc/containers/systemd/graylog-stack" ]
}

@test "uninstall preserved the data directories" {
  load_deployed_env
  [ -d "${MONGODB_DB_DIR}" ]
  [ -n "$(ls -A "${MONGODB_DB_DIR}")" ]
}

@test "uninstall preserved generated Podman secrets" {
  run bash -c "podman secret exists graylog-stack-mongo-root-password"
  [ "$status" -eq 0 ]
}

@test "uninstall is idempotent (running it again does not error)" {
  run "${REPO_ROOT}/uninstall.sh" --yes
  [ "$status" -eq 0 ]
}

@test "redeploy after uninstall succeeds" {
  run "${REPO_ROOT}/deploy.sh"
  [ "$status" -eq 0 ]
}

@test "redeploy reuses the same admin password hash (no credential rotation)" {
  load_deployed_env
  run cat /tmp/graylog-stack-test-sha2-before.txt
  [ "$output" = "${GRAYLOG_ROOT_PASSWORD_SHA2}" ]
}

@test "redeploy reused the same MongoDB data (application-level record intact)" {
  load_deployed_env
  run podman exec "${MONGODB_CONTAINER_NAME}" mongosh --quiet -u "${MONGO_INITDB_ROOT_USERNAME}" -p "${MONGO_INITDB_ROOT_PASSWORD}" \
    --authenticationDatabase admin graylog --eval "db.users.countDocuments({username: 'graylog-stack-automation'})"
  [ "$status" -eq 0 ]
  before="$(cat /tmp/graylog-stack-test-automation-user-count-before.txt)"
  [ "${before}" -ge 1 ]
  [ "$output" = "${before}" ]
}

@test "final healthcheck after the roundtrip is HEALTHY" {
  run "${REPO_ROOT}/healthcheck.sh"
  [ "$status" -eq 0 ]
  [[ "$output" == *"Overall status: HEALTHY"* ]]
}

@test "cleanup: remove uninstall-roundtrip test scratch files" {
  rm -f /tmp/graylog-stack-test-sha2-before.txt /tmp/graylog-stack-test-automation-user-count-before.txt
}
