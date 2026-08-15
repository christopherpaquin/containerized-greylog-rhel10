#!/usr/bin/env bash
# One-click deployment of the Graylog stack (MongoDB, Graylog Data Node,
# Graylog) on RHEL 10 using Podman + systemd Quadlets.
#
# Safe to run repeatedly: every step is idempotent. See README.md for
# prerequisites and usage.

set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/lib.sh
source "${SCRIPT_DIR}/scripts/lib.sh"

MANIFEST_FILE="" # set once DATA_ROOT is known (env_validate has run)

on_error() {
  local exit_code=$?
  local line=$1
  log_err "deploy.sh failed at line ${line} (exit ${exit_code})"
  log_err "Diagnostics:"
  log_err "  systemctl status mongodb.service graylog-datanode.service graylog.service"
  log_err "  journalctl -u mongodb.service -u graylog-datanode.service -u graylog.service -n 100 --no-pager"
  log_err "  podman ps -a"
  exit "${exit_code}"
}
trap 'on_error ${LINENO}' ERR

# --- 1/2: platform + privilege checks --------------------------------------
step_preflight() {
  log_step "Verifying platform"
  require_root
  require_rhel10
  log_ok "Running as root on $(. /etc/os-release && echo "$PRETTY_NAME")"
}

# --- 3/4: packages + podman -------------------------------------------------
REQUIRED_PACKAGES=(podman firewalld policycoreutils-python-utils container-selinux curl jq)

step_packages() {
  log_step "Checking required packages"
  local to_install=() pkg
  for pkg in "${REQUIRED_PACKAGES[@]}"; do
    if ! rpm -q "${pkg}" >/dev/null 2>&1; then
      to_install+=("${pkg}")
    fi
  done
  if ! command -v envsubst >/dev/null 2>&1; then
    to_install+=(gettext)
  fi
  if [[ ${#to_install[@]} -gt 0 ]]; then
    log_info "Installing: ${to_install[*]}"
    dnf install -y "${to_install[@]}"
    printf '%s\n' "${to_install[@]}" >> "${MANIFEST_FILE}.packages_installed"
  else
    log_ok "All required packages already present"
  fi
  command -v podman >/dev/null 2>&1 || die "podman still not available after install"
  log_ok "podman $(podman --version | awk '{print $3}')"
}

# --- 5/6: kernel settings ----------------------------------------------------
step_sysctl() {
  log_step "Configuring persistent kernel settings"
  local required_max_map_count=262144
  cat > "${SYSCTL_DROPIN}" <<EOF
# Managed by graylog-stack deploy.sh - safe to delete via uninstall.sh
# Data Node embeds OpenSearch, which requires a high mmap count.
vm.max_map_count=${required_max_map_count}
EOF
  sysctl -p "${SYSCTL_DROPIN}" >/dev/null
  local current
  current="$(sysctl -n vm.max_map_count)"
  [[ "${current}" -ge "${required_max_map_count}" ]] || die "vm.max_map_count is ${current}, expected >= ${required_max_map_count}"
  log_ok "vm.max_map_count=${current} (persisted in ${SYSCTL_DROPIN})"
}

# --- 7: resource limits -------------------------------------------------
step_limits() {
  log_step "Configuring resource limits"
  cat > "${LIMITS_DROPIN}" <<EOF
# Managed by graylog-stack deploy.sh - safe to delete via uninstall.sh
# Headroom for podman/conmon processes managing the stack's containers.
root soft nofile 65536
root hard nofile 65536
EOF
  log_ok "Resource limits configured (${LIMITS_DROPIN})"
}

# --- 8/9/10: filesystem hierarchy + ownership -------------------------------
step_directories() {
  log_step "Creating persistent storage hierarchy"
  ensure_dir "${DATA_ROOT}" 0 0 0755
  ensure_dir "${MONGODB_DB_DIR}" 999 999 0750
  ensure_dir "${MONGODB_CONFIGDB_DIR}" 999 999 0750
  ensure_dir "${DATANODE_DATA_DIR}" 999 999 0750
  ensure_dir "${GRAYLOG_DATA_DIR}" 1100 1100 0750
  ensure_dir "${SECRETS_DIR}" 0 0 0700
  log_ok "Directories created under ${DATA_ROOT}"
}

# --- 11/12/13: SELinux -------------------------------------------------------
step_selinux() {
  log_step "Configuring SELinux (must remain Enforcing)"
  local mode
  mode="$(getenforce)"
  [[ "${mode}" == "Enforcing" ]] || die "SELinux is '${mode}', not Enforcing. This deployment requires Enforcing mode and will not weaken it for you."
  selinux_label_path "${DATA_ROOT}"
  log_ok "SELinux Enforcing; container_file_t applied to ${DATA_ROOT}"
}

# --- 14/15/16: network + Quadlets + systemd --------------------------------
# Populated by step_quadlets with the systemd unit names whose rendered
# content actually changed this run, so step_start_services knows which
# already-running services need a `restart` (vs a no-op `start`).
CHANGED_UNITS=()

step_quadlets() {
  log_step "Installing Quadlet unit definitions"
  mkdir -p "${QUADLET_DEST_DIR}"
  # Called twice (GRAYLOG_HTTP_EXTERNAL_URI may only be known after the
  # first pass) - accumulate across both calls rather than resetting, or a
  # change detected on the first call would be lost by the second.
  local render_vars_common=(
    NETWORK_NAME
    MONGODB_IMAGE MONGODB_VERSION MONGODB_CONTAINER_NAME MONGODB_DB_DIR MONGODB_CONFIGDB_DIR
    MONGO_INITDB_DATABASE MONGO_INITDB_ROOT_USERNAME
    DATANODE_IMAGE DATANODE_VERSION DATANODE_CONTAINER_NAME DATANODE_DATA_DIR DATANODE_OPENSEARCH_HEAP
    GRAYLOG_IMAGE GRAYLOG_VERSION GRAYLOG_CONTAINER_NAME GRAYLOG_DATA_DIR
    GRAYLOG_HTTP_PORT SYSLOG_TCP_PORT SYSLOG_UDP_PORT
    GRAYLOG_HTTP_EXTERNAL_URI GRAYLOG_ROOT_USERNAME GRAYLOG_ROOT_EMAIL
    GRAYLOG_SELFSIGNED_STARTUP GRAYLOG_SERVER_JAVA_OPTS TZ
  )
  if render_quadlet "${QUADLET_SRC_DIR}/graylog.network" "${QUADLET_DEST_DIR}/graylog.network" "${render_vars_common[@]}"; then CHANGED_UNITS+=(graylog-network.service); fi
  if render_quadlet "${QUADLET_SRC_DIR}/mongodb.container" "${QUADLET_DEST_DIR}/mongodb.container" "${render_vars_common[@]}"; then CHANGED_UNITS+=(mongodb.service); fi
  if render_quadlet "${QUADLET_SRC_DIR}/graylog-datanode.container" "${QUADLET_DEST_DIR}/graylog-datanode.container" "${render_vars_common[@]}"; then CHANGED_UNITS+=(graylog-datanode.service); fi
  if render_quadlet "${QUADLET_SRC_DIR}/graylog.container" "${QUADLET_DEST_DIR}/graylog.container" "${render_vars_common[@]}"; then CHANGED_UNITS+=(graylog.service); fi

  if [[ ${#CHANGED_UNITS[@]} -gt 0 ]]; then
    log_info "Unit files changed: ${CHANGED_UNITS[*]} - reloading systemd"
    systemctl daemon-reload
  else
    log_ok "Unit files unchanged"
  fi
}

# unit_changed <unit.service> - true if step_quadlets rendered new content for it.
unit_changed() {
  local unit="$1" u
  for u in "${CHANGED_UNITS[@]}"; do [[ "${u}" == "${unit}" ]] && return 0; done
  return 1
}

# start_or_restart <unit.service>
# `systemctl start` on an already-active unit is a harmless no-op, which
# would silently skip picking up changed unit content - restart instead
# when this run actually re-rendered that unit.
start_or_restart() {
  local unit="$1"
  if unit_changed "${unit}" && systemctl is-active --quiet "${unit}"; then
    log_info "${unit} definition changed; restarting"
    systemctl restart "${unit}"
  else
    systemctl start "${unit}"
  fi
}

# --- secrets -----------------------------------------------------------------
ADMIN_PLAINTEXT_PASSWORD="" # only set in-process on first run; never persisted in .env

step_secrets() {
  log_step "Provisioning secrets"

  if [[ -z "${GRAYLOG_PASSWORD_SECRET}" ]]; then
    log_info "Generating GRAYLOG_PASSWORD_SECRET"
    local password_secret; password_secret="$(gen_secret 96)"
    persist_env_var GRAYLOG_PASSWORD_SECRET "${password_secret}"
  fi
  podman_secret_ensure graylog-stack-password-secret "${GRAYLOG_PASSWORD_SECRET}"

  if [[ -z "${MONGO_INITDB_ROOT_PASSWORD}" ]]; then
    log_info "Generating MONGO_INITDB_ROOT_PASSWORD"
    local mongo_password; mongo_password="$(gen_secret 40)"
    persist_env_var MONGO_INITDB_ROOT_PASSWORD "${mongo_password}"
  fi
  podman_secret_ensure graylog-stack-mongo-root-password "${MONGO_INITDB_ROOT_PASSWORD}"

  local mongodb_uri="mongodb://${MONGO_INITDB_ROOT_USERNAME}:${MONGO_INITDB_ROOT_PASSWORD}@${MONGODB_CONTAINER_NAME}:27017/${MONGO_INITDB_DATABASE}?authSource=admin"
  podman_secret_ensure graylog-stack-mongodb-uri "${mongodb_uri}"

  if [[ -z "${GRAYLOG_ROOT_PASSWORD_SHA2}" ]]; then
    log_info "Generating initial Graylog admin password"
    ADMIN_PLAINTEXT_PASSWORD="$(gen_secret 24)"
    local password_hash; password_hash="$(printf '%s' "${ADMIN_PLAINTEXT_PASSWORD}" | sha256_hex)"
    persist_env_var GRAYLOG_ROOT_PASSWORD_SHA2 "${password_hash}"
    umask 077
    printf 'Graylog initial admin credentials (generated %s)\nUsername: %s\nPassword: %s\n\nThis file is only written once. Store this password somewhere safe -\nit cannot be recovered from Graylog after this file is removed.\n' \
      "$(date -Is)" "${GRAYLOG_ROOT_USERNAME}" "${ADMIN_PLAINTEXT_PASSWORD}" > "${SECRETS_DIR}/admin_password.txt"
    chmod 600 "${SECRETS_DIR}/admin_password.txt"
  fi
  podman_secret_ensure graylog-stack-root-password-sha2 "${GRAYLOG_ROOT_PASSWORD_SHA2}"

  log_ok "Secrets ready (generated values, if any, preserved for future runs)"
}

step_external_uri() {
  if [[ -z "${GRAYLOG_HTTP_EXTERNAL_URI}" ]]; then
    local ip
    ip="$(ip route get 1.1.1.1 2>/dev/null | awk '/src/{for(i=1;i<=NF;i++) if($i=="src") print $(i+1)}')"
    [[ -n "${ip}" ]] || ip="127.0.0.1"
    local uri="http://${ip}:${GRAYLOG_HTTP_PORT}/"
    persist_env_var GRAYLOG_HTTP_EXTERNAL_URI "${uri}"
    log_info "Detected and persisted GRAYLOG_HTTP_EXTERNAL_URI=${GRAYLOG_HTTP_EXTERNAL_URI}"
  fi
}

# Sized from host RAM if left blank in .env, then persisted so reruns don't
# recompute (and won't clobber a value you've since tuned by hand). Follows
# Graylog's own published guidance: ~50% of RAM to the Data Node's embedded
# OpenSearch heap (capped at 31g - the JVM compressed-oops ceiling), and a
# smaller share to Graylog server itself, which is far less heap-hungry.
step_heap_sizing() {
  local total_mb
  total_mb="$(detect_total_ram_mb)"

  if [[ -z "${DATANODE_OPENSEARCH_HEAP}" ]]; then
    local heap; heap="$(heap_size_for_ram_mb "${total_mb}" 50 512 31744)"
    persist_env_var DATANODE_OPENSEARCH_HEAP "${heap}"
    log_info "Detected and persisted DATANODE_OPENSEARCH_HEAP=${heap} (50% of ${total_mb}MB host RAM)"
  fi

  if [[ -z "${GRAYLOG_SERVER_JAVA_OPTS}" ]]; then
    local heap; heap="$(heap_size_for_ram_mb "${total_mb}" 25 512 4096)"
    local opts="-Xms${heap} -Xmx${heap}"
    persist_env_var GRAYLOG_SERVER_JAVA_OPTS "${opts}"
    log_info "Detected and persisted GRAYLOG_SERVER_JAVA_OPTS=\"${opts}\" (25% of ${total_mb}MB host RAM, capped at 4g)"
  fi
}

# --- 17: enable/start services -----------------------------------------------
step_start_services() {
  log_step "Starting services (this blocks on real health checks, not just process start)"
  # Quadlet units carry their own [Install] section and are (re)enabled
  # automatically by the generator on every daemon-reload/boot; `systemctl
  # enable` on a generated unit errors with "transient or generated", so we
  # only ever `start` them here.
  start_or_restart graylog-network.service
  log_info "Starting MongoDB..."
  start_or_restart mongodb.service
  log_ok "MongoDB healthy"
  log_info "Starting Graylog Data Node (OpenSearch JVM startup can take a couple of minutes)..."
  start_or_restart graylog-datanode.service
  log_ok "Data Node healthy"
  log_info "Starting Graylog server..."
  start_or_restart graylog.service
  log_ok "Graylog healthy"
}

# --- 18: firewalld -----------------------------------------------------------
step_firewall() {
  log_step "Configuring firewalld"
  if [[ "${MANAGE_FIREWALL}" != "true" ]]; then
    log_warn "MANAGE_FIREWALL=false - skipping firewall changes. Ensure ${GRAYLOG_HTTP_PORT}/tcp, ${SYSLOG_TCP_PORT}/tcp and ${SYSLOG_UDP_PORT}/udp are reachable yourself."
    return
  fi
  systemctl enable --now firewalld >/dev/null

  # Podman's bridge interface for graylog-net has no firewalld zone by
  # default. On this host that silently breaks inter-container traffic
  # (including aardvark-dns container-name resolution) as soon as anything
  # triggers a firewalld reload - the interface falls under an implicit
  # deny instead of being treated as trusted internal traffic. External
  # exposure is controlled separately and explicitly via the PublishPort
  # mappings below, not by this zone assignment, so trusting the bridge
  # here does not widen what's reachable from outside the host.
  local bridge_iface
  bridge_iface="$(podman network inspect "${NETWORK_NAME}" --format '{{.NetworkInterface}}' 2>/dev/null || true)"
  if [[ -n "${bridge_iface}" ]]; then
    if [[ "$(firewall-cmd --get-zone-of-interface="${bridge_iface}" 2>/dev/null)" != "trusted" ]]; then
      firewall-cmd --zone=trusted --add-interface="${bridge_iface}" >/dev/null
      firewall-cmd --permanent --zone=trusted --add-interface="${bridge_iface}" >/dev/null
      log_ok "Assigned ${bridge_iface} (${NETWORK_NAME}) to the firewalld trusted zone"
    else
      log_info "${bridge_iface} (${NETWORK_NAME}) already in the trusted zone"
    fi
  else
    log_warn "Could not determine the bridge interface for ${NETWORK_NAME}; skipping trusted-zone assignment"
  fi

  local ports=("${GRAYLOG_HTTP_PORT}/tcp" "${SYSLOG_TCP_PORT}/tcp" "${SYSLOG_UDP_PORT}/udp")
  local added=()
  local p
  for p in "${ports[@]}"; do
    if firewall-cmd --query-port="${p}" >/dev/null 2>&1; then
      log_info "${p} already open"
    else
      firewall_open_port "${p}"
      added+=("${p}")
    fi
  done
  if [[ ${#added[@]} -gt 0 ]]; then
    firewall_reload
    printf '%s\n' "${added[@]}" >> "${MANIFEST_FILE}.firewall_ports_added"
    log_ok "Opened: ${added[*]}"
  else
    log_ok "All required ports already open"
  fi
}

# --- 19/20: post-deploy provisioning (syslog inputs, cert lifetime) ---------
step_provision_graylog() {
  log_step "Provisioning Graylog inputs"
  # shellcheck source=scripts/graylog-api.sh
  source "${SCRIPT_DIR}/scripts/graylog-api.sh"

  local token_file="${SECRETS_DIR}/api_token"
  local api_token=""
  if [[ -f "${token_file}" ]]; then
    api_token="$(cat "${token_file}")"
  else
    # Fall back to the one-time admin password file if this run didn't
    # generate the password itself (e.g. a prior run created it but was
    # interrupted before a token got minted).
    local admin_password="${ADMIN_PLAINTEXT_PASSWORD}"
    if [[ -z "${admin_password}" && -f "${SECRETS_DIR}/admin_password.txt" ]]; then
      admin_password="$(grep '^Password:' "${SECRETS_DIR}/admin_password.txt" | sed 's/^Password: //')"
    fi
    if [[ -n "${admin_password}" ]]; then
      wait_until "Graylog API reachable" 60 3 graylog_api_reachable
      # The built-in root user can't own API tokens (no real user ID), so
      # provision a dedicated Admin-role automation user for this once, then
      # mint its token.
      local automation_user_id=""
      if ! automation_user_id="$(graylog_ensure_automation_user "${GRAYLOG_ROOT_USERNAME}" "${admin_password}" "graylog-stack-automation")"; then
        automation_user_id=""
      fi
      if [[ -n "${automation_user_id}" && "${automation_user_id}" != "null" ]]; then
        if ! api_token="$(graylog_create_api_token "${GRAYLOG_ROOT_USERNAME}" "${admin_password}" "${automation_user_id}" "graylog-stack-deploy")"; then
          api_token=""
        fi
      fi
      if [[ -n "${api_token}" && "${api_token}" != "null" ]]; then
        umask 077
        printf '%s' "${api_token}" > "${token_file}"
        chmod 600 "${token_file}"
      fi
    else
      log_warn "No stored API token and no admin password available this run (admin_password.txt already removed). Skipping input/cert-policy provisioning; healthcheck.sh will report if inputs are missing."
      return
    fi
  fi

  if [[ -z "${api_token}" || "${api_token}" == "null" ]]; then
    log_warn "Could not obtain a Graylog API token; skipping automated input/cert-policy provisioning."
    return
  fi

  export GRAYLOG_API_USER="${api_token}"
  export GRAYLOG_API_PASS="token"

  wait_until "Graylog API reachable" 60 3 graylog_api_reachable

  if graylog_ensure_syslog_input "Syslog TCP" "org.graylog2.inputs.syslog.tcp.SyslogTCPInput" 1514; then
    log_ok "Syslog TCP input ready (container port 1514, published as ${SYSLOG_TCP_PORT}/tcp)"
  else
    log_warn "Could not confirm/create Syslog TCP input via API"
  fi

  if graylog_ensure_syslog_input "Syslog UDP" "org.graylog2.inputs.syslog.udp.SyslogUDPInput" 1514; then
    log_ok "Syslog UDP input ready (container port 1514, published as ${SYSLOG_UDP_PORT}/udp)"
  else
    log_warn "Could not confirm/create Syslog UDP input via API"
  fi

  if graylog_set_cert_renewal_lifetime "${DATANODE_CERT_LIFETIME}"; then
    log_ok "Data Node certificate lifetime set to ${DATANODE_CERT_LIFETIME}"
  else
    log_warn "Could not set certificate lifetime to ${DATANODE_CERT_LIFETIME} via API; default 30-day automatic renewal remains in effect (see docs/architecture.md)"
  fi
}

# --- 21: final report ---------------------------------------------------------
step_summary() {
  log_step "Deployment summary"
  podman ps --filter "name=^(${MONGODB_CONTAINER_NAME}|${DATANODE_CONTAINER_NAME}|${GRAYLOG_CONTAINER_NAME})\$" --format 'table {{.Names}}\t{{.Status}}\t{{.Image}}' 2>/dev/null || true
  echo
  log_ok "Graylog web UI: ${GRAYLOG_HTTP_EXTERNAL_URI}"
  log_ok "Syslog TCP: <this-host>:${SYSLOG_TCP_PORT}   Syslog UDP: <this-host>:${SYSLOG_UDP_PORT}"
  if [[ -f "${SECRETS_DIR}/admin_password.txt" ]]; then
    log_warn "Initial admin credentials were written to ${SECRETS_DIR}/admin_password.txt (root-only). Save them and consider deleting the file."
  fi
  echo
  log_info "Run ./healthcheck.sh anytime for a full status report."
}

main() {
  step_preflight
  step_packages
  step_sysctl
  step_limits

  load_env
  env_validate
  MANIFEST_FILE="${DATA_ROOT}/.manifest"
  mkdir -p "${DATA_ROOT}"

  step_directories
  step_selinux
  step_quadlets
  step_secrets
  step_external_uri
  step_heap_sizing
  # Re-render Quadlets: GRAYLOG_HTTP_EXTERNAL_URI/heap sizes may have just been detected/persisted.
  step_quadlets
  step_start_services
  step_firewall
  step_provision_graylog
  step_summary

  echo
  log_ok "Deployment complete."
  echo
  "${SCRIPT_DIR}/healthcheck.sh" || {
    log_warn "healthcheck.sh reported issues - see above for details."
    exit 1
  }
}

# Guarded so unit tests can `source` this file (to exercise functions like
# start_or_restart in isolation) without triggering a real deployment.
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  main "$@"
fi
