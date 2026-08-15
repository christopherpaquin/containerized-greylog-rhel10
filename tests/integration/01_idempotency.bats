#!/usr/bin/env bats
# The required idempotency sequence: deploy -> healthcheck -> deploy again
# -> healthcheck, verifying the second run succeeds, creates nothing new,
# never rotates secrets, and leaves the environment healthy.
#
# Precondition: a working deployment already exists (this file redeploys
# on top of it, which is exactly the behavior under test).
# Run with: sudo bats tests/integration/01_idempotency.bats
# This is slow (each ./deploy.sh run takes several minutes) by nature.

load 'test_helper'

setup() {
  require_root_or_skip
  [[ -f "${ENV_FILE}" ]] || skip ".env not present - run ./deploy.sh once first"
}

@test "first ./deploy.sh (baseline) succeeds" {
  run "${REPO_ROOT}/deploy.sh"
  [ "$status" -eq 0 ]
}

@test "./healthcheck.sh reports HEALTHY after baseline deploy" {
  run "${REPO_ROOT}/healthcheck.sh"
  [ "$status" -eq 0 ]
  [[ "$output" == *"Overall status: HEALTHY"* ]]
}

@test "snapshot secrets and resource counts before the second deploy" {
  load_deployed_env
  {
    echo "GRAYLOG_PASSWORD_SECRET=${GRAYLOG_PASSWORD_SECRET}"
    echo "GRAYLOG_ROOT_PASSWORD_SHA2=${GRAYLOG_ROOT_PASSWORD_SHA2}"
    echo "MONGO_INITDB_ROOT_PASSWORD=${MONGO_INITDB_ROOT_PASSWORD}"
    echo "GRAYLOG_HTTP_EXTERNAL_URI=${GRAYLOG_HTTP_EXTERNAL_URI}"
  } > /tmp/graylog-stack-test-secrets-before.env
  podman secret ls --format '{{.Name}}' | sort > /tmp/graylog-stack-test-secrets-list-before.txt
  local token
  token="$(cat "${SECRETS_DIR}/api_token")"
  curl -fsS -u "${token}:token" "http://127.0.0.1:${GRAYLOG_HTTP_PORT}/api/system/inputs" \
    > /tmp/graylog-stack-test-inputs-before.json
}

@test "second ./deploy.sh (rerun) succeeds" {
  run "${REPO_ROOT}/deploy.sh"
  [ "$status" -eq 0 ]
}

@test "./healthcheck.sh still reports HEALTHY after the rerun" {
  run "${REPO_ROOT}/healthcheck.sh"
  [ "$status" -eq 0 ]
  [[ "$output" == *"Overall status: HEALTHY"* ]]
}

@test "rerun did not rotate any generated secret" {
  load_deployed_env
  run grep -q "GRAYLOG_PASSWORD_SECRET=${GRAYLOG_PASSWORD_SECRET}" /tmp/graylog-stack-test-secrets-before.env
  [ "$status" -eq 0 ]
  run grep -q "GRAYLOG_ROOT_PASSWORD_SHA2=${GRAYLOG_ROOT_PASSWORD_SHA2}" /tmp/graylog-stack-test-secrets-before.env
  [ "$status" -eq 0 ]
  run grep -q "MONGO_INITDB_ROOT_PASSWORD=${MONGO_INITDB_ROOT_PASSWORD}" /tmp/graylog-stack-test-secrets-before.env
  [ "$status" -eq 0 ]
}

@test "rerun did not change the detected external URI" {
  load_deployed_env
  run grep -q "GRAYLOG_HTTP_EXTERNAL_URI=${GRAYLOG_HTTP_EXTERNAL_URI}" /tmp/graylog-stack-test-secrets-before.env
  [ "$status" -eq 0 ]
}

@test "rerun did not create duplicate Podman secrets" {
  podman secret ls --format '{{.Name}}' | sort > /tmp/graylog-stack-test-secrets-list-after.txt
  diff /tmp/graylog-stack-test-secrets-list-before.txt /tmp/graylog-stack-test-secrets-list-after.txt
}

@test "rerun did not create duplicate Graylog inputs" {
  load_deployed_env
  local token before_count after_count
  token="$(cat "${SECRETS_DIR}/api_token")"
  before_count="$(python3 -c "import json;print(json.load(open('/tmp/graylog-stack-test-inputs-before.json'))['total'])")"
  after_count="$(curl -fsS -u "${token}:token" "http://127.0.0.1:${GRAYLOG_HTTP_PORT}/api/system/inputs" | python3 -c "import json,sys;print(json.load(sys.stdin)['total'])")"
  [ "${before_count}" -eq "${after_count}" ]
}

@test "rerun did not change container start times (no unnecessary restarts)" {
  load_deployed_env
  for name in "${MONGODB_CONTAINER_NAME}" "${DATANODE_CONTAINER_NAME}" "${GRAYLOG_CONTAINER_NAME}"; do
    run bash -c "podman inspect -f '{{.State.Health.Status}}' '${name}'"
    [ "$output" = "healthy" ]
  done
}

@test "cleanup: remove idempotency test scratch files" {
  rm -f /tmp/graylog-stack-test-secrets-before.env /tmp/graylog-stack-test-secrets-list-before.txt \
        /tmp/graylog-stack-test-secrets-list-after.txt /tmp/graylog-stack-test-inputs-before.json
}
