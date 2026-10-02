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
  # exactly the expected published ports, not more (TLS syslog adds one)
  local expected=3
  [[ "${SYSLOG_TLS_ENABLED:-false}" == "true" ]] && expected=4
  [ "$(echo "$output" | wc -l)" -eq "${expected}" ]
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
  run curl -fsS -m 5 --cacert "${GRAYLOG_TLS_DIR:-${DATA_ROOT}/tls}/cert.pem" "https://127.0.0.1:${GRAYLOG_HTTP_PORT}/api/system/lbstatus"
  [ "$status" -eq 0 ]
}

@test "Graylog refuses plain HTTP on the web port" {
  run curl -fsS -m 5 "http://127.0.0.1:${GRAYLOG_HTTP_PORT}/api/system/lbstatus"
  [ "$status" -ne 0 ]
}

@test "web certificate is valid for at least GRAYLOG_TLS_CERT_DAYS minus 30 days" {
  local cert="${GRAYLOG_TLS_DIR:-${DATA_ROOT}/tls}/cert.pem"
  run openssl x509 -in "${cert}" -noout -checkend $(( (${GRAYLOG_TLS_CERT_DAYS:-3650} - 30) * 86400 ))
  [ "$status" -eq 0 ]
}

@test "TLS key and trust store are root:1100 0640 and readable inside the container" {
  local dir="${GRAYLOG_TLS_DIR:-${DATA_ROOT}/tls}"
  [ "$(stat -c '%u:%g %a' "${dir}/key.pem")" = "0:1100 640" ]
  [ "$(stat -c '%u:%g %a' "${dir}/cacerts.jks")" = "0:1100 640" ]
  run podman exec "${GRAYLOG_CONTAINER_NAME}" sh -c "test -r /etc/graylog-tls/key.pem && test -r /etc/graylog-tls/cacerts.jks"
  [ "$status" -eq 0 ]
}

@test "Graylog can call its own API over TLS (cluster endpoint proxied via publish URI)" {
  local dir="${GRAYLOG_TLS_DIR:-${DATA_ROOT}/tls}"
  local token; token="$(cat "${SECRETS_DIR}/api_token")"
  run curl -fsS -m 15 --cacert "${dir}/cert.pem" -u "${token}:token" "https://127.0.0.1:${GRAYLOG_HTTP_PORT}/api/cluster/inputstates"
  [ "$status" -eq 0 ]
  run podman logs --tail 2000 "${GRAYLOG_CONTAINER_NAME}"
  [[ "$output" != *"PKIX path building failed"* ]]
}

@test "TLS syslog port completes a verified handshake when SYSLOG_TLS_ENABLED=true" {
  [[ "${SYSLOG_TLS_ENABLED:-false}" == "true" ]] || skip "SYSLOG_TLS_ENABLED is not true"
  local cert="${GRAYLOG_TLS_DIR:-${DATA_ROOT}/tls}/cert.pem"
  run bash -c "timeout 5 openssl s_client -connect 127.0.0.1:${SYSLOG_TLS_PORT:-6514} -CAfile '${cert}' -verify_return_error </dev/null"
  [ "$status" -eq 0 ]
}

@test "TLS syslog port is not listening when SYSLOG_TLS_ENABLED=false" {
  [[ "${SYSLOG_TLS_ENABLED:-false}" == "false" ]] || skip "SYSLOG_TLS_ENABLED is true"
  run bash -c "ss -Htln 'sport = :${SYSLOG_TLS_PORT:-6514}' | grep -q ."
  [ "$status" -ne 0 ]
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

@test "firewalld allows the expected ports (as port rules, or rich rules when sources are restricted)" {
  local zone="${FIREWALL_ZONE:-}"
  if [[ -z "${zone}" ]]; then
    zone="$(cut -d'|' -f1 "${DATA_ROOT}/.manifest.firewall_rules" | head -1)"
  fi
  [[ -n "${zone}" ]] || zone="$(firewall-cmd --get-default-zone)"
  run firewall-cmd --zone="${zone}" --list-all
  [ "$status" -eq 0 ]
  if [[ -n "${FIREWALL_ALLOWED_SOURCES:-}" ]]; then
    [[ "$output" == *"port=\"${GRAYLOG_HTTP_PORT}\" protocol=\"tcp\" accept"* ]]
    [[ "$output" == *"port=\"${SYSLOG_TCP_PORT}\" protocol=\"tcp\" accept"* ]]
    [[ "$output" == *"port=\"${SYSLOG_UDP_PORT}\" protocol=\"udp\" accept"* ]]
  else
    [[ "$output" == *"${GRAYLOG_HTTP_PORT}/tcp"* ]]
    [[ "$output" == *"${SYSLOG_TCP_PORT}/tcp"* ]]
    [[ "$output" == *"${SYSLOG_UDP_PORT}/udp"* ]]
  fi
}

@test "login banner shows the web URL and the health/stop/start commands" {
  [ -f /etc/motd.d/90-graylog-stack ]
  grep -q "${GRAYLOG_HTTP_EXTERNAL_URI}" /etc/motd.d/90-graylog-stack
  grep -q "healthcheck.sh" /etc/motd.d/90-graylog-stack
  grep -q "systemctl stop graylog graylog-datanode mongodb" /etc/motd.d/90-graylog-stack
  grep -q "systemctl start graylog" /etc/motd.d/90-graylog-stack
}

@test "vm.max_map_count is persisted, not just runtime-set" {
  grep -rq "vm.max_map_count=262144" /etc/sysctl.d/
  [ "$(sysctl -n vm.max_map_count)" -ge 262144 ]
}
