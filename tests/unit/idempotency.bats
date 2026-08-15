#!/usr/bin/env bats
# Idempotency helpers: readiness polling and the changed-unit tracking that
# decides `systemctl start` vs `restart`.

load 'test_helper'

setup() {
  common_setup
  source "${REPO_ROOT}/scripts/lib.sh"
}

teardown() { common_teardown; }

@test "wait_until succeeds immediately when the command already succeeds" {
  run wait_until "always true" 5 1 true
  [ "$status" -eq 0 ]
}

@test "wait_until retries until the command succeeds" {
  local counter_file="${TEST_TMP}/counter"
  echo 0 > "${counter_file}"
  flaky() {
    local n; n="$(cat "${counter_file}")"
    n=$((n + 1))
    echo "${n}" > "${counter_file}"
    [[ "${n}" -ge 3 ]]
  }
  run wait_until "eventually true" 10 1 flaky
  [ "$status" -eq 0 ]
  [ "$(cat "${counter_file}")" -eq 3 ]
}

@test "wait_until fails after the timeout elapses" {
  run wait_until "never true" 2 1 false
  [ "$status" -ne 0 ]
  [[ "$output" == *"Timed out"* ]]
}

@test "unit_changed / start_or_restart: unchanged + already-active unit only gets start" {
  # shellcheck source=deploy.sh
  source "${REPO_ROOT}/deploy.sh"
  CHANGED_UNITS=()
  stub systemctl 0
  cat > "${STUB_BIN}/systemctl" <<EOF
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "${TEST_TMP}/calls_systemctl"
[[ "\$1 \$2" == "is-active --quiet" ]] && exit 0
exit 0
EOF
  chmod +x "${STUB_BIN}/systemctl"
  start_or_restart mongodb.service
  calls_of systemctl | grep -q "^start mongodb.service$"
  ! calls_of systemctl | grep -q "^restart mongodb.service$"
}

@test "unit_changed / start_or_restart: changed + already-active unit gets restart" {
  source "${REPO_ROOT}/deploy.sh"
  CHANGED_UNITS=(mongodb.service)
  cat > "${STUB_BIN}/systemctl" <<EOF
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "${TEST_TMP}/calls_systemctl"
[[ "\$1 \$2" == "is-active --quiet" ]] && exit 0
exit 0
EOF
  chmod +x "${STUB_BIN}/systemctl"
  start_or_restart mongodb.service
  calls_of systemctl | grep -q "^restart mongodb.service$"
}

@test "unit_changed / start_or_restart: changed but not-yet-active unit gets start, not restart" {
  source "${REPO_ROOT}/deploy.sh"
  CHANGED_UNITS=(mongodb.service)
  cat > "${STUB_BIN}/systemctl" <<EOF
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "${TEST_TMP}/calls_systemctl"
[[ "\$1 \$2" == "is-active --quiet" ]] && exit 1
exit 0
EOF
  chmod +x "${STUB_BIN}/systemctl"
  start_or_restart mongodb.service
  calls_of systemctl | grep -q "^start mongodb.service$"
  ! calls_of systemctl | grep -q "^restart mongodb.service$"
}
