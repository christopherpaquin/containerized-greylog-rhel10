#!/usr/bin/env bats
# step_firewall: zone selection, source restriction, and ownership tracking
# (only rules this deployment added are ever removed). Runs against a
# stateful firewall-cmd stub whose permanent config is a plain text file.

load 'test_helper'

setup() {
  common_setup
  source "${REPO_ROOT}/scripts/lib.sh"
  ENV_FILE="${TEST_TMP}/.env"
  cp "${REPO_ROOT}/.env.example" "${ENV_FILE}"
  chmod 600 "${ENV_FILE}"
  load_env
  # shellcheck source=deploy.sh
  source "${REPO_ROOT}/deploy.sh"
  MANIFEST_FILE="${TEST_TMP}/.manifest"
  RULES="${MANIFEST_FILE}.firewall_rules"
  FW_STATE="${TEST_TMP}/fw_state"   # lines: <zone>|port|<p>  or  <zone>|rich|<rule>
  : > "${FW_STATE}"
  export FW_STATE
  stub systemctl 0
  stub podman 0 "podman1"
  stub nft 0
  SOURCE_FILTER_NFT="${TEST_TMP}/etc/source-filter.nft"
  SOURCE_FILTER_UNIT="${TEST_TMP}/etc/${SOURCE_FILTER_UNIT_NAME}"
  stub ip 0 "1.1.1.1 via 10.1.2.1 dev eth0 src 10.1.2.3 uid 0"
  cat > "${STUB_BIN}/firewall-cmd" <<'STUB'
#!/usr/bin/env bash
zone=""; op=""; kind=""; value=""
for a in "$@"; do
  case "$a" in
    --get-default-zone) echo "${FW_DEFAULT_ZONE:-public}"; exit 0 ;;
    --get-zone-of-interface=podman1) echo "${FW_BRIDGE_ZONE:-}"; [[ -n "${FW_BRIDGE_ZONE:-}" ]]; exit ;;
    --get-zone-of-interface=*) echo "${FW_ACTIVE_ZONE:-public}"; exit 0 ;;
    --add-interface=*|--remove-interface=*) echo "$*" >> "${FW_STATE}.iface"; exit 0 ;;
    --reload) echo reload >> "${FW_STATE}.reloads"; exit 0 ;;
    --list-ports) [[ "${zone}" != "nosuchzone" ]]; exit ;;
    --zone=*) zone="${a#--zone=}" ;;
    --query-port=*|--add-port=*|--remove-port=*) op="${a%%-port=*}"; op="${op#--}"; kind=port; value="${a#*=}" ;;
    --query-rich-rule=*|--add-rich-rule=*|--remove-rich-rule=*) op="${a%%-rich-rule=*}"; op="${op#--}"; kind=rich; value="${a#*=}" ;;
  esac
done
line="${zone}|${kind}|${value}"
case "${op}" in
  query)  grep -qxF -- "${line}" "${FW_STATE}" ;;
  add)    grep -qxF -- "${line}" "${FW_STATE}" || echo "${line}" >> "${FW_STATE}" ;;
  remove) [[ -n "${FW_REMOVE_BROKEN:-}" ]] && exit 1
          grep -vxF -- "${line}" "${FW_STATE}" > "${FW_STATE}.new" || true; mv "${FW_STATE}.new" "${FW_STATE}" ;;
  *) exit 0 ;;
esac
STUB
  chmod +x "${STUB_BIN}/firewall-cmd"
}

teardown() { common_teardown; }

refute() {
  if "$@"; then return 1; fi
}

@test "firewall_source_valid accepts addresses and CIDRs, rejects junk" {
  firewall_source_valid 10.20.0.0/16
  firewall_source_valid 192.168.5.10
  firewall_source_valid fd00:1234::/48
  refute firewall_source_valid 10.20.0.0/33
  refute firewall_source_valid 300.1.1.1
  refute firewall_source_valid lab-net
  refute firewall_source_valid '10.0.0.1" accept'
}

@test "env_validate rejects a malformed FIREWALL_ALLOWED_SOURCES entry" {
  FIREWALL_ALLOWED_SOURCES="10.20.0.0/16, not-a-cidr"
  run env_validate
  [ "$status" -ne 0 ]
  [[ "$output" == *"not-a-cidr"* ]]
}

@test "no sources: plain port rules in the zone of the default-route interface" {
  export FW_ACTIVE_ZONE=internal FW_DEFAULT_ZONE=public
  step_firewall >/dev/null 2>&1
  grep -qxF "internal|port|9000/tcp" "${FW_STATE}"
  grep -qxF "internal|port|1514/tcp" "${FW_STATE}"
  grep -qxF "internal|port|1514/udp" "${FW_STATE}"
  refute grep -q "^public|" "${FW_STATE}"
  [ "$(wc -l < "${RULES}")" -eq 3 ]
}

@test "FIREWALL_ZONE overrides detection, and an unknown zone is refused" {
  FIREWALL_ZONE=work
  step_firewall >/dev/null 2>&1
  grep -qxF "work|port|9000/tcp" "${FW_STATE}"
  FIREWALL_ZONE=nosuchzone
  run step_firewall
  [ "$status" -ne 0 ]
}

@test "sources set: one rich rule per source and port, and no plain port rules" {
  FIREWALL_ALLOWED_SOURCES="10.20.0.0/16, fd00:1::/64"
  step_firewall >/dev/null 2>&1
  grep -qxF 'public|rich|rule family="ipv4" source address="10.20.0.0/16" port port="9000" protocol="tcp" accept' "${FW_STATE}"
  grep -qxF 'public|rich|rule family="ipv6" source address="fd00:1::/64" port port="1514" protocol="udp" accept' "${FW_STATE}"
  refute grep -q "|port|" "${FW_STATE}"
  [ "$(wc -l < "${FW_STATE}")" -eq 6 ]
}

@test "rerun with unchanged settings changes nothing and does not reload" {
  FIREWALL_ALLOWED_SOURCES="10.20.0.0/16"
  step_firewall >/dev/null 2>&1
  before="$(cat "${FW_STATE}" "${RULES}")"
  rm -f "${FW_STATE}.reloads"
  step_firewall >/dev/null 2>&1
  [ "$(cat "${FW_STATE}" "${RULES}")" = "${before}" ]
  [ ! -e "${FW_STATE}.reloads" ]
}

@test "switching from open to restricted replaces the port rules we added" {
  step_firewall >/dev/null 2>&1
  FIREWALL_ALLOWED_SOURCES="10.20.0.0/16"
  step_firewall >/dev/null 2>&1
  refute grep -q "|port|" "${FW_STATE}"
  [ "$(grep -c '|rich|' "${FW_STATE}")" -eq 3 ]
  # ...and back again
  FIREWALL_ALLOWED_SOURCES=""
  step_firewall >/dev/null 2>&1
  refute grep -q "|rich|" "${FW_STATE}"
  [ "$(grep -c '|port|' "${FW_STATE}")" -eq 3 ]
}

@test "a pre-existing port rule is never owned or removed, and restriction warns about it" {
  echo "public|port|9000/tcp" >> "${FW_STATE}"
  step_firewall >/dev/null 2>&1
  refute grep -qxF "public|port|9000/tcp" "${RULES}"
  FIREWALL_ALLOWED_SOURCES="10.20.0.0/16"
  run step_firewall
  [ "$status" -eq 0 ]
  [[ "$output" == *"9000/tcp is also open to any source"* ]]
  grep -qxF "public|port|9000/tcp" "${FW_STATE}"
}

@test "TLS syslog port is added when enabled and removed when disabled or moved" {
  SYSLOG_TLS_ENABLED=true
  step_firewall >/dev/null 2>&1
  grep -qxF "public|port|6514/tcp" "${FW_STATE}"
  SYSLOG_TLS_PORT=7514
  step_firewall >/dev/null 2>&1
  refute grep -qxF "public|port|6514/tcp" "${FW_STATE}"
  grep -qxF "public|port|7514/tcp" "${FW_STATE}"
  SYSLOG_TLS_ENABLED=false
  step_firewall >/dev/null 2>&1
  refute grep -q "514/tcp$" <(grep -v "|1514/tcp$" "${FW_STATE}")
  [ "$(wc -l < "${RULES}")" -eq 3 ]
}

@test "a rule that cannot be removed fails the deploy and stays recorded as owned" {
  SYSLOG_TLS_ENABLED=true
  step_firewall >/dev/null 2>&1
  SYSLOG_TLS_ENABLED=false
  export FW_REMOVE_BROKEN=1
  run step_firewall
  [ "$status" -ne 0 ]
  [[ "$output" == *"still in place"* ]]
  grep -qxF "public|port|6514/tcp" "${RULES}"
}

@test "legacy default-zone manifest entries are adopted and reconciled" {
  export FW_ACTIVE_ZONE=internal FW_DEFAULT_ZONE=public
  printf '%s\n' "public|port|9000/tcp" "public|port|1514/tcp" "public|port|1514/udp" > "${FW_STATE}"
  printf '%s\n' 9000/tcp 1514/tcp 1514/udp > "${MANIFEST_FILE}.firewall_ports_added"
  step_firewall >/dev/null 2>&1
  refute grep -q "^public|" "${FW_STATE}"
  [ "$(grep -c '^internal|port|' "${FW_STATE}")" -eq 3 ]
  [ ! -e "${MANIFEST_FILE}.firewall_ports_added" ]
}

@test "trusted-zone binding is recorded only when deploy.sh created it" {
  step_firewall >/dev/null 2>&1
  [ "$(cat "${MANIFEST_FILE}.firewall_trusted_iface")" = "podman1" ]
}

@test "an already-trusted bridge is not recorded as ours" {
  export FW_BRIDGE_ZONE=trusted
  step_firewall >/dev/null 2>&1
  [ ! -e "${MANIFEST_FILE}.firewall_trusted_iface" ]
  [ ! -e "${FW_STATE}.iface" ]
}

@test "uninstall.sh only removes a trusted-zone binding recorded in the manifest" {
  grep -q 'firewall_trusted_iface' "${REPO_ROOT}/uninstall.sh"
  refute grep -q 'remove-interface="${bridge_iface}"' "${REPO_ROOT}/uninstall.sh"
}

@test "source filter ruleset accepts listed sources per protocol and drops the rest" {
  run firewall_source_filter_ruleset podman1 "10.20.0.0/16, fd00:1::/64" 9000/tcp 1514/tcp 1514/udp
  [ "$status" -eq 0 ]
  [[ "$output" == *"type filter hook prerouting priority -150"* ]]
  [[ "$output" == *'iifname "podman1" accept'* ]]
  [[ "$output" == *"tcp dport { 9000,1514 } ip saddr { 10.20.0.0/16 } accept"* ]]
  [[ "$output" == *"tcp dport { 9000,1514 } ip6 saddr { fd00:1::/64 } accept"* ]]
  [[ "$output" == *"tcp dport { 9000,1514 } drop"* ]]
  [[ "$output" == *"udp dport { 1514 } ip saddr { 10.20.0.0/16 } accept"* ]]
  [[ "$output" == *"udp dport { 1514 } drop"* ]]
}

@test "source filter is installed and (re)loaded when sources are set" {
  FIREWALL_ALLOWED_SOURCES="10.20.0.0/16"
  step_firewall >/dev/null 2>&1
  grep -q "ip saddr { 10.20.0.0/16 } accept" "${SOURCE_FILTER_NFT}"
  grep -q "ExecStart=/usr/sbin/nft -f ${SOURCE_FILTER_NFT}" "${SOURCE_FILTER_UNIT}"
  calls_of systemctl | grep -q "^enable ${SOURCE_FILTER_UNIT_NAME}$"
  calls_of systemctl | grep -q "^restart ${SOURCE_FILTER_UNIT_NAME}$"
}

@test "source filter includes the TLS syslog port only while it is enabled" {
  FIREWALL_ALLOWED_SOURCES="10.20.0.0/16"
  SYSLOG_TLS_ENABLED=true
  step_firewall >/dev/null 2>&1
  grep -q "tcp dport { 9000,1514,6514 } drop" "${SOURCE_FILTER_NFT}"
  SYSLOG_TLS_ENABLED=false
  step_firewall >/dev/null 2>&1
  grep -q "tcp dport { 9000,1514 } drop" "${SOURCE_FILTER_NFT}"
}

@test "source filter is removed when the source list is cleared" {
  FIREWALL_ALLOWED_SOURCES="10.20.0.0/16"
  step_firewall >/dev/null 2>&1
  FIREWALL_ALLOWED_SOURCES=""
  step_firewall >/dev/null 2>&1
  [ ! -e "${SOURCE_FILTER_NFT}" ]
  [ ! -e "${SOURCE_FILTER_UNIT}" ]
  calls_of systemctl | grep -q "^disable --now ${SOURCE_FILTER_UNIT_NAME}$"
  calls_of nft | grep -q "^delete table inet graylog_stack$"
}

@test "deploy fails if the source filter cannot be loaded" {
  FIREWALL_ALLOWED_SOURCES="10.20.0.0/16"
  cat > "${STUB_BIN}/systemctl" <<EOF
#!/usr/bin/env bash
[[ "\$1" == "restart" ]] && exit 1
exit 0
EOF
  run step_firewall
  [ "$status" -ne 0 ]
  [[ "$output" == *"allowed-source filter"* ]]
}
