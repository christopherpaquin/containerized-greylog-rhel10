#!/usr/bin/env bash
# Shared helper library for deploy.sh / healthcheck.sh / uninstall.sh.
# Sourced, never executed directly.

# --- paths -------------------------------------------------------------
LIB_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${LIB_SCRIPT_DIR}/.." && pwd)"
ENV_FILE="${REPO_ROOT}/.env"
ENV_EXAMPLE_FILE="${REPO_ROOT}/.env.example"
QUADLET_SRC_DIR="${REPO_ROOT}/quadlet"
QUADLET_DEST_DIR="/etc/containers/systemd/graylog-stack"
SYSCTL_DROPIN="/etc/sysctl.d/99-graylog-stack.conf"
LIMITS_DROPIN="/etc/security/limits.d/99-graylog-stack.conf"

# --- logging -------------------------------------------------------------
_c_red=$'\033[31m'; _c_grn=$'\033[32m'; _c_yel=$'\033[33m'; _c_blu=$'\033[34m'; _c_rst=$'\033[0m'
[[ -t 1 ]] || { _c_red=; _c_grn=; _c_yel=; _c_blu=; _c_rst=; }

log_info() { printf '%s[INFO]%s %s\n' "${_c_blu}" "${_c_rst}" "$*"; }
log_warn() { printf '%s[WARN]%s %s\n' "${_c_yel}" "${_c_rst}" "$*" >&2; }
log_err()  { printf '%s[FAIL]%s %s\n' "${_c_red}" "${_c_rst}" "$*" >&2; }
log_ok()   { printf '%s[ OK ]%s %s\n' "${_c_grn}" "${_c_rst}" "$*"; }
log_step() { printf '\n%s==>%s %s\n' "${_c_blu}" "${_c_rst}" "$*"; }

die() { log_err "$*"; exit 1; }

# --- privilege / platform checks -----------------------------------------
require_root() {
  [[ ${EUID} -eq 0 ]] || die "This must be run as root (try: sudo $0)"
}

require_rhel10() {
  [[ -r /etc/os-release ]] || die "/etc/os-release not found - cannot verify OS"
  # shellcheck disable=SC1091
  local id version_id
  id="$(. /etc/os-release && echo "$ID")"
  version_id="$(. /etc/os-release && echo "$VERSION_ID")"
  case "${id}" in
    rhel|centos|rocky|almalinux) ;;
    *) die "Unsupported OS ID='${id}'. This deployment targets RHEL 10." ;;
  esac
  local major="${version_id%%.*}"
  [[ "${major}" == "10" ]] || die "Unsupported OS version '${version_id}'. This deployment targets RHEL/derivative 10.x (found ${id} ${version_id})."
}

# --- .env handling --------------------------------------------------------
# Required variables. Anything not GENERATED-blank must be non-empty after load_env.
ENV_REQUIRED_VARS=(
  GRAYLOG_IMAGE GRAYLOG_VERSION
  DATANODE_IMAGE DATANODE_VERSION
  MONGODB_IMAGE MONGODB_VERSION
  PROJECT_NAME NETWORK_NAME
  MONGODB_CONTAINER_NAME DATANODE_CONTAINER_NAME GRAYLOG_CONTAINER_NAME
  DATA_ROOT MONGODB_DB_DIR MONGODB_CONFIGDB_DIR DATANODE_DATA_DIR GRAYLOG_DATA_DIR SECRETS_DIR
  GRAYLOG_HTTP_PORT SYSLOG_TCP_PORT SYSLOG_UDP_PORT
  GRAYLOG_ROOT_USERNAME
  GRAYLOG_SELFSIGNED_STARTUP DATANODE_CERT_LIFETIME
  MONGO_INITDB_DATABASE MONGO_INITDB_ROOT_USERNAME
  TZ MANAGE_FIREWALL
)

# Values that are allowed to be blank in .env (generated at deploy time).
ENV_GENERATED_VARS=(
  GRAYLOG_PASSWORD_SECRET GRAYLOG_ROOT_PASSWORD_SHA2 MONGO_INITDB_ROOT_PASSWORD
  GRAYLOG_HTTP_EXTERNAL_URI GRAYLOG_SERVER_JAVA_OPTS DATANODE_OPENSEARCH_HEAP
)

# load_env [--allow-missing-generated]
# Sources .env (falling back to .env.example only for `env_validate`, never
# for real deploys) and exports every variable so envsubst/child processes
# can see them.
load_env() {
  [[ -f "${ENV_FILE}" ]] || die "${ENV_FILE} not found. Copy .env.example to .env and configure it first."
  local perms
  perms="$(stat -c '%a' "${ENV_FILE}")"
  if [[ "${perms}" != "600" && "${perms}" != "400" ]]; then
    log_warn ".env has permissions ${perms}; tightening to 600 (contains secrets)"
    chmod 600 "${ENV_FILE}" || true
  fi
  set -a
  # shellcheck disable=SC1090
  source "${ENV_FILE}"
  set +a
}

env_validate() {
  local missing=()
  local var
  for var in "${ENV_REQUIRED_VARS[@]}"; do
    if [[ -z "${!var:-}" ]]; then
      missing+=("${var}")
    fi
  done
  if [[ ${#missing[@]} -gt 0 ]]; then
    die "Missing required .env values: ${missing[*]}"
  fi
}

# --- secret generation -----------------------------------------------------
# Alphanumeric only, by design: avoids URI/shell escaping edge cases for
# values embedded in MongoDB connection strings and Quadlet unit files.
#
# `head -c` closing the pipe early makes `tr` receive SIGPIPE, which under
# `pipefail` surfaces as a (benign, expected) non-zero pipeline status -
# tolerate that specific case but still verify the output length so a real
# failure (e.g. /dev/urandom unreadable) is not silently swallowed.
gen_secret() {
  local length="${1:-96}" out
  out="$(tr -dc 'A-Za-z0-9' < /dev/urandom | head -c "${length}")" || true
  [[ ${#out} -eq ${length} ]] || die "gen_secret: failed to generate a ${length}-character secret"
  printf '%s' "${out}"
}

sha256_hex() {
  sha256sum | cut -d' ' -f1
}

# --- filesystem -------------------------------------------------------------
# ensure_dir <path> <owner_uid> <owner_gid> <mode>
ensure_dir() {
  local path="$1" uid="$2" gid="$3" mode="$4"
  mkdir -p "${path}"
  chown "${uid}:${gid}" "${path}"
  chmod "${mode}" "${path}"
}

# --- SELinux ------------------------------------------------------------
# Persist a container_file_t fcontext rule for a path tree and apply it.
# Idempotent: semanage fails harmlessly if the exact rule already exists.
selinux_label_path() {
  local path="$1"
  command -v semanage >/dev/null 2>&1 || die "semanage not found (install policycoreutils-python-utils)"
  local pattern="${path}(/.*)?"
  # Capture fully before grepping: piping semanage's (large) output directly
  # into `grep -q` lets grep close the pipe early on first match, which can
  # SIGPIPE semanage and corrupt the pipeline's exit status under pipefail.
  local existing
  existing="$(semanage fcontext -l 2>/dev/null)" || true
  if ! grep -qF "${pattern}" <<< "${existing}"; then
    semanage fcontext -a -t container_file_t "${pattern}"
  fi
  restorecon -Rv "${path}" >/dev/null
}

selinux_unlabel_path() {
  local path="$1"
  local pattern="${path}(/.*)?"
  local existing
  existing="$(semanage fcontext -l 2>/dev/null)" || true
  if grep -qF "${pattern}" <<< "${existing}"; then
    semanage fcontext -d -t container_file_t "${pattern}" || true
  fi
}

# --- Podman secrets ---------------------------------------------------------
# podman_secret_ensure <name> <value>
# Creates the secret only if it does not already exist, so reruns never
# rotate credentials. Returns 0 whether created or already present.
podman_secret_ensure() {
  local name="$1" value="$2"
  if podman secret exists "${name}" 2>/dev/null; then
    return 0
  fi
  printf '%s' "${value}" | podman secret create "${name}" - >/dev/null
}

podman_secret_rm_if_exists() {
  local name="$1"
  if podman secret exists "${name}" 2>/dev/null; then
    podman secret rm "${name}" >/dev/null
  fi
}

# --- Quadlet rendering --------------------------------------------------
# render_quadlet <template_path> <dest_path> <var...>
# Renders a template with envsubst restricted to the given variable names
# (so literal $ characters elsewhere, e.g. in generated secrets referenced
# by name only, are never touched) and writes it only if the content
# actually changed, so unrelated reruns don't churn mtimes/daemon-reload.
render_quadlet() {
  local template="$1" dest="$2"; shift 2
  local varlist=""
  local v
  for v in "$@"; do varlist+="\${${v}} "; done
  local rendered
  rendered="$(envsubst "${varlist}" < "${template}")"
  if [[ -f "${dest}" ]] && [[ "$(cat "${dest}")" == "${rendered}" ]]; then
    return 1 # unchanged
  fi
  printf '%s\n' "${rendered}" > "${dest}.tmp"
  mv -f "${dest}.tmp" "${dest}"
  chmod 644 "${dest}"
  return 0 # changed
}

# persist_env_var <KEY> <VALUE>
# In-place update of a KEY=... line in .env (creates it if absent). Used to
# durably store generated secrets/detected values so reruns are idempotent.
# Uses a delimiter unlikely to appear in the value (|) rather than the more
# common / to stay safe for values that are themselves URLs.
persist_env_var() {
  local key="$1" value="$2"
  if grep -qE "^${key}=" "${ENV_FILE}"; then
    sed -i "s|^${key}=.*|${key}=${value}|" "${ENV_FILE}"
  else
    printf '%s=%s\n' "${key}" "${value}" >> "${ENV_FILE}"
  fi
  printf -v "${key}" '%s' "${value}"
  export "${key?}"
}

# --- memory-aware JVM heap sizing -------------------------------------------
detect_total_ram_mb() {
  awk '/^MemTotal:/{print int($2/1024)}' /proc/meminfo
}

# heap_size_for_ram_mb <total_mb> <fraction_pct> <min_mb> <max_mb>
# Applies the fraction, clamps to [min_mb, max_mb], and formats as "Ng"
# (whole GB, for readability) or "Nm" for values under 1 GB.
heap_size_for_ram_mb() {
  local total_mb="$1" fraction_pct="$2" min_mb="$3" max_mb="$4"
  local heap_mb=$(( total_mb * fraction_pct / 100 ))
  (( heap_mb < min_mb )) && heap_mb="${min_mb}"
  (( heap_mb > max_mb )) && heap_mb="${max_mb}"
  if (( heap_mb >= 1024 )); then
    echo "$(( heap_mb / 1024 ))g"
  else
    echo "${heap_mb}m"
  fi
}

# --- readiness polling -----------------------------------------------------
# wait_until <description> <timeout_seconds> <poll_interval_seconds> <cmd...>
# Polls a command until it succeeds or the timeout elapses. Used instead of
# a fixed sleep so startup ordering reflects real readiness.
wait_until() {
  local desc="$1" timeout="$2" interval="$3"; shift 3
  local waited=0
  until "$@" >/dev/null 2>&1; do
    if (( waited >= timeout )); then
      log_err "Timed out after ${timeout}s waiting for: ${desc}"
      return 1
    fi
    sleep "${interval}"
    waited=$(( waited + interval ))
  done
  log_ok "${desc} (${waited}s)"
  return 0
}

# --- firewalld -----------------------------------------------------------
firewall_open_port() {
  local port_proto="$1" # e.g. "9000/tcp"
  firewall-cmd --permanent --add-port="${port_proto}" >/dev/null
}

firewall_close_port() {
  local port_proto="$1"
  firewall-cmd --permanent --remove-port="${port_proto}" >/dev/null 2>&1 || true
}

firewall_reload() {
  firewall-cmd --reload >/dev/null
}
