#!/usr/bin/env bash
# Shared setup for unit tests. Unit tests exercise scripts/lib.sh functions
# in isolation, with system commands (podman, semanage, restorecon,
# firewall-cmd, systemctl) stubbed out - they must pass on a plain dev
# machine, not just on the target RHEL 10 VM.

UNIT_TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${UNIT_TEST_DIR}/../.." && pwd)"

common_setup() {
  TEST_TMP="$(mktemp -d)"
  STUB_BIN="${TEST_TMP}/bin"
  mkdir -p "${STUB_BIN}"
  export PATH="${STUB_BIN}:${PATH}"
  export TEST_TMP STUB_BIN
}

common_teardown() {
  [[ -n "${TEST_TMP:-}" && -d "${TEST_TMP}" ]] && rm -rf "${TEST_TMP}"
}

# stub <name> <exit_code> [stdout]
# Creates a fake executable on PATH that records its invocation (args, one
# per call, newline separated) to ${TEST_TMP}/calls_<name> and exits with
# the given status, optionally printing stdout.
stub() {
  local name="$1" exit_code="${2:-0}" stdout="${3:-}"
  cat > "${STUB_BIN}/${name}" <<EOF
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "${TEST_TMP}/calls_${name}"
[[ -n "${stdout}" ]] && printf '%s\n' "${stdout}"
exit ${exit_code}
EOF
  chmod +x "${STUB_BIN}/${name}"
}

calls_of() {
  cat "${TEST_TMP}/calls_${1}" 2>/dev/null || true
}
