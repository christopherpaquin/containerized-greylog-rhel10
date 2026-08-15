#!/usr/bin/env bash
# Shared setup for integration tests. These exercise the REAL deployed
# system (systemd, podman, SELinux, firewalld) and therefore:
#   - must run as root
#   - must run on the target RHEL 10 host (or an equivalent VM), never a
#     generic dev machine
#   - are slow (minutes) and mutate host state - do not run in parallel
#     with anything else touching this stack
#
# Run with: sudo bats tests/integration/

INTEGRATION_TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${INTEGRATION_TEST_DIR}/../.." && pwd)"
ENV_FILE="${REPO_ROOT}/.env"

require_root_or_skip() {
  if [[ "$(id -u)" -ne 0 ]]; then
    skip "integration tests must run as root (sudo bats tests/integration/)"
  fi
}

load_deployed_env() {
  [[ -f "${ENV_FILE}" ]] || skip ".env not present - run ./deploy.sh first"
  set -a
  # shellcheck disable=SC1090
  source "${ENV_FILE}"
  set +a
}
