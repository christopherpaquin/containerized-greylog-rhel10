#!/usr/bin/env bats
# TLS helpers: SAN list building, self-signed certificate generation and
# lifetime, .env defaults/validation, and the Graylog Quadlet's TLS wiring.

load 'test_helper'

setup() {
  common_setup
  source "${REPO_ROOT}/scripts/lib.sh"
  ENV_FILE="${TEST_TMP}/.env"
  CERT="${TEST_TMP}/cert.pem"
  KEY="${TEST_TMP}/key.pem"
}

teardown() { common_teardown; }

write_valid_env() {
  cp "${REPO_ROOT}/.env.example" "${ENV_FILE}"
  chmod 600 "${ENV_FILE}"
}

# `! cmd` never fails a bats test on its own; this does.
refute() {
  if "$@"; then return 1; fi
}

generate_test_cert() {
  tls_generate_self_signed "${CERT}" "${KEY}" "${1:-3650}" "graylog.lab.example" \
    "DNS:localhost,IP:127.0.0.1,DNS:graylog.lab.example,IP:10.1.2.3"
}

@test "uri_host strips scheme, port and path" {
  [ "$(uri_host 'https://graylog.lab.example:9000/')" = "graylog.lab.example" ]
  [ "$(uri_host 'http://10.1.2.3:9000/')" = "10.1.2.3" ]
  [ "$(uri_host 'https://[fe80::1]:9000/')" = "fe80::1" ]
}

@test "tls_build_san_list classifies hosts and IPs, skips blanks, de-duplicates" {
  run tls_build_san_list localhost 127.0.0.1 "" graylog localhost 10.1.2.3 DNS:extra.example IP:10.1.2.3
  [ "$status" -eq 0 ]
  [ "$output" = "DNS:localhost,IP:127.0.0.1,DNS:graylog,IP:10.1.2.3,DNS:extra.example" ]
}

@test "generated certificate is valid for 10 years by default" {
  generate_test_cert
  # Still valid 3649 days from now, no longer valid 3651 days from now.
  openssl x509 -in "${CERT}" -noout -checkend $(( 3649 * 86400 ))
  refute openssl x509 -in "${CERT}" -noout -checkend $(( 3651 * 86400 ))
  days_left="$(tls_cert_days_left "${CERT}")"
  [ "${days_left}" -ge 3649 ]
}

@test ".env.example requests a 10-year certificate" {
  grep -q '^GRAYLOG_TLS_CERT_DAYS=3650$' "${REPO_ROOT}/.env.example"
}

@test "generated certificate honors a custom lifetime" {
  generate_test_cert 30
  openssl x509 -in "${CERT}" -noout -checkend $(( 29 * 86400 ))
  refute openssl x509 -in "${CERT}" -noout -checkend $(( 31 * 86400 ))
}

@test "generated key is unencrypted PKCS#8 and not readable by others" {
  generate_test_cert
  head -1 "${KEY}" | grep -q '^-----BEGIN PRIVATE KEY-----$'
  [ "$(stat -c '%a' "${KEY}")" = "600" ]
}

@test "generated key matches the certificate" {
  generate_test_cert
  [ "$(openssl x509 -in "${CERT}" -noout -pubkey | sha256sum)" = "$(openssl pkey -in "${KEY}" -pubout | sha256sum)" ]
}

@test "tls_key_matches_cert rejects a key from a different pair" {
  generate_test_cert
  tls_key_matches_cert "${CERT}" "${KEY}"
  openssl genpkey -algorithm RSA -pkeyopt rsa_keygen_bits:2048 -out "${TEST_TMP}/other.pem" 2>/dev/null
  refute tls_key_matches_cert "${CERT}" "${TEST_TMP}/other.pem"
}

@test "tls_cert_covers_host matches SAN names and IPs only" {
  generate_test_cert
  tls_cert_covers_host "${CERT}" graylog.lab.example
  tls_cert_covers_host "${CERT}" 10.1.2.3
  tls_cert_covers_host "${CERT}" 127.0.0.1
  refute tls_cert_covers_host "${CERT}" other.lab.example
  refute tls_cert_covers_host "${CERT}" 10.9.9.9
}

@test "tls_generate_self_signed leaves no partial files behind on failure" {
  run tls_generate_self_signed "${CERT}" "${KEY}" 3650 "x" "not-a-valid-san"
  [ "$status" -ne 0 ]
  [ ! -e "${CERT}" ]
  [ ! -e "${KEY}" ]
  [ ! -e "${CERT}.tmp" ]
  [ ! -e "${KEY}.tmp" ]
}

@test "load_env supplies TLS defaults for a .env written before they existed" {
  grep -vE '^(GRAYLOG_TLS_|SYSLOG_TLS_)' "${REPO_ROOT}/.env.example" > "${ENV_FILE}"
  chmod 600 "${ENV_FILE}"
  set -u
  load_env
  [ "${GRAYLOG_TLS_DIR}" = "${DATA_ROOT}/tls" ]
  [ "${GRAYLOG_TLS_CERT_DAYS}" = "3650" ]
  [ "${SYSLOG_TLS_ENABLED}" = "false" ]
  [ "${SYSLOG_TLS_PORT}" = "6514" ]
}

@test "TLS syslog is off by default in .env.example" {
  grep -q '^SYSLOG_TLS_ENABLED=false$' "${REPO_ROOT}/.env.example"
}

@test "env_validate rejects a SYSLOG_TLS_ENABLED value other than true/false" {
  write_valid_env
  load_env
  SYSLOG_TLS_ENABLED=yes
  run env_validate
  [ "$status" -ne 0 ]
  [[ "$output" == *"SYSLOG_TLS_ENABLED"* ]]
}

@test "env_validate rejects a TLS syslog port equal to the plaintext TCP port" {
  write_valid_env
  load_env
  SYSLOG_TLS_ENABLED=true
  SYSLOG_TLS_PORT="${SYSLOG_TCP_PORT}"
  run env_validate
  [ "$status" -ne 0 ]
}

@test "env_validate rejects a TLS syslog port equal to the web port" {
  write_valid_env
  load_env
  SYSLOG_TLS_ENABLED=true
  SYSLOG_TLS_PORT="${GRAYLOG_HTTP_PORT}"
  run env_validate
  [ "$status" -ne 0 ]
}

@test "env_validate rejects a non-numeric certificate lifetime" {
  write_valid_env
  load_env
  GRAYLOG_TLS_CERT_DAYS=10y
  run env_validate
  [ "$status" -ne 0 ]
}

# --- deploy.sh steps ---------------------------------------------------------

load_deploy() {
  write_valid_env
  load_env
  # shellcheck source=deploy.sh
  source "${REPO_ROOT}/deploy.sh"
}

@test "step_external_uri auto-detects an https:// URI" {
  load_deploy
  stub ip 0 "1.1.1.1 via 10.1.2.1 dev eth0 src 10.1.2.3 uid 0"
  step_external_uri
  [ "${GRAYLOG_HTTP_EXTERNAL_URI}" = "https://10.1.2.3:9000/" ]
}

@test "step_external_uri migrates a persisted http:// URI to https://" {
  load_deploy
  persist_env_var GRAYLOG_HTTP_EXTERNAL_URI "http://10.1.2.3:9000/"
  step_external_uri
  [ "${GRAYLOG_HTTP_EXTERNAL_URI}" = "https://10.1.2.3:9000/" ]
  grep -q '^GRAYLOG_HTTP_EXTERNAL_URI="https://10.1.2.3:9000/"$' "${ENV_FILE}"
}

render_graylog_unit() {
  QUADLET_DEST_DIR="${TEST_TMP}/units"
  stub systemctl 0
  GRAYLOG_HTTP_EXTERNAL_URI="https://10.1.2.3:9000/"
  GRAYLOG_SERVER_JAVA_OPTS="-Xms1g -Xmx1g"
  export GRAYLOG_HTTP_EXTERNAL_URI GRAYLOG_SERVER_JAVA_OPTS
  step_quadlets >/dev/null
  UNIT="${QUADLET_DEST_DIR}/graylog.container"
}

@test "Graylog unit enables TLS and mounts the certificate directory read-only" {
  load_deploy
  render_graylog_unit
  grep -q '^Environment=GRAYLOG_HTTP_ENABLE_TLS=true$' "${UNIT}"
  grep -q '^Environment=GRAYLOG_HTTP_TLS_CERT_FILE=/etc/graylog-tls/cert.pem$' "${UNIT}"
  grep -q '^Environment=GRAYLOG_HTTP_TLS_KEY_FILE=/etc/graylog-tls/key.pem$' "${UNIT}"
  grep -q '^Environment=GRAYLOG_HTTP_PUBLISH_URI=https://graylog:9000/$' "${UNIT}"
  grep -q "^Volume=${DATA_ROOT}/tls:/etc/graylog-tls:ro,Z$" "${UNIT}"
  grep -q '^HealthCmd=curl -sf --cacert /etc/graylog-tls/cert.pem https://localhost:9000/' "${UNIT}"
  refute grep -q 'http://' "${UNIT}"
}

@test "Graylog unit carries the trust store flags exactly once, after the heap options" {
  load_deploy
  render_graylog_unit
  grep -q '^Environment="GRAYLOG_SERVER_JAVA_OPTS=-Xms1g -Xmx1g -Djavax.net.ssl.trustStore=/etc/graylog-tls/cacerts.jks -Djavax.net.ssl.trustStorePassword=changeit"$' "${UNIT}"
  [ "$(grep -o 'javax.net.ssl.trustStore=' "${UNIT}" | wc -l)" -eq 1 ]
}

@test "Graylog unit does not publish a TLS syslog port when disabled" {
  load_deploy
  render_graylog_unit
  [ "$(grep -c '^PublishPort=' "${UNIT}")" -eq 3 ]
  refute grep -q '6514' "${UNIT}"
}

@test "Graylog unit publishes the TLS syslog port when enabled, keeping plaintext ports" {
  load_deploy
  SYSLOG_TLS_ENABLED=true
  SYSLOG_TLS_PORT=16514
  render_graylog_unit
  grep -q '^PublishPort=16514:6514/tcp$' "${UNIT}"
  grep -q '^PublishPort=1514:1514/tcp$' "${UNIT}"
  grep -q '^PublishPort=1514:1514/udp$' "${UNIT}"
}

@test "toggling TLS syslog is detected as a change to graylog.service only once" {
  load_deploy
  render_graylog_unit
  CHANGED_UNITS=()
  step_quadlets >/dev/null
  [ "${#CHANGED_UNITS[@]}" -eq 0 ]
  SYSLOG_TLS_ENABLED=true
  step_quadlets >/dev/null
  [ "${CHANGED_UNITS[*]}" = "graylog.service" ]
}

@test "step_tls refuses a user-supplied JVM trust store" {
  load_deploy
  GRAYLOG_TLS_DIR="${TEST_TMP}/tls"; mkdir -p "${GRAYLOG_TLS_DIR}"
  GRAYLOG_SERVER_JAVA_OPTS="-Xmx1g -Djavax.net.ssl.trustStore=/tmp/x"
  run step_tls
  [ "$status" -ne 0 ]
  [[ "$output" == *"trustStore"* ]]
}

@test "step_tls refuses a key that does not match the existing certificate" {
  load_deploy
  GRAYLOG_TLS_DIR="${TEST_TMP}/tls"; mkdir -p "${GRAYLOG_TLS_DIR}"
  GRAYLOG_HTTP_EXTERNAL_URI="https://10.1.2.3:9000/"
  GRAYLOG_SERVER_JAVA_OPTS="-Xms1g -Xmx1g"
  tls_generate_self_signed "${GRAYLOG_TLS_DIR}/cert.pem" "${GRAYLOG_TLS_DIR}/key.pem" 3650 x "IP:10.1.2.3"
  openssl genpkey -algorithm RSA -pkeyopt rsa_keygen_bits:2048 -out "${GRAYLOG_TLS_DIR}/key.pem" 2>/dev/null
  stub chown 0
  stub podman 0
  run step_tls
  [ "$status" -ne 0 ]
  [[ "$output" == *"is not the private key"* ]]
  [ -z "$(calls_of podman)" ]
}

@test "installed packages are recorded under DATA_ROOT, never in the working directory" {
  load_deploy
  MANIFEST_FILE=""
  stub rpm 1
  stub dnf 0
  stub podman 0 "podman version 5.4.0"
  cd "${TEST_TMP}"
  step_packages >/dev/null 2>&1
  [ ! -e "${TEST_TMP}/.packages_installed" ]
  MANIFEST_FILE="${TEST_TMP}/data/.manifest"; mkdir -p "${TEST_TMP}/data"
  record_installed_packages
  grep -qx "podman" "${MANIFEST_FILE}.packages_installed"
}
