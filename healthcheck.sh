#!/usr/bin/env bash
# Post-deployment health check for the Graylog stack.
# Prints [PASS]/[WARN]/[FAIL] lines and an overall status. Exits non-zero if
# any critical (FAIL) check fails. Safe to run any time, as often as you like.

set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/lib.sh
source "${SCRIPT_DIR}/scripts/lib.sh"

FAIL_COUNT=0
WARN_COUNT=0

pass() { printf '[PASS] %s\n' "$1"; }
warn() { printf '[WARN] %s\n' "$1"; WARN_COUNT=$((WARN_COUNT + 1)); }
fail() { printf '[FAIL] %s\n' "$1"; FAIL_COUNT=$((FAIL_COUNT + 1)); }

check() {
  # check <label> <critical:true|false> <command...>
  local label="$1" critical="$2"; shift 2
  if "$@" >/dev/null 2>&1; then
    pass "${label}"
    return 0
  fi
  if [[ "${critical}" == "true" ]]; then
    fail "${label}"
  else
    warn "${label}"
  fi
  return 1
}

# --- Podman ------------------------------------------------------------
check "Podman installed" true command -v podman

# --- .env / config present ----------------------------------------------
if [[ ! -f "${ENV_FILE}" ]]; then
  fail ".env present (run deploy.sh first)"
  echo
  echo "Overall status: NOT DEPLOYED"
  exit 1
fi
load_env
env_validate 2>/dev/null && pass ".env valid" || fail ".env valid"

# --- systemd units --------------------------------------------------------
UNITS=(graylog-network.service mongodb.service graylog-datanode.service graylog.service)
for unit in "${UNITS[@]}"; do
  check "systemd unit active: ${unit}" true systemctl is-active --quiet "${unit}"
done

for unit in "${UNITS[@]}"; do
  restarts="$(systemctl show -p NRestarts --value "${unit}" 2>/dev/null || echo 0)"
  if [[ "${restarts}" =~ ^[0-9]+$ ]] && [[ "${restarts}" -gt 0 ]]; then
    warn "restart count for ${unit} is ${restarts} (may indicate prior instability)"
  else
    pass "no unexpected restarts: ${unit}"
  fi
  if systemctl is-failed --quiet "${unit}" 2>/dev/null; then
    fail "${unit} is in a failed state"
  fi
done

# --- container running state ----------------------------------------------
for name in "${MONGODB_CONTAINER_NAME}" "${DATANODE_CONTAINER_NAME}" "${GRAYLOG_CONTAINER_NAME}"; do
  check "container running: ${name}" true bash -c "podman inspect -f '{{.State.Running}}' '${name}' | grep -q true"
done

# --- container health (podman healthcheck) --------------------------------
for name in "${MONGODB_CONTAINER_NAME}" "${DATANODE_CONTAINER_NAME}" "${GRAYLOG_CONTAINER_NAME}"; do
  status="$(podman inspect -f '{{.State.Health.Status}}' "${name}" 2>/dev/null || echo 'unknown')"
  if [[ "${status}" == "healthy" ]]; then
    pass "container health: ${name}"
  else
    fail "container health: ${name} (status=${status})"
  fi
done

# --- Podman network ---------------------------------------------------------
check "Podman network '${NETWORK_NAME}' present" true podman network exists "${NETWORK_NAME}"

# Cross-container DNS/connectivity (aardvark-dns) - this is the actual path
# Graylog/Data Node use to reach MongoDB by container name, and is known to
# silently break if the network's bridge interface loses its firewalld
# trusted-zone assignment (e.g. after an unrelated firewalld reload).
check "cross-container DNS + connectivity (graylog -> mongodb)" true \
  podman exec "${GRAYLOG_CONTAINER_NAME}" bash -c "exec 3<>/dev/tcp/${MONGODB_CONTAINER_NAME}/27017"

# --- Bind mounts: presence, ownership, permissions, SELinux label ---------
check_bind_mount() {
  local path="$1" uid="$2" gid="$3"
  [[ -d "${path}" ]] || { fail "bind mount exists: ${path}"; return; }
  local actual_uid actual_gid actual_ctx
  actual_uid="$(stat -c '%u' "${path}")"
  actual_gid="$(stat -c '%g' "${path}")"
  actual_ctx="$(stat -c '%C' "${path}" 2>/dev/null || echo '')"
  if [[ "${actual_uid}" != "${uid}" || "${actual_gid}" != "${gid}" ]]; then
    fail "ownership of ${path} is ${actual_uid}:${actual_gid}, expected ${uid}:${gid}"
  else
    pass "ownership correct: ${path} (${uid}:${gid})"
  fi
  if [[ "${actual_ctx}" == *container_file_t* ]]; then
    pass "SELinux label correct: ${path}"
  else
    fail "SELinux label on ${path} is '${actual_ctx}', expected container_file_t"
  fi
}
check_bind_mount "${MONGODB_DB_DIR}" 999 999
check_bind_mount "${MONGODB_CONFIGDB_DIR}" 999 999
check_bind_mount "${DATANODE_DATA_DIR}" 999 999
check_bind_mount "${GRAYLOG_DATA_DIR}" 1100 1100
check_bind_mount "${GRAYLOG_TLS_DIR}" 0 1100

# --- TLS certificate (web UI / API, and the TLS syslog input if enabled) ----
TLS_CERT="${GRAYLOG_TLS_DIR}/cert.pem"
TLS_KEY="${GRAYLOG_TLS_DIR}/key.pem"
TLS_TRUSTSTORE="${GRAYLOG_TLS_DIR}/cacerts.jks"
if [[ -s "${TLS_CERT}" && -s "${TLS_KEY}" && -s "${TLS_TRUSTSTORE}" ]]; then
  pass "TLS certificate, key and JVM trust store present"
  if cert_days_left="$(tls_cert_days_left "${TLS_CERT}" 2>/dev/null)"; then
    cert_not_after="$(openssl x509 -in "${TLS_CERT}" -noout -enddate | cut -d= -f2)"
    if (( cert_days_left <= 0 )); then
      fail "TLS certificate expired (${cert_not_after})"
    elif (( cert_days_left < 30 )); then
      warn "TLS certificate expires in ${cert_days_left} days (${cert_not_after})"
    else
      pass "TLS certificate valid for ${cert_days_left} more days (until ${cert_not_after})"
    fi
  else
    fail "TLS certificate ${TLS_CERT} could not be read"
  fi
  check "TLS key matches the certificate" true tls_key_matches_cert "${TLS_CERT}" "${TLS_KEY}"
  external_host="$(uri_host "${GRAYLOG_HTTP_EXTERNAL_URI}")"
  check "TLS certificate covers ${external_host} (GRAYLOG_HTTP_EXTERNAL_URI)" true tls_cert_covers_host "${TLS_CERT}" "${external_host}"
  for tls_file in "${TLS_KEY}" "${TLS_TRUSTSTORE}"; do
    tls_file_state="$(stat -c '%u:%g %a' "${tls_file}")"
    if [[ "${tls_file_state}" == "0:1100 640" ]]; then
      pass "ownership/mode correct: ${tls_file} (0:1100 640)"
    else
      fail "ownership/mode of ${tls_file} is ${tls_file_state}, expected 0:1100 640"
    fi
  done
  check "Graylog container user can read its TLS key and trust store" true \
    podman exec "${GRAYLOG_CONTAINER_NAME}" sh -c "test -r ${GRAYLOG_TLS_CONTAINER_DIR}/key.pem && test -r ${GRAYLOG_TLS_CONTAINER_DIR}/cacerts.jks"
else
  fail "TLS certificate, key and JVM trust store present under ${GRAYLOG_TLS_DIR} (run deploy.sh)"
fi

# --- SELinux enforcing + AVC denials ---------------------------------------
if [[ "$(getenforce)" == "Enforcing" ]]; then
  pass "SELinux enforcing"
else
  fail "SELinux is not Enforcing (found: $(getenforce))"
fi

avc_hits=""
if command -v ausearch >/dev/null 2>&1; then
  # --input-logs: without it ausearch reads stdin whenever stdin is a pipe
  # (ssh, cron, CI) and hangs forever waiting for input.
  avc_hits="$(ausearch --input-logs -m avc -ts recent 2>/dev/null </dev/null | grep -Ei "${DATA_ROOT}|${MONGODB_CONTAINER_NAME}|${DATANODE_CONTAINER_NAME}|${GRAYLOG_CONTAINER_NAME}" || true)"
else
  avc_hits="$(journalctl -k --since '10 min ago' 2>/dev/null | grep -i 'avc:.*denied' | grep -Ei "${DATA_ROOT}|container_t" || true)"
fi
if [[ -z "${avc_hits}" ]]; then
  pass "no recent SELinux AVC denials related to this deployment"
else
  fail "SELinux AVC denials detected (run: ausearch -m avc -ts recent)"
fi

# --- disk capacity -----------------------------------------------------------
# Each bind mount may be its own filesystem (see README "Partition sizing"),
# so check every distinct filesystem behind them, once each.
declare -A disk_seen=()
for disk_path in "${DATA_ROOT}" "${DATANODE_DATA_DIR}" "${GRAYLOG_DATA_DIR}" "${MONGODB_DB_DIR}" "${MONGODB_CONFIGDB_DIR}"; do
  [[ -d "${disk_path}" ]] || continue
  read -r disk_mount disk_use_pct < <(df -P "${disk_path}" | awk 'NR==2{gsub("%","",$5); print $6, $5}')
  [[ -z "${disk_seen[${disk_mount}]:-}" ]] || continue
  disk_seen["${disk_mount}"]=1
  if [[ "${disk_use_pct}" -ge 95 ]]; then
    fail "disk usage on ${disk_mount} (holds ${disk_path}) is ${disk_use_pct}% (critical)"
  elif [[ "${disk_use_pct}" -ge 85 ]]; then
    warn "disk usage on ${disk_mount} (holds ${disk_path}) is ${disk_use_pct}% (getting full)"
  else
    pass "disk usage on ${disk_mount} (holds ${disk_path}) is ${disk_use_pct}%"
  fi
done

# --- MongoDB / Data Node / Graylog readiness (podman healthcheck already
#     covers this; add a direct network-level confirmation too) -----------
check "MongoDB port reachable in-network" true podman exec "${MONGODB_CONTAINER_NAME}" mongosh --quiet -u "${MONGO_INITDB_ROOT_USERNAME}" -p "${MONGO_INITDB_ROOT_PASSWORD}" --authenticationDatabase admin --eval "db.adminCommand('ping')"
check "Data Node status endpoint reachable" true podman exec "${DATANODE_CONTAINER_NAME}" bash -c '(exec 3<>/dev/tcp/127.0.0.1/8999 && printf "GET / HTTP/1.0\r\n\r\n" >&3 && head -1 <&3 | grep -qE "^HTTP/1\.[01] [0-9]{3}") || (printf "GET / HTTP/1.0\r\n\r\n" | timeout 5 openssl s_client -connect 127.0.0.1:8999 -quiet 2>/dev/null | grep -qE "^HTTP/1\.[01] [0-9]{3}")'

# --- Graylog HTTP/API -----------------------------------------------------
check "Graylog HTTPS/API reachable and certificate verifies (lbstatus)" true curl -fsS -m 5 --cacert "${TLS_CERT}" "https://127.0.0.1:${GRAYLOG_HTTP_PORT}/api/system/lbstatus"
if curl -fsS -m 5 "http://127.0.0.1:${GRAYLOG_HTTP_PORT}/api/system/lbstatus" >/dev/null 2>&1; then
  fail "Graylog answers plain HTTP on ${GRAYLOG_HTTP_PORT} (expected TLS only)"
else
  pass "Graylog does not answer plain HTTP on ${GRAYLOG_HTTP_PORT}"
fi

# --- allowed-source filter ---------------------------------------------------
if [[ "${MANAGE_FIREWALL}" == "true" && -n "${FIREWALL_ALLOWED_SOURCES//[[:space:],]/}" ]]; then
  check "allowed-source filter loaded (FIREWALL_ALLOWED_SOURCES=${FIREWALL_ALLOWED_SOURCES})" true nft list table inet graylog_stack
  check "allowed-source filter enabled at boot" true systemctl is-enabled --quiet "${SOURCE_FILTER_UNIT_NAME}"
elif nft list table inet graylog_stack >/dev/null 2>&1; then
  fail "allowed-source filter is loaded but FIREWALL_ALLOWED_SOURCES is empty (rerun deploy.sh)"
fi

# --- Syslog ports listening -------------------------------------------------
check "Syslog TCP :${SYSLOG_TCP_PORT} listening" true bash -c "ss -Htln 'sport = :${SYSLOG_TCP_PORT}' | grep -q ."
check "Syslog UDP :${SYSLOG_UDP_PORT} listening" true bash -c "ss -Huln 'sport = :${SYSLOG_UDP_PORT}' | grep -q ."
if [[ "${SYSLOG_TLS_ENABLED}" == "true" ]]; then
  check "Syslog TLS :${SYSLOG_TLS_PORT} listening" true bash -c "ss -Htln 'sport = :${SYSLOG_TLS_PORT}' | grep -q ."
  check "Syslog TLS :${SYSLOG_TLS_PORT} presents the deployment certificate" true \
    bash -c "timeout 5 openssl s_client -connect 127.0.0.1:${SYSLOG_TLS_PORT} -CAfile '${TLS_CERT}' -verify_return_error </dev/null"
fi

# --- End-to-end syslog ingestion test ---------------------------------------
e2e_ingest_test() {
  local token_file="${SECRETS_DIR}/api_token"
  if [[ ! -f "${token_file}" ]]; then
    warn "end-to-end syslog ingestion test skipped (no stored API token; run deploy.sh to provision one)"
    return
  fi
  # shellcheck source=scripts/graylog-api.sh
  source "${SCRIPT_DIR}/scripts/graylog-api.sh"
  export GRAYLOG_API_USER GRAYLOG_API_PASS
  GRAYLOG_API_USER="$(cat "${token_file}")"
  GRAYLOG_API_PASS="token"

  if ! graylog_token_valid "${GRAYLOG_API_USER}"; then
    fail "stored API token is rejected by Graylog (expired or revoked) - rerun deploy.sh to mint a new one"
    return
  fi

  if ! command -v logger >/dev/null 2>&1; then
    warn "end-to-end syslog ingestion test skipped (logger command not available)"
    return
  fi

  # Drift between SYSLOG_TLS_ENABLED and what Graylog actually has configured.
  local tls_input_state
  if tls_input_state="$(graylog_input_tls_state "${SYSLOG_TLS_INPUT_TITLE}" 2>/dev/null)"; then
    if [[ "${SYSLOG_TLS_ENABLED}" == "true" ]]; then
      if [[ "${tls_input_state}" == "tls" ]]; then pass "TLS syslog input configured with TLS enabled"; else fail "SYSLOG_TLS_ENABLED=true but the '${SYSLOG_TLS_INPUT_TITLE}' input is ${tls_input_state} (rerun deploy.sh)"; fi
    else
      if [[ "${tls_input_state}" == "absent" ]]; then pass "no TLS syslog input configured (SYSLOG_TLS_ENABLED=false)"; else fail "SYSLOG_TLS_ENABLED=false but a '${SYSLOG_TLS_INPUT_TITLE}' input still exists (rerun deploy.sh)"; fi
    fi
  else
    fail "could not query Graylog inputs via the API"
  fi

  local marker tcp_ok=0 udp_ok=0 tls_ok=0
  marker="healthcheck-$(date +%s)-$$"

  logger -n 127.0.0.1 -P "${SYSLOG_TCP_PORT}" -T -t healthcheck "${marker}-tcp" 2>/dev/null || true
  logger -n 127.0.0.1 -P "${SYSLOG_UDP_PORT}" -d -t healthcheck "${marker}-udp" 2>/dev/null || true
  if [[ "${SYSLOG_TLS_ENABLED}" == "true" ]]; then
    # s_client -quiet keeps the connection open after stdin ends, so bound it.
    printf '<14>%s %s healthcheck: %s-tls\n' "$(date '+%b %e %H:%M:%S')" "$(hostname -s)" "${marker}" \
      | timeout 5 openssl s_client -connect "127.0.0.1:${SYSLOG_TLS_PORT}" -CAfile "${TLS_CERT}" -verify_return_error -quiet >/dev/null 2>&1 || true
  else
    tls_ok=1 # not applicable
  fi

  local waited=0 found=""
  while (( waited < 30 )); do
    found="$(graylog_curl GET "/search/universal/relative?query=${marker}&range=60&limit=10" 2>/dev/null || true)"
    if printf '%s' "${found}" | grep -q "${marker}-tcp"; then tcp_ok=1; fi
    if printf '%s' "${found}" | grep -q "${marker}-udp"; then udp_ok=1; fi
    if printf '%s' "${found}" | grep -q "${marker}-tls"; then tls_ok=1; fi
    if [[ ${tcp_ok} -eq 1 && ${udp_ok} -eq 1 && ${tls_ok} -eq 1 ]]; then break; fi
    sleep 3
    waited=$(( waited + 3 ))
  done

  if [[ ${tcp_ok} -eq 1 ]]; then pass "end-to-end syslog TCP ingestion verified"; else fail "end-to-end syslog TCP ingestion (test message not found in index within 30s)"; fi
  if [[ ${udp_ok} -eq 1 ]]; then pass "end-to-end syslog UDP ingestion verified"; else fail "end-to-end syslog UDP ingestion (test message not found in index within 30s)"; fi
  if [[ "${SYSLOG_TLS_ENABLED}" == "true" ]]; then
    if [[ ${tls_ok} -eq 1 ]]; then pass "end-to-end syslog TLS ingestion verified"; else fail "end-to-end syslog TLS ingestion (test message not found in index within 30s)"; fi
  fi
}
e2e_ingest_test

echo
if [[ ${FAIL_COUNT} -eq 0 ]]; then
  echo "Overall status: HEALTHY"
  [[ ${WARN_COUNT} -gt 0 ]] && echo "(${WARN_COUNT} non-critical warning(s) above)"
  exit 0
else
  echo "Overall status: UNHEALTHY (${FAIL_COUNT} critical failure(s), ${WARN_COUNT} warning(s))"
  exit 1
fi
