#!/usr/bin/env bats
# .env parsing and required-variable validation.

load 'test_helper'

setup() {
  common_setup
  source "${REPO_ROOT}/scripts/lib.sh"
  ENV_FILE="${TEST_TMP}/.env"
}

teardown() { common_teardown; }

write_valid_env() {
  cp "${REPO_ROOT}/.env.example" "${ENV_FILE}"
  chmod 600 "${ENV_FILE}"
}

@test "load_env fails when .env is missing" {
  run load_env
  [ "$status" -ne 0 ]
  [[ "$output" == *"not found"* ]]
}

@test "load_env sources and exports variables from .env" {
  write_valid_env
  load_env
  [ "${GRAYLOG_VERSION}" = "7.1.7" ]
  [ "${NETWORK_NAME}" = "graylog-net" ]
}

@test "load_env tightens overly-permissive .env permissions" {
  write_valid_env
  chmod 644 "${ENV_FILE}"
  load_env
  perms="$(stat -c '%a' "${ENV_FILE}")"
  [ "${perms}" = "600" ]
}

@test "env_validate passes for a fully populated .env.example" {
  write_valid_env
  load_env
  run env_validate
  [ "$status" -eq 0 ]
}

@test "env_validate fails when a required variable is blank" {
  write_valid_env
  load_env
  # shellcheck disable=SC2034
  NETWORK_NAME=""
  run env_validate
  [ "$status" -ne 0 ]
  [[ "$output" == *"NETWORK_NAME"* ]]
}

@test "env_validate reports every missing variable, not just the first" {
  write_valid_env
  load_env
  NETWORK_NAME=""
  PROJECT_NAME=""
  run env_validate
  [ "$status" -ne 0 ]
  [[ "$output" == *"NETWORK_NAME"* ]]
  [[ "$output" == *"PROJECT_NAME"* ]]
}

@test "env_validate does not require GENERATED secrets to be pre-populated" {
  write_valid_env
  load_env
  # .env.example ships these blank on purpose - deploy.sh fills them in.
  [ -z "${GRAYLOG_PASSWORD_SECRET}" ]
  [ -z "${MONGO_INITDB_ROOT_PASSWORD}" ]
  run env_validate
  [ "$status" -eq 0 ]
}

@test "persist_env_var updates an existing key in place" {
  write_valid_env
  load_env
  persist_env_var NETWORK_NAME "custom-net"
  grep -q '^NETWORK_NAME="custom-net"$' "${ENV_FILE}"
  [ "${NETWORK_NAME}" = "custom-net" ]
}

@test "persist_env_var appends a key that does not yet exist" {
  write_valid_env
  load_env
  persist_env_var BRAND_NEW_KEY "hello"
  grep -q '^BRAND_NEW_KEY="hello"$' "${ENV_FILE}"
}

@test "persist_env_var is idempotent (rerun does not duplicate the key)" {
  write_valid_env
  load_env
  persist_env_var NETWORK_NAME "custom-net"
  persist_env_var NETWORK_NAME "custom-net"
  count="$(grep -c '^NETWORK_NAME=' "${ENV_FILE}")"
  [ "${count}" -eq 1 ]
}

@test "persist_env_var value with spaces survives a reload of .env" {
  write_valid_env
  load_env
  persist_env_var GRAYLOG_SERVER_JAVA_OPTS "-Xms1g -Xmx1g"
  unset GRAYLOG_SERVER_JAVA_OPTS
  load_env
  [ "${GRAYLOG_SERVER_JAVA_OPTS}" = "-Xms1g -Xmx1g" ]
}

@test "persist_env_var round-trips shell and sed metacharacters unchanged" {
  write_valid_env
  load_env
  local tricky='a|b&c\d"e$HOME`id`/f g'
  persist_env_var NETWORK_NAME "${tricky}"
  unset NETWORK_NAME
  load_env
  [ "${NETWORK_NAME}" = "${tricky}" ]
}

@test "persist_env_var keeps .env mode when updating a key" {
  write_valid_env
  chmod 600 "${ENV_FILE}"
  load_env
  persist_env_var NETWORK_NAME "custom-net"
  [ "$(stat -c '%a' "${ENV_FILE}")" = "600" ]
  ! ls "${ENV_FILE}".?* >/dev/null 2>&1
}

@test "admin_notes shows URL, health check, stop/start commands and no secrets" {
  write_valid_env
  load_env
  GRAYLOG_HTTP_EXTERNAL_URI="https://10.1.2.3:9000/"
  MONGO_INITDB_ROOT_PASSWORD="s3cretvalue"
  GRAYLOG_PASSWORD_SECRET="peppervalue"
  run admin_notes
  [ "$status" -eq 0 ]
  [[ "$output" == *"https://10.1.2.3:9000/"* ]]
  [[ "$output" == *"${REPO_ROOT}/healthcheck.sh"* ]]
  [[ "$output" == *"systemctl stop graylog graylog-datanode mongodb"* ]]
  [[ "$output" == *"systemctl start graylog"* ]]
  [[ "$output" == *"journalctl -u graylog"* ]]
  [[ "$output" != *"s3cretvalue"* ]]
  [[ "$output" != *"peppervalue"* ]]
  [[ "$output" != *"(TLS)"* ]]
  SYSLOG_TLS_ENABLED=true
  run admin_notes
  [[ "$output" == *"6514/tcp (TLS)"* ]]
}
