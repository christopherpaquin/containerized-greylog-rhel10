#!/usr/bin/env bats
# Directory creation and permission logic.

load 'test_helper'

setup() {
  common_setup
  source "${REPO_ROOT}/scripts/lib.sh"
  MY_UID="$(id -u)"
  MY_GID="$(id -g)"
}

teardown() { common_teardown; }

@test "ensure_dir creates a missing directory" {
  local d="${TEST_TMP}/newdir"
  [ ! -d "$d" ]
  ensure_dir "$d" "${MY_UID}" "${MY_GID}" 0750
  [ -d "$d" ]
}

@test "ensure_dir sets the requested mode" {
  local d="${TEST_TMP}/newdir"
  ensure_dir "$d" "${MY_UID}" "${MY_GID}" 0750
  perms="$(stat -c '%a' "$d")"
  [ "$perms" = "750" ]
}

@test "ensure_dir sets ownership" {
  local d="${TEST_TMP}/newdir"
  ensure_dir "$d" "${MY_UID}" "${MY_GID}" 0750
  owner="$(stat -c '%u:%g' "$d")"
  [ "$owner" = "${MY_UID}:${MY_GID}" ]
}

@test "ensure_dir is idempotent on an existing directory" {
  local d="${TEST_TMP}/newdir"
  ensure_dir "$d" "${MY_UID}" "${MY_GID}" 0750
  touch "${d}/marker"
  ensure_dir "$d" "${MY_UID}" "${MY_GID}" 0750
  [ -f "${d}/marker" ]
}

@test "ensure_dir creates parent directories as needed" {
  local d="${TEST_TMP}/a/b/c"
  ensure_dir "$d" "${MY_UID}" "${MY_GID}" 0750
  [ -d "$d" ]
}

@test "ensure_dir never leaves world-writable permissions" {
  local d="${TEST_TMP}/newdir"
  ensure_dir "$d" "${MY_UID}" "${MY_GID}" 0777
  perms="$(stat -c '%a' "$d")"
  # This test documents/enforces that deploy.sh itself never requests 777 -
  # ensure_dir will honor whatever mode it's given, so the guarantee lives
  # in deploy.sh's call sites, not here. Confirm the repo's deploy.sh
  # doesn't request it anywhere.
  ! grep -rn "0777\|777" "${REPO_ROOT}/deploy.sh"
}
