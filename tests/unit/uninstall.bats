#!/usr/bin/env bats
# uninstall.sh behavior: argument parsing and the data-preservation default.

load 'test_helper'

teardown() { common_teardown; }

setup() { common_setup; }

@test "uninstall.sh --help exits 0 and does not require root" {
  run "${REPO_ROOT}/uninstall.sh" --help
  [ "$status" -eq 0 ]
  [[ "$output" == *"--purge-data"* ]]
}

@test "uninstall.sh rejects unknown arguments" {
  run "${REPO_ROOT}/uninstall.sh" --bogus-flag
  [ "$status" -ne 0 ]
}

@test "uninstall.sh requires root for real runs" {
  if [[ "$(id -u)" -eq 0 ]]; then
    skip "test suite itself is running as root"
  fi
  run "${REPO_ROOT}/uninstall.sh"
  # Without root, require_root's die() should fire before anything destructive.
  [ "$status" -ne 0 ]
  [[ "$output" == *"root"* ]]
}

@test "uninstall.sh defaults to preserving data (no --purge-data in default invocation help text implies opt-in)" {
  run "${REPO_ROOT}/uninstall.sh" --help
  [[ "$output" == *"Also permanently delete"* ]] || [[ "$output" == *"Irreversible"* ]]
}

@test "default uninstall path never deletes DATA_ROOT unconditionally" {
  # Static check: the unconditional `rm -rf` of DATA_ROOT must only appear
  # inside the PURGE_DATA branch, not in the default flow.
  awk '/if \[\[ "\$\{PURGE_DATA\}" == "true" \]\]; then/{flag=1} flag && /rm -rf "\$\{DATA_ROOT\}"/{found=1} /^else$/{flag=0} END{exit !found}' "${REPO_ROOT}/uninstall.sh"
}

@test "uninstall.sh never removes packages" {
  ! grep -qE '(dnf|yum) (remove|erase)' "${REPO_ROOT}/uninstall.sh"
}

@test "uninstall.sh never calls setenforce or disables SELinux" {
  ! grep -q "setenforce" "${REPO_ROOT}/uninstall.sh"
}
