#!/usr/bin/env bash
# Removes deployment/configuration artifacts created by deploy.sh.
#
# By default, PERSISTENT DATA (MongoDB, Data Node indices, Graylog data,
# generated secrets) is left untouched, so a subsequent ./deploy.sh restores
# the exact same working stack with the exact same credentials.
#
# Pass --purge-data to additionally and irreversibly delete all persistent
# data and generated secrets. --purge-data prompts for confirmation unless
# --yes is also given.
#
# Safe to run repeatedly.

set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/lib.sh
source "${SCRIPT_DIR}/scripts/lib.sh"

PURGE_DATA=false
ASSUME_YES=false

usage() {
  cat <<EOF
Usage: $0 [--purge-data] [--yes]

  --purge-data   Also permanently delete MongoDB/Data Node/Graylog data and
                 generated secrets under \$DATA_ROOT. Irreversible.
  --yes          Do not prompt for confirmation (required for non-interactive
                 use of --purge-data).
EOF
}

for arg in "$@"; do
  case "${arg}" in
    --purge-data) PURGE_DATA=true ;;
    --yes) ASSUME_YES=true ;;
    -h|--help) usage; exit 0 ;;
    *) log_err "Unknown argument: ${arg}"; usage; exit 1 ;;
  esac
done

require_root

if [[ ! -f "${ENV_FILE}" ]]; then
  log_warn "${ENV_FILE} not found - nothing to load. Falling back to .env.example for path defaults only."
  [[ -f "${ENV_EXAMPLE_FILE}" ]] || die "Neither .env nor .env.example present; cannot determine what was deployed."
  set -a
  # shellcheck disable=SC1090
  source "${ENV_EXAMPLE_FILE}"
  set +a
else
  load_env
fi

MANIFEST_FILE="${DATA_ROOT}/.manifest"

if [[ "${PURGE_DATA}" == "true" && "${ASSUME_YES}" != "true" ]]; then
  echo "This will PERMANENTLY DELETE all Graylog stack data:"
  echo "  - MongoDB data:   ${MONGODB_DB_DIR}"
  echo "  - Data Node data: ${DATANODE_DATA_DIR}"
  echo "  - Graylog data:   ${GRAYLOG_DATA_DIR}"
  echo "  - Generated secrets and the initial admin password file"
  echo
  read -r -p "Type 'yes' to continue: " confirm
  [[ "${confirm}" == "yes" ]] || { log_info "Aborted."; exit 1; }
fi

log_step "Stopping services"
# Quadlet units are generated (their [Install] section is processed by the
# generator on every daemon-reload/boot, not via a persistent enable
# symlink), so `systemctl disable` errors with "transient or generated".
# Stopping them plus removing the source unit files (below) is sufficient
# to fully undo them.
UNITS=(graylog.service graylog-datanode.service mongodb.service graylog-network.service)
for unit in "${UNITS[@]}"; do
  if systemctl list-unit-files "${unit}" >/dev/null 2>&1; then
    systemctl stop "${unit}" >/dev/null 2>&1 || log_warn "Could not stop ${unit} (may already be gone)"
  fi
done
log_ok "Services stopped"

log_step "Removing any leftover containers"
for name in "${GRAYLOG_CONTAINER_NAME:-graylog}" "${DATANODE_CONTAINER_NAME:-graylog-datanode}" "${MONGODB_CONTAINER_NAME:-mongodb}"; do
  podman rm -f "${name}" >/dev/null 2>&1 || true
done
log_ok "Containers removed"

log_step "Removing Quadlet unit files"
if [[ -d "${QUADLET_DEST_DIR}" ]]; then
  rm -rf "${QUADLET_DEST_DIR}"
  log_ok "Removed ${QUADLET_DEST_DIR}"
else
  log_info "Nothing to remove at ${QUADLET_DEST_DIR}"
fi
systemctl daemon-reload

log_step "Removing Podman network"
bridge_iface=""
if [[ -n "${NETWORK_NAME:-}" ]] && podman network exists "${NETWORK_NAME}" 2>/dev/null; then
  # Capture the bridge interface before the network (and therefore the
  # interface) disappears, so its trusted-zone firewalld binding can be
  # cleaned up below.
  bridge_iface="$(podman network inspect "${NETWORK_NAME}" --format '{{.NetworkInterface}}' 2>/dev/null || true)"
  podman network rm "${NETWORK_NAME}" >/dev/null 2>&1 || log_warn "Could not remove network ${NETWORK_NAME} (containers may still reference it)"
  log_ok "Removed network ${NETWORK_NAME}"
else
  log_info "Network ${NETWORK_NAME:-graylog-net} not present"
fi

log_step "Removing firewalld rules created by this deployment"
if [[ -n "${bridge_iface}" ]]; then
  firewall-cmd --permanent --zone=trusted --remove-interface="${bridge_iface}" >/dev/null 2>&1 || true
  log_info "Removed trusted-zone binding for ${bridge_iface}"
fi
if [[ -f "${MANIFEST_FILE}.firewall_ports_added" ]]; then
  while IFS= read -r p; do
    [[ -n "${p}" ]] || continue
    firewall_close_port "${p}"
    log_info "Closed ${p}"
  done < "${MANIFEST_FILE}.firewall_ports_added"
fi
firewall_reload || true

log_step "Removing persistent kernel/resource-limit configuration"
for f in "${SYSCTL_DROPIN}" "${LIMITS_DROPIN}"; do
  if [[ -f "${f}" ]]; then
    rm -f "${f}"
    log_ok "Removed ${f}"
  fi
done
sysctl --system >/dev/null 2>&1 || true

log_step "Removing SELinux file-context rules"
if [[ -n "${DATA_ROOT:-}" ]]; then
  selinux_unlabel_path "${DATA_ROOT}"
  log_ok "Removed container_file_t fcontext rule for ${DATA_ROOT}"
fi

log_step "Removing deployment manifest"
rm -f "${MANIFEST_FILE}" "${MANIFEST_FILE}.packages_installed" "${MANIFEST_FILE}.firewall_ports_added"

if [[ -f "${MANIFEST_FILE}.packages_installed" ]]; then
  log_info "Packages installed by deploy.sh (not removed - shared system state): $(sort -u "${MANIFEST_FILE}.packages_installed" | xargs)"
fi

if [[ "${PURGE_DATA}" == "true" ]]; then
  log_step "Purging persistent data and secrets"
  for name in graylog-stack-password-secret graylog-stack-root-password-sha2 graylog-stack-mongo-root-password graylog-stack-mongodb-uri; do
    podman_secret_rm_if_exists "${name}"
  done
  if [[ -n "${DATA_ROOT:-}" && -d "${DATA_ROOT}" ]]; then
    rm -rf "${DATA_ROOT}"
    log_ok "Removed ${DATA_ROOT} (all data and secrets)"
  fi
else
  log_step "Preserving persistent data"
  log_info "Left in place: ${DATA_ROOT}/{mongodb,datanode,graylog,secrets} (rerun with --purge-data to delete)"
fi

echo
log_ok "Uninstall complete."
[[ "${PURGE_DATA}" == "true" ]] || log_info "Run ./deploy.sh to redeploy - existing data and credentials will be reused."
