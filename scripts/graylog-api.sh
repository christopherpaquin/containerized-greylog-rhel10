#!/usr/bin/env bash
# Graylog REST API helpers - shared by deploy.sh (post-deploy provisioning)
# and healthcheck.sh (readiness + end-to-end ingestion test). Sourced,
# never executed directly. Requires lib.sh to already be sourced.
#
# Style note: every command substitution that is allowed to fail is written
# as `if ! var="$(...)"; then ...`, never `var="$(...)" || ...`. Under
# `set -E`, a failing command *inside* a `$(...)` subshell fires the
# caller's inherited ERR trap immediately, regardless of how the outer
# statement plans to handle the exit code - `||` does not protect against
# this, but being the direct condition of an `if`/`while` does (a documented
# bash exemption), which is what keeps deploy.sh's diagnostics from firing
# on expected, handled failures like a 404 existence check.

# 127.0.0.1 is one of the certificate's SANs, so these calls verify the
# server against the deployment's own self-signed certificate.
GRAYLOG_API_BASE="https://127.0.0.1:${GRAYLOG_HTTP_PORT}/api"
GRAYLOG_API_CACERT="${GRAYLOG_TLS_DIR}/cert.pem"

# graylog_curl <method> <path> [json_body]
# Auths with $GRAYLOG_API_USER / $GRAYLOG_API_PASS (either the admin
# username/password on first run, or the "token"/<token> convention on
# later runs). Prints the response body; caller checks $? / status via -w.
graylog_curl() {
  local method="$1" path="$2" body="${3:-}"
  local args=(-fsS --cacert "${GRAYLOG_API_CACERT}" -X "${method}" -u "${GRAYLOG_API_USER}:${GRAYLOG_API_PASS}"
              -H 'X-Requested-By: graylog-stack-deploy' -H 'Accept: application/json')
  if [[ -n "${body}" ]]; then
    args+=(-H 'Content-Type: application/json' -d "${body}")
  fi
  curl "${args[@]}" "${GRAYLOG_API_BASE}${path}"
}

graylog_api_reachable() {
  curl -fsS -m 5 --cacert "${GRAYLOG_API_CACERT}" "${GRAYLOG_API_BASE}/system/lbstatus" >/dev/null 2>&1
}

# graylog_ensure_automation_user <root_user> <root_pass> <username>
# The built-in root user (GRAYLOG_ROOT_USERNAME) is a synthetic account with
# no real MongoDB-backed user ID, so it cannot own API access tokens - the
# tokens API requires a real 24-hex user ID. Create (or reuse) a dedicated
# Admin-role user for automation instead, and echo its user ID.
graylog_ensure_automation_user() {
  local root_user="$1" root_pass="$2" username="$3"
  local resp
  if resp="$(GRAYLOG_API_USER="${root_user}" GRAYLOG_API_PASS="${root_pass}" \
             graylog_curl GET "/users/${username}" 2>/dev/null)"; then
    printf '%s' "${resp}" | jq -r '.id'
    return 0
  fi
  local throwaway_password payload
  throwaway_password="$(gen_secret 40)" # never needed again - token auth only
  payload="$(jq -n --arg u "${username}" --arg p "${throwaway_password}" '{
    username: $u,
    email: ($u + "@example.invalid"),
    first_name: "Graylog",
    last_name: "Stack Automation",
    password: $p,
    roles: ["Admin"],
    permissions: []
  }')"
  if ! GRAYLOG_API_USER="${root_user}" GRAYLOG_API_PASS="${root_pass}" \
       graylog_curl POST "/users" "${payload}" >/dev/null; then
    return 1
  fi
  if ! resp="$(GRAYLOG_API_USER="${root_user}" GRAYLOG_API_PASS="${root_pass}" \
               graylog_curl GET "/users/${username}")"; then
    return 1
  fi
  printf '%s' "${resp}" | jq -r '.id'
}

# graylog_token_valid <token> - true if Graylog accepts the token.
graylog_token_valid() {
  GRAYLOG_API_USER="$1" GRAYLOG_API_PASS="token" graylog_curl GET "/system" >/dev/null 2>&1
}

# graylog_create_api_token <root_user> <root_pass> <user_id> <token_name> <ttl>
# Token values are only ever returned at creation time (Graylog never
# exposes them again via GET), so this always mints a fresh token - callers
# are expected to persist the result themselves. The TTL (ISO-8601 duration)
# is passed explicitly: without one Graylog applies its default of 30 days,
# after which every automated call would start failing with 401.
graylog_create_api_token() {
  local root_user="$1" root_pass="$2" user_id="$3" token_name="$4" ttl="$5"
  local resp body
  body="$(jq -n --arg ttl "${ttl}" '{token_ttl: $ttl}')"
  if ! resp="$(GRAYLOG_API_USER="${root_user}" GRAYLOG_API_PASS="${root_pass}" \
               graylog_curl POST "/users/${user_id}/tokens/${token_name}" "${body}")"; then
    return 1
  fi
  printf '%s' "${resp}" | jq -r '.token'
}

# graylog_input_tls_state <title>
# Prints "absent", "tls" or "plain" for the input with this title, reading
# back what Graylog actually stored rather than what was requested.
graylog_input_tls_state() {
  local title="$1" resp
  if ! resp="$(graylog_curl GET "/system/inputs")"; then
    return 1
  fi
  printf '%s' "${resp}" | jq -r --arg t "${title}" '
    [.inputs[]? | select(.title==$t)] as $m
    | if ($m | length) == 0 then "absent"
      elif $m[0].attributes.tls_enable == true then "tls"
      else "plain" end'
}

# graylog_ensure_syslog_input <title> <input_class> <port> [bind_address] [tls:true|false]
# Idempotently creates a global Syslog input if one with this title doesn't
# already exist. With tls=true the input uses the deployment's certificate
# and key, and the call only succeeds if Graylog reports the stored input as
# TLS-enabled - an existing plaintext input under that title is an error,
# never silently accepted.
graylog_ensure_syslog_input() {
  local title="$1" class="$2" port="$3" bind="${4:-0.0.0.0}" tls="${5:-false}"
  local state
  if ! state="$(graylog_input_tls_state "${title}")"; then
    return 1
  fi
  if [[ "${state}" != "absent" ]]; then
    [[ "${tls}" != "true" || "${state}" == "tls" ]]
    return
  fi
  local payload
  payload="$(jq -n --arg title "${title}" --arg type "${class}" --argjson port "${port}" --arg bind "${bind}" \
                  --argjson tls "${tls}" --arg dir "${GRAYLOG_TLS_CONTAINER_DIR}" '{
    title: $title,
    type: $type,
    global: true,
    configuration: ({
      bind_address: $bind,
      port: $port,
      recv_buffer_size: 262144,
      number_worker_threads: 2,
      force_rdns: false,
      allow_override_date: true,
      store_full_message: false,
      expand_structured_data: false,
      tls_enable: $tls
    } + (if $tls then {
      tls_cert_file: ($dir + "/cert.pem"),
      tls_key_file: ($dir + "/key.pem"),
      tls_client_auth: "disabled"
    } else {} end))
  }')"
  if ! graylog_curl POST "/system/inputs" "${payload}" >/dev/null; then
    return 1
  fi
  if [[ "${tls}" == "true" ]]; then
    if ! state="$(graylog_input_tls_state "${title}")"; then
      return 1
    fi
    [[ "${state}" == "tls" ]]
  fi
}

# graylog_delete_input_by_title <title>
# Removes every input with this title. Succeeds if there was nothing to remove.
graylog_delete_input_by_title() {
  local title="$1" resp id
  if ! resp="$(graylog_curl GET "/system/inputs")"; then
    return 1
  fi
  while IFS= read -r id; do
    [[ -n "${id}" ]] || continue
    if ! graylog_curl DELETE "/system/inputs/${id}" >/dev/null; then
      return 1
    fi
  done < <(printf '%s' "${resp}" | jq -r --arg t "${title}" '.inputs[]? | select(.title==$t) | .id')
}

# graylog_set_cert_renewal_lifetime <ISO8601 duration, e.g. P3650D>
# Backed by Graylog's generic cluster-config store (the same mechanism the
# Data Node preflight UI uses), keyed by the RenewalPolicy config class.
graylog_set_cert_renewal_lifetime() {
  local lifetime="$1"
  local payload
  payload="$(jq -n --arg lt "${lifetime}" '{mode: "AUTOMATIC", certificate_lifetime: $lt}')"
  graylog_curl PUT "/system/cluster_config/org.graylog2.plugin.certificates.RenewalPolicy" "${payload}" >/dev/null
}
