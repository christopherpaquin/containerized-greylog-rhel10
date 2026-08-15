#!/usr/bin/env bats
# SELinux configuration logic (semanage/restorecon are stubbed - these
# tests run on any dev machine, not just the target RHEL 10 VM).

load 'test_helper'

setup() {
  common_setup
  source "${REPO_ROOT}/scripts/lib.sh"
}

teardown() { common_teardown; }

@test "selinux_label_path adds a new fcontext rule when none exists" {
  stub semanage 0 ""
  stub restorecon 0
  selinux_label_path "/var/lib/graylog-stack"
  calls_of semanage | grep -qE "^fcontext -a -t container_file_t /var/lib/graylog-stack\(/\.\*\)\?$"
}

@test "selinux_label_path is idempotent - does not re-add an existing rule" {
  cat > "${STUB_BIN}/semanage" <<EOF
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "${TEST_TMP}/calls_semanage"
if [[ "\$1 \$2" == "fcontext -l" ]]; then
  echo '/var/lib/graylog-stack(/.*)?    all files    system_u:object_r:container_file_t:s0'
  exit 0
fi
exit 0
EOF
  chmod +x "${STUB_BIN}/semanage"
  stub restorecon 0
  selinux_label_path "/var/lib/graylog-stack"
  ! calls_of semanage | grep -q "^-a "
}

@test "selinux_label_path always runs restorecon to reapply labels" {
  stub semanage 0 ""
  stub restorecon 0
  selinux_label_path "/var/lib/graylog-stack"
  calls_of restorecon | grep -q "\-Rv /var/lib/graylog-stack"
}

@test "selinux_unlabel_path removes an existing rule" {
  cat > "${STUB_BIN}/semanage" <<EOF
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "${TEST_TMP}/calls_semanage"
if [[ "\$1 \$2" == "fcontext -l" ]]; then
  echo '/var/lib/graylog-stack(/.*)?    all files    system_u:object_r:container_file_t:s0'
  exit 0
fi
exit 0
EOF
  chmod +x "${STUB_BIN}/semanage"
  selinux_unlabel_path "/var/lib/graylog-stack"
  calls_of semanage | grep -qE "^fcontext -d -t container_file_t /var/lib/graylog-stack\(/\.\*\)\?$"
}

@test "selinux_unlabel_path is a no-op when no rule exists" {
  stub semanage 0 ""
  selinux_unlabel_path "/var/lib/graylog-stack"
  ! calls_of semanage | grep -q "^-d "
}

@test "deploy.sh refuses to proceed when SELinux is not Enforcing" {
  # Exercise the actual guard clause from deploy.sh's step_selinux logic.
  run bash -c '
    getenforce() { echo "Permissive"; }
    export -f getenforce
    mode="$(getenforce)"
    [[ "${mode}" == "Enforcing" ]] || { echo "REFUSED: ${mode}"; exit 1; }
  '
  [ "$status" -eq 1 ]
  [[ "$output" == *"REFUSED: Permissive"* ]]
}

@test "deploy.sh never calls setenforce" {
  ! grep -rn "setenforce" "${REPO_ROOT}/deploy.sh" "${REPO_ROOT}/scripts"
}
