#!/usr/bin/env bats
# Validates a system that has already been deployed via ./deploy.sh.
# Precondition: `sudo ./deploy.sh` has completed successfully.
# Run with: sudo bats tests/integration/00_deployed_system.bats

load 'test_helper'

setup() {
  require_root_or_skip
  load_deployed_env
}

@test "all four systemd units are active" {
  for unit in graylog-network.service mongodb.service graylog-datanode.service graylog.service; do
    run systemctl is-active --quiet "${unit}"
    [ "$status" -eq 0 ]
  done
}

@test "no stack unit is in a failed state" {
  for unit in graylog-network.service mongodb.service graylog-datanode.service graylog.service; do
    run systemctl is-failed --quiet "${unit}"
    [ "$status" -ne 0 ]
  done
}

@test "all three containers are running" {
  for name in "${MONGODB_CONTAINER_NAME}" "${DATANODE_CONTAINER_NAME}" "${GRAYLOG_CONTAINER_NAME}"; do
    run bash -c "podman inspect -f '{{.State.Running}}' '${name}'"
    [ "$output" = "true" ]
  done
}

@test "all three containers report podman-healthy" {
  for name in "${MONGODB_CONTAINER_NAME}" "${DATANODE_CONTAINER_NAME}" "${GRAYLOG_CONTAINER_NAME}"; do
    run bash -c "podman inspect -f '{{.State.Health.Status}}' '${name}'"
    [ "$output" = "healthy" ]
  done
}

@test "the dedicated Podman network exists and is bridge-mode" {
  run podman network exists "${NETWORK_NAME}"
  [ "$status" -eq 0 ]
  run bash -c "podman network inspect '${NETWORK_NAME}' --format '{{.Driver}}'"
  [ "$output" = "bridge" ]
}

@test "MongoDB is not published to the host" {
  run bash -c "podman port ${MONGODB_CONTAINER_NAME}"
  [ -z "$output" ]
}

@test "Data Node is not published to the host" {
  run bash -c "podman port ${DATANODE_CONTAINER_NAME}"
  [ -z "$output" ]
}

@test "Graylog publishes exactly web + syslog tcp + syslog udp" {
  run bash -c "podman port ${GRAYLOG_CONTAINER_NAME}"
  [[ "$output" == *"9000/tcp"* ]]
  [[ "$output" == *"1514/tcp"* ]]
  [[ "$output" == *"1514/udp"* ]]
  # exactly 3 published ports, not more
  [ "$(echo "$output" | wc -l)" -eq 3 ]
}

@test "bind mounts exist with correct ownership" {
  run bash -c "stat -c '%u:%g' '${MONGODB_DB_DIR}'"; [ "$output" = "999:999" ]
  run bash -c "stat -c '%u:%g' '${MONGODB_CONFIGDB_DIR}'"; [ "$output" = "999:999" ]
  run bash -c "stat -c '%u:%g' '${DATANODE_DATA_DIR}'"; [ "$output" = "999:999" ]
  run bash -c "stat -c '%u:%g' '${GRAYLOG_DATA_DIR}'"; [ "$output" = "1100:1100" ]
}

@test "bind mounts carry container_file_t SELinux context" {
  for d in "${MONGODB_DB_DIR}" "${MONGODB_CONFIGDB_DIR}" "${DATANODE_DATA_DIR}" "${GRAYLOG_DATA_DIR}"; do
    run bash -c "stat -c '%C' '${d}'"
    [[ "$output" == *container_file_t* ]]
  done
}

@test "persistent storage actually has data (not empty bind mounts)" {
  [ -n "$(ls -A "${MONGODB_DB_DIR}")" ]
  [ -n "$(ls -A "${GRAYLOG_DATA_DIR}")" ]
}

@test "SELinux is Enforcing" {
  run getenforce
  [ "$output" = "Enforcing" ]
}

@test "Graylog HTTP API responds (lbstatus)" {
  run curl -fsS -m 5 "http://127.0.0.1:${GRAYLOG_HTTP_PORT}/api/system/lbstatus"
  [ "$status" -eq 0 ]
}

@test "Syslog TCP port is listening" {
  run bash -c "ss -Htln 'sport = :${SYSLOG_TCP_PORT}' | grep -q ."
  [ "$status" -eq 0 ]
}

@test "Syslog UDP port is listening" {
  run bash -c "ss -Huln 'sport = :${SYSLOG_UDP_PORT}' | grep -q ."
  [ "$status" -eq 0 ]
}

@test "MongoDB is reachable from inside the network by container name" {
  run podman exec "${GRAYLOG_CONTAINER_NAME}" bash -c "exec 3<>/dev/tcp/${MONGODB_CONTAINER_NAME}/27017"
  [ "$status" -eq 0 ]
}

@test "Data Node is reachable from Graylog's network by container name" {
  run podman exec "${GRAYLOG_CONTAINER_NAME}" bash -c "exec 3<>/dev/tcp/${DATANODE_CONTAINER_NAME}/9200"
  [ "$status" -eq 0 ]
}

@test "firewalld has exactly the three expected ports open (plus whatever pre-existed)" {
  run firewall-cmd --list-ports
  [[ "$output" == *"${GRAYLOG_HTTP_PORT}/tcp"* ]]
  [[ "$output" == *"${SYSLOG_TCP_PORT}/tcp"* ]]
  [[ "$output" == *"${SYSLOG_UDP_PORT}/udp"* ]]
}

@test "vm.max_map_count is persisted, not just runtime-set" {
  grep -rq "vm.max_map_count=262144" /etc/sysctl.d/
  [ "$(sysctl -n vm.max_map_count)" -ge 262144 ]
}
