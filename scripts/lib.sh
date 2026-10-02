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
# Shown at SSH login (pam_motd reads /etc/motd.d/), so an admin landing on
# the box sees how to operate the stack without finding this repo first.
MOTD_FILE="/etc/motd.d/90-graylog-stack"
# Source filter for the published ports (only present while
# FIREWALL_ALLOWED_SOURCES is set) - see firewall_source_filter_ruleset.
SOURCE_FILTER_NFT="/etc/graylog-stack/source-filter.nft"
SOURCE_FILTER_UNIT_NAME="graylog-stack-source-filter.service"
SOURCE_FILTER_UNIT="/etc/systemd/system/${SOURCE_FILTER_UNIT_NAME}"

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
  tls_defaults
}

# Defaults for settings added after the first release, so a .env written
# before they existed still loads cleanly under `set -u`.
tls_defaults() {
  : "${GRAYLOG_TLS_DIR:=${DATA_ROOT:-/var/lib/graylog-stack}/tls}"
  : "${GRAYLOG_TLS_CERT_DAYS:=3650}"
  : "${GRAYLOG_TLS_EXTRA_SANS:=}"
  : "${SYSLOG_TLS_ENABLED:=false}"
  : "${SYSLOG_TLS_PORT:=6514}"
  : "${GRAYLOG_API_TOKEN_TTL:=P3650D}"
  export GRAYLOG_API_TOKEN_TTL
  : "${FIREWALL_ZONE:=}"
  : "${FIREWALL_ALLOWED_SOURCES:=}"
  export FIREWALL_ZONE FIREWALL_ALLOWED_SOURCES
  export GRAYLOG_TLS_DIR GRAYLOG_TLS_CERT_DAYS GRAYLOG_TLS_EXTRA_SANS SYSLOG_TLS_ENABLED SYSLOG_TLS_PORT
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
  case "${SYSLOG_TLS_ENABLED:-false}" in
    true|false) ;;
    *) die "SYSLOG_TLS_ENABLED must be 'true' or 'false' (found '${SYSLOG_TLS_ENABLED}')" ;;
  esac
  if [[ "${SYSLOG_TLS_ENABLED:-false}" == "true" ]]; then
    local tls_port="${SYSLOG_TLS_PORT:-6514}"
    if [[ "${tls_port}" == "${SYSLOG_TCP_PORT}" || "${tls_port}" == "${GRAYLOG_HTTP_PORT}" ]]; then
      die "SYSLOG_TLS_PORT (${tls_port}) must differ from SYSLOG_TCP_PORT and GRAYLOG_HTTP_PORT - they are all published on the host over TCP"
    fi
  fi
  local src
  local -a sources=()
  IFS=',' read -ra sources <<< "${FIREWALL_ALLOWED_SOURCES:-}"
  for src in "${sources[@]}"; do
    src="${src//[[:space:]]/}"
    [[ -z "${src}" ]] || firewall_source_valid "${src}" \
      || die "FIREWALL_ALLOWED_SOURCES entry '${src}' is not an IPv4/IPv6 address or CIDR (e.g. 10.20.0.0/16)"
  done
  if [[ ! "${GRAYLOG_TLS_CERT_DAYS:-3650}" =~ ^[1-9][0-9]*$ ]]; then
    die "GRAYLOG_TLS_CERT_DAYS must be a positive whole number of days (found '${GRAYLOG_TLS_CERT_DAYS}')"
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

# --- TLS (web UI / API certificate, optional TLS syslog input) ---------------
# Where the host's GRAYLOG_TLS_DIR is mounted (read-only) inside the Graylog
# container. Referenced by the Quadlet template and by the input/JVM settings.
GRAYLOG_TLS_CONTAINER_DIR="/etc/graylog-tls"
# Container-side port of the optional TLS syslog input (published on the host
# as SYSLOG_TLS_PORT).
SYSLOG_TLS_CONTAINER_PORT=6514
SYSLOG_TLS_INPUT_TITLE="Syslog TCP (TLS)"
export GRAYLOG_TLS_CONTAINER_DIR

# uri_host <uri> - prints the host part (no scheme, port, path or brackets).
uri_host() {
  local h="${1#*://}"
  h="${h%%/*}"
  if [[ "${h}" == \[* ]]; then
    h="${h#\[}"; h="${h%%\]*}"
  else
    h="${h%%:*}"
  fi
  printf '%s' "${h}"
}

is_ip_literal() {
  [[ "$1" =~ ^[0-9]+(\.[0-9]+){3}$ || "$1" == *:* ]]
}

# tls_build_san_list <host-or-entry...>
# Accepts bare hostnames/IPs or ready-made "DNS:x"/"IP:y" entries, skips
# blanks, de-duplicates (first occurrence wins) and prints a
# subjectAltName value, e.g. "DNS:localhost,IP:127.0.0.1".
tls_build_san_list() {
  local -A seen=()
  local out="" item entry
  for item in "$@"; do
    item="${item//[[:space:]]/}"
    [[ -n "${item}" ]] || continue
    if [[ "${item}" =~ ^(DNS|IP): ]]; then
      entry="${item}"
    elif is_ip_literal "${item}"; then
      entry="IP:${item}"
    else
      entry="DNS:${item}"
    fi
    [[ -z "${seen[${entry}]:-}" ]] || continue
    seen["${entry}"]=1
    out+="${out:+,}${entry}"
  done
  printf '%s' "${out}"
}

# tls_generate_self_signed <cert_path> <key_path> <days> <common_name> <san_list>
# RSA-4096 self-signed certificate plus an unencrypted PKCS#8 key (the only
# key format Graylog accepts). Written via temp files and only moved into
# place once the result has been checked, including that it really is valid
# for the requested lifetime.
tls_generate_self_signed() {
  local cert="$1" key="$2" days="$3" cn="$4" san="$5"
  local tmp_cert="${cert}.tmp" tmp_key="${key}.tmp"
  if ! ( umask 077
         openssl req -x509 -newkey rsa:4096 -sha256 -nodes -days "${days}" \
           -subj "/CN=${cn:0:64}" -addext "subjectAltName=${san}" \
           -keyout "${tmp_key}" -out "${tmp_cert}" ) >/dev/null 2>&1; then
    rm -f "${tmp_cert}" "${tmp_key}"
    return 1
  fi
  if ! grep -q 'BEGIN PRIVATE KEY' "${tmp_key}" \
     || ! openssl x509 -in "${tmp_cert}" -noout -checkend "$(( (days - 1) * 86400 ))" >/dev/null 2>&1; then
    rm -f "${tmp_cert}" "${tmp_key}"
    return 1
  fi
  mv -f "${tmp_key}" "${key}"
  mv -f "${tmp_cert}" "${cert}"
}

# tls_cert_covers_host <cert_path> <host> - true if the host/IP is in the SANs.
tls_cert_covers_host() {
  local cert="$1" host="$2" flag="-checkhost" result
  is_ip_literal "${host}" && flag="-checkip"
  result="$(openssl x509 -in "${cert}" -noout "${flag}" "${host}" 2>/dev/null)" || true
  [[ "${result}" == *"does match"* ]]
}

# tls_key_matches_cert <cert_path> <key_path> - true if they are one key pair.
tls_key_matches_cert() {
  local cert_pub key_pub
  cert_pub="$(openssl x509 -in "$1" -noout -pubkey 2>/dev/null)" || return 1
  key_pub="$(openssl pkey -in "$2" -pubout 2>/dev/null)" || return 1
  [[ -n "${cert_pub}" && "${cert_pub}" == "${key_pub}" ]]
}

# tls_cert_days_left <cert_path> - whole days until notAfter (negative if expired).
tls_cert_days_left() {
  local cert="$1" end_date end_epoch
  end_date="$(openssl x509 -in "${cert}" -noout -enddate)" || return 1
  end_epoch="$(date -d "${end_date#notAfter=}" +%s)" || return 1
  echo $(( (end_epoch - $(date +%s)) / 86400 ))
}

tls_cert_fingerprint() {
  openssl x509 -in "$1" -noout -fingerprint -sha256 | cut -d= -f2
}

# tls_build_truststore <image> <cert_path> <truststore_path>
# Graylog calls its own REST API (via http_publish_uri) using the JVM's
# default trust store, which knows nothing about a self-signed certificate.
# Build a trust store that is the image's own cacerts plus our certificate,
# using the keytool shipped in that same image. The container gets no
# network and no volume: the certificate goes in on stdin and the finished
# trust store comes back on stdout.
tls_build_truststore() {
  local image="$1" cert="$2" out="$3"
  local tmp="${out}.tmp"
  # shellcheck disable=SC2016  # expanded by the shell inside the container
  if ! podman run --rm -i --network none --entrypoint /bin/sh "${image}" -c '
        set -e
        jh="${JAVA_HOME:-/opt/java/openjdk}"
        d="$(mktemp -d)"
        cat > "$d/cert.pem"
        cp "$jh/lib/security/cacerts" "$d/truststore"
        chmod 600 "$d/truststore"
        "$jh/bin/keytool" -importcert -noprompt -alias graylog-stack-web \
          -file "$d/cert.pem" -keystore "$d/truststore" -storepass changeit >&2
        cat "$d/truststore"' < "${cert}" > "${tmp}" || [[ ! -s "${tmp}" ]]; then
    rm -f "${tmp}"
    return 1
  fi
  mv -f "${tmp}" "${out}"
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
# The value is always written double-quoted, with the characters bash still
# interprets inside double quotes escaped, because .env is bash-sourced: an
# unquoted value containing a space (e.g. "-Xms1g -Xmx1g") would otherwise
# be parsed as an assignment followed by a command. The line is replaced via
# awk reading it from the environment (not sed) so no character in the
# value is ever treated as a pattern/replacement metacharacter.
persist_env_var() {
  local key="$1" value="$2"
  local escaped="${value//\\/\\\\}"
  escaped="${escaped//\"/\\\"}"
  escaped="${escaped//\$/\\\$}"
  escaped="${escaped//\`/\\\`}"
  local line="${key}=\"${escaped}\""
  if grep -qE "^${key}=" "${ENV_FILE}"; then
    local tmp
    tmp="$(mktemp "${ENV_FILE}.XXXXXX")"
    PERSIST_ENV_LINE="${line}" awk -v prefix="${key}=" \
      'index($0, prefix) == 1 { print ENVIRON["PERSIST_ENV_LINE"]; next } { print }' \
      "${ENV_FILE}" > "${tmp}"
    # Overwrite in place (not mv) so .env keeps its owner and mode.
    cat "${tmp}" > "${ENV_FILE}"
    rm -f "${tmp}"
  else
    printf '%s\n' "${line}" >> "${ENV_FILE}"
  fi
  printf -v "${key}" '%s' "${value}"
  export "${key?}"
}

# --- operator notes (login banner + deploy summary) -------------------------
# admin_notes - prints the short "how to run this box" reference. Contains
# no secrets, only where to find them.
admin_notes() {
  local syslog_line="${SYSLOG_TCP_PORT}/tcp and ${SYSLOG_UDP_PORT}/udp (plaintext)"
  [[ "${SYSLOG_TLS_ENABLED}" == "true" ]] && syslog_line+=", ${SYSLOG_TLS_PORT}/tcp (TLS)"
  cat <<EOF
==================== Graylog (Podman + systemd Quadlets) ====================
 Web UI / API : ${GRAYLOG_HTTP_EXTERNAL_URI}   (self-signed certificate)
 Syslog inputs: ${syslog_line}
 Login        : user '${GRAYLOG_ROOT_USERNAME}'; initial password in
                ${SECRETS_DIR}/admin_password.txt (root only, if not yet removed)

 Health check : sudo ${REPO_ROOT}/healthcheck.sh
 Status       : sudo systemctl status mongodb graylog-datanode graylog
                sudo podman ps

 Stop all     : sudo systemctl stop graylog graylog-datanode mongodb
 Start all    : sudo systemctl start graylog        (starts the other two first)
 Restart one  : sudo systemctl restart graylog      (or graylog-datanode, mongodb)
 Starts at boot automatically. Do not use 'podman start/stop' or
 'systemctl enable' - systemd owns these containers.

 Logs         : sudo journalctl -u graylog -f       (or -u graylog-datanode, -u mongodb)
                sudo podman logs --tail 100 ${GRAYLOG_CONTAINER_NAME}
 Data         : ${DATA_ROOT}   (check space: df -h ${DATANODE_DATA_DIR})
 Config       : ${REPO_ROOT}/.env   - edit, then: sudo ${REPO_ROOT}/deploy.sh
 More help    : ${REPO_ROOT}/docs/troubleshooting.md
=============================================================================
EOF
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
# Every rule this deployment adds is one "entry": <zone>|port|<port/proto> or
# <zone>|rich|<rich rule text>. Entries it added itself are listed in
# ${MANIFEST_FILE}.firewall_rules, so later runs and uninstall.sh remove
# exactly those and never a rule an administrator had in place already.

# firewall_source_valid <address-or-cidr>
firewall_source_valid() {
  local src="$1"
  if [[ "${src}" =~ ^([0-9]{1,3})\.([0-9]{1,3})\.([0-9]{1,3})\.([0-9]{1,3})(/([0-9]{1,2}))?$ ]]; then
    local i
    for i in 1 2 3 4; do (( 10#${BASH_REMATCH[i]} <= 255 )) || return 1; done
    [[ -z "${BASH_REMATCH[6]}" ]] || (( 10#${BASH_REMATCH[6]} <= 32 ))
    return
  fi
  if [[ "${src}" == *:* && "${src}" =~ ^[0-9A-Fa-f:]+(/([0-9]{1,3}))?$ ]]; then
    [[ -z "${BASH_REMATCH[2]}" ]] || (( 10#${BASH_REMATCH[2]} <= 128 ))
    return
  fi
  return 1
}

# firewall_detect_zone
# The zone traffic to this host actually arrives in: that of the interface
# carrying the default route, falling back to firewalld's default zone.
# (firewall-cmd without --zone always means the default zone, which is not
# necessarily the one the interface is bound to.)
firewall_detect_zone() {
  local iface zone=""
  iface="$(ip route get 1.1.1.1 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="dev") print $(i+1)}')" || true
  if [[ -n "${iface}" ]]; then
    zone="$(firewall-cmd --get-zone-of-interface="${iface}" 2>/dev/null)" || zone=""
  fi
  [[ -n "${zone}" ]] || zone="$(firewall-cmd --get-default-zone)"
  printf '%s' "${zone}"
}

# firewall_rich_rule <source> <port/proto> - prints the rich rule text.
firewall_rich_rule() {
  local src="$1" port="${2%%/*}" proto="${2##*/}" family="ipv4"
  [[ "${src}" == *:* ]] && family="ipv6"
  printf 'rule family="%s" source address="%s" port port="%s" protocol="%s" accept' "${family}" "${src}" "${port}" "${proto}"
}

# firewall_desired_entries <zone> <sources_csv> <port/proto...>
# One entry per line: plain port rules when no sources are given, otherwise
# one rich rule per source and port.
firewall_desired_entries() {
  local zone="$1" sources_csv="$2"; shift 2
  local -a sources=() clean=()
  local src p
  IFS=',' read -ra sources <<< "${sources_csv}"
  for src in "${sources[@]}"; do
    src="${src//[[:space:]]/}"
    [[ -z "${src}" ]] || clean+=("${src}")
  done
  for p in "$@"; do
    if [[ ${#clean[@]} -eq 0 ]]; then
      printf '%s|port|%s\n' "${zone}" "${p}"
    else
      for src in "${clean[@]}"; do
        printf '%s|rich|%s\n' "${zone}" "$(firewall_rich_rule "${src}" "${p}")"
      done
    fi
  done
}

# _firewall_entry <query|add|remove> <entry> - acts on the permanent config.
_firewall_entry() {
  local action="$1" entry="$2"
  local zone="${entry%%|*}" rest="${entry#*|}"
  local kind="${rest%%|*}" value="${rest#*|}"
  case "${kind}" in
    port) firewall-cmd --permanent --zone="${zone}" "--${action}-port=${value}" >/dev/null 2>&1 ;;
    rich) firewall-cmd --permanent --zone="${zone}" "--${action}-rich-rule=${value}" >/dev/null 2>&1 ;;
    *) return 2 ;;
  esac
}
firewall_entry_present() { _firewall_entry query "$1"; }
firewall_entry_add()     { _firewall_entry add "$1"; }
# Succeeds only if the entry is verifiably gone afterwards.
firewall_entry_remove() {
  _firewall_entry remove "$1" || true
  ! firewall_entry_present "$1"
}

# firewall_source_filter_ruleset <bridge_iface> <sources_csv> <port/proto...>
# Prints an nftables ruleset that drops traffic to the published ports unless
# it comes from an allowed source.
#
# Why this exists: Podman publishes ports with DNAT, and firewalld accepts
# all DNAT'ed traffic ("ct status dnat accept") before any zone, port or
# rich rule is consulted - so firewalld rules alone do NOT restrict who can
# reach a published container port (verified on RHEL 10.2 / firewalld 2.4).
# This table hooks prerouting ahead of the DNAT (priority -150 is after
# connection tracking at -200 and before dstnat at -100), where the packet
# still carries the host port and the real client address.
firewall_source_filter_ruleset() {
  local bridge="$1" sources_csv="$2"; shift 2
  local -a sources=() v4=() v6=() tcp=() udp=()
  local src p
  IFS=',' read -ra sources <<< "${sources_csv}"
  for src in "${sources[@]}"; do
    src="${src//[[:space:]]/}"
    [[ -n "${src}" ]] || continue
    if [[ "${src}" == *:* ]]; then v6+=("${src}"); else v4+=("${src}"); fi
  done
  for p in "$@"; do
    if [[ "${p##*/}" == "udp" ]]; then udp+=("${p%%/*}"); else tcp+=("${p%%/*}"); fi
  done
  local IFS=','
  cat <<EOF
# Managed by graylog-stack deploy.sh (FIREWALL_ALLOWED_SOURCES) - do not edit.
table inet graylog_stack {}
delete table inet graylog_stack
table inet graylog_stack {
  chain prerouting {
    type filter hook prerouting priority -150; policy accept;
    ct state established,related accept
    iifname "lo" accept
EOF
  [[ -z "${bridge}" ]] || printf '    iifname "%s" accept\n' "${bridge}"
  printf '    fib daddr type != local accept\n'
  local proto ports
  for proto in tcp udp; do
    if [[ "${proto}" == "tcp" ]]; then ports="${tcp[*]}"; else ports="${udp[*]}"; fi
    [[ -n "${ports}" ]] || continue
    [[ ${#v4[@]} -eq 0 ]] || printf '    %s dport { %s } ip saddr { %s } accept\n' "${proto}" "${ports}" "${v4[*]}"
    [[ ${#v6[@]} -eq 0 ]] || printf '    %s dport { %s } ip6 saddr { %s } accept\n' "${proto}" "${ports}" "${v6[*]}"
    printf '    %s dport { %s } drop\n' "${proto}" "${ports}"
  done
  printf '  }\n}\n'
}

firewall_source_filter_unit() {
  cat <<EOF
# Managed by graylog-stack deploy.sh - loads the allowed-source filter for
# the published Graylog ports at boot. Removed when
# FIREWALL_ALLOWED_SOURCES is cleared, and by uninstall.sh.
[Unit]
Description=Graylog stack - allowed-source filter for published ports
Before=graylog.service
After=network-pre.target

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/usr/sbin/nft -f ${SOURCE_FILTER_NFT}
ExecStop=-/usr/sbin/nft delete table inet graylog_stack

[Install]
WantedBy=multi-user.target
EOF
}

# firewall_source_filter_remove - stop and delete the filter; safe if absent.
firewall_source_filter_remove() {
  if [[ -f "${SOURCE_FILTER_UNIT}" ]]; then
    systemctl disable --now "${SOURCE_FILTER_UNIT_NAME}" >/dev/null 2>&1 || true
    rm -f "${SOURCE_FILTER_UNIT}"
    systemctl daemon-reload
  fi
  nft delete table inet graylog_stack >/dev/null 2>&1 || true
  rm -f "${SOURCE_FILTER_NFT}"
  rmdir "$(dirname "${SOURCE_FILTER_NFT}")" 2>/dev/null || true
}

# Legacy helpers: default-zone port rules as recorded by earlier versions in
# ${MANIFEST_FILE}.firewall_ports_added.
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
