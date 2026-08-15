#!/usr/bin/env bats
# Memory-aware JVM heap sizing (auto-detected from host RAM when blank).

load 'test_helper'

setup() {
  common_setup
  source "${REPO_ROOT}/scripts/lib.sh"
}

teardown() { common_teardown; }

@test "heap_size_for_ram_mb applies the requested fraction" {
  run heap_size_for_ram_mb 8000 50 512 31744
  [ "$status" -eq 0 ]
  [ "$output" = "3g" ]  # 8000*50% = 4000MB -> floors to 3g on whole-GB rounding
}

@test "heap_size_for_ram_mb matches the tested 7.5GB VM (Data Node: 50%, capped 31g)" {
  run heap_size_for_ram_mb 7680 50 512 31744
  [ "$output" = "3g" ]
}

@test "heap_size_for_ram_mb matches the tested 7.5GB VM (Graylog: 25%, capped 4g)" {
  run heap_size_for_ram_mb 7680 25 512 4096
  [ "$output" = "1g" ]
}

@test "heap_size_for_ram_mb clamps to the minimum on a tiny host" {
  run heap_size_for_ram_mb 512 25 512 4096
  [ "$output" = "512m" ]
}

@test "heap_size_for_ram_mb clamps to the maximum on a huge host" {
  run heap_size_for_ram_mb 262144 50 512 31744
  [ "$output" = "31g" ]
}

@test "heap_size_for_ram_mb never exceeds the cap even when the fraction alone would" {
  run heap_size_for_ram_mb 32768 50 512 4096
  [ "$output" = "4g" ]
}

@test "detect_total_ram_mb reads a plausible value from /proc/meminfo" {
  run detect_total_ram_mb
  [ "$status" -eq 0 ]
  [[ "$output" =~ ^[0-9]+$ ]]
  [ "$output" -gt 0 ]
}

@test "GRAYLOG_SERVER_JAVA_OPTS and DATANODE_OPENSEARCH_HEAP are allowed blank in .env.example (auto-detected)" {
  grep -qE '^GRAYLOG_SERVER_JAVA_OPTS=$' "${REPO_ROOT}/.env.example"
  grep -qE '^DATANODE_OPENSEARCH_HEAP=$' "${REPO_ROOT}/.env.example"
}

@test "env_validate does not require heap settings to be pre-populated" {
  cp "${REPO_ROOT}/.env.example" "${TEST_TMP}/.env"
  chmod 600 "${TEST_TMP}/.env"
  ENV_FILE="${TEST_TMP}/.env" load_env
  [ -z "${GRAYLOG_SERVER_JAVA_OPTS}" ]
  [ -z "${DATANODE_OPENSEARCH_HEAP}" ]
  run env_validate
  [ "$status" -eq 0 ]
}
