#!/usr/bin/env bats
# Secret-generation and persistence behavior.

load 'test_helper'

setup() {
  common_setup
  source "${REPO_ROOT}/scripts/lib.sh"
}

teardown() { common_teardown; }

@test "gen_secret produces a string of the requested length" {
  run gen_secret 32
  [ "$status" -eq 0 ]
  [ "${#output}" -eq 32 ]
}

@test "gen_secret default length is 96" {
  run gen_secret
  [ "$status" -eq 0 ]
  [ "${#output}" -eq 96 ]
}

@test "gen_secret output is alphanumeric only" {
  run gen_secret 64
  [[ "$output" =~ ^[A-Za-z0-9]+$ ]]
}

@test "gen_secret produces different values on successive calls" {
  a="$(gen_secret 32)"
  b="$(gen_secret 32)"
  [ "$a" != "$b" ]
}

@test "sha256_hex matches a known vector" {
  result="$(printf '%s' "hello" | sha256_hex)"
  [ "$result" = "2cf24dba5fb0a30e26e83b2ac5b9e29e1b161e5c1fa7425e73043362938b9824" ]
}

@test "podman_secret_ensure creates the secret when it does not exist" {
  stub podman 0
  # `podman secret exists` must fail (not found) so create is attempted.
  cat > "${STUB_BIN}/podman" <<EOF
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "${TEST_TMP}/calls_podman"
if [[ "\$1 \$2" == "secret exists" ]]; then
  exit 1
fi
if [[ "\$1 \$2" == "secret create" ]]; then
  cat > /dev/null
  echo "fake-secret-id"
  exit 0
fi
exit 0
EOF
  chmod +x "${STUB_BIN}/podman"
  run podman_secret_ensure my-secret "supersecretvalue"
  [ "$status" -eq 0 ]
  calls_of podman | grep -q "secret create my-secret -"
}

@test "podman_secret_ensure is a no-op when the secret already exists (preserves value)" {
  cat > "${STUB_BIN}/podman" <<EOF
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "${TEST_TMP}/calls_podman"
if [[ "\$1 \$2" == "secret exists" ]]; then
  exit 0
fi
if [[ "\$1 \$2" == "secret create" ]]; then
  echo "SHOULD NOT BE CALLED" >&2
  exit 1
fi
exit 0
EOF
  chmod +x "${STUB_BIN}/podman"
  run podman_secret_ensure my-secret "supersecretvalue"
  [ "$status" -eq 0 ]
  ! calls_of podman | grep -q "secret create"
}
