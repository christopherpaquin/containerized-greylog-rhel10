#!/usr/bin/env bats
# Quadlet template rendering (envsubst-based, change detection).

load 'test_helper'

setup() {
  common_setup
  source "${REPO_ROOT}/scripts/lib.sh"
  TEMPLATE="${TEST_TMP}/example.container.tmpl"
  DEST="${TEST_TMP}/example.container"
  cat > "${TEMPLATE}" <<'EOF'
[Container]
Image=${FOO_IMAGE}:${FOO_VERSION}
Environment=STATIC=literal-$dollar-stays
EOF
}

teardown() { common_teardown; }

@test "render_quadlet substitutes only the listed variables" {
  export FOO_IMAGE="myimage"
  export FOO_VERSION="1.2.3"
  render_quadlet "${TEMPLATE}" "${DEST}" FOO_IMAGE FOO_VERSION
  grep -q "Image=myimage:1.2.3" "${DEST}"
  grep -q 'literal-$dollar-stays' "${DEST}"
}

@test "render_quadlet reports changed on first render" {
  export FOO_IMAGE="myimage"
  export FOO_VERSION="1.2.3"
  run render_quadlet "${TEMPLATE}" "${DEST}" FOO_IMAGE FOO_VERSION
  [ "$status" -eq 0 ]
}

@test "render_quadlet reports unchanged when content is identical" {
  export FOO_IMAGE="myimage"
  export FOO_VERSION="1.2.3"
  render_quadlet "${TEMPLATE}" "${DEST}" FOO_IMAGE FOO_VERSION
  run render_quadlet "${TEMPLATE}" "${DEST}" FOO_IMAGE FOO_VERSION
  [ "$status" -eq 1 ]
}

@test "render_quadlet reports changed when a substituted value changes" {
  export FOO_IMAGE="myimage"
  export FOO_VERSION="1.2.3"
  render_quadlet "${TEMPLATE}" "${DEST}" FOO_IMAGE FOO_VERSION
  FOO_VERSION="1.2.4"
  run render_quadlet "${TEMPLATE}" "${DEST}" FOO_IMAGE FOO_VERSION
  [ "$status" -eq 0 ]
  grep -q "1.2.4" "${DEST}"
}

@test "render_quadlet does not touch the destination file when unchanged (mtime-friendly)" {
  export FOO_IMAGE="myimage"
  export FOO_VERSION="1.2.3"
  render_quadlet "${TEMPLATE}" "${DEST}" FOO_IMAGE FOO_VERSION
  before="$(stat -c '%Y.%N' "${DEST}" 2>/dev/null || stat -c '%Y' "${DEST}")"
  sleep 1.1
  render_quadlet "${TEMPLATE}" "${DEST}" FOO_IMAGE FOO_VERSION || true
  after="$(stat -c '%Y.%N' "${DEST}" 2>/dev/null || stat -c '%Y' "${DEST}")"
  [ "$before" = "$after" ]
}

@test "rendered Quadlet file is world-readable (0644), not secret-bearing" {
  export FOO_IMAGE="myimage"
  export FOO_VERSION="1.2.3"
  render_quadlet "${TEMPLATE}" "${DEST}" FOO_IMAGE FOO_VERSION
  perms="$(stat -c '%a' "${DEST}")"
  [ "$perms" = "644" ]
}

@test "credentials are wired via Secret=, never a literal Environment=...PASSWORD/SECRET value" {
  # Passwords/secrets must arrive via Podman's Secret= mechanism (Secret=name,type=env,target=VAR),
  # never hard-coded (or even template-substituted) into an Environment= line.
  ! grep -rn -E '^Environment=.*(PASSWORD|_SECRET)=' "${REPO_ROOT}/quadlet/"*.container
}

@test "every credential-shaped env target is backed by a Secret= line" {
  for target in GRAYLOG_PASSWORD_SECRET GRAYLOG_DATANODE_PASSWORD_SECRET GRAYLOG_ROOT_PASSWORD_SHA2 MONGO_INITDB_ROOT_PASSWORD GRAYLOG_MONGODB_URI GRAYLOG_DATANODE_MONGODB_URI; do
    grep -rq "target=${target}" "${REPO_ROOT}/quadlet/"*.container || \
      { echo "no Secret= line targets ${target}"; return 1; }
  done
}
