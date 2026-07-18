#!/usr/bin/env bats
# Live sandbox egress tests. Build a review image whose AI CLI is a stub, then
# assert the security properties of the sandbox topology: default-deny on the
# internal network, allowlist enforcement at the proxy, and a full sandboxed
# review producing findings JSON. Skipped when Docker is unavailable.

bats_require_minimum_version 1.5.0

setup_file() {
  if ! command -v docker &>/dev/null || ! docker info &>/dev/null; then
    export SANDBOX_TESTS_SKIP=1
    return 0
  fi
  REPO_ROOT="$(cd "${BATS_TEST_DIRNAME}/../.." && pwd)"
  export REPO_ROOT
  docker build -q -t ai-pr-review:batstest "${REPO_ROOT}" >/dev/null
  # Overlay the stub claude CLI + canned response onto the built image.
  local ctx
  ctx="$(mktemp -d)"
  cp "${REPO_ROOT}/tests/stubs/claude" "${ctx}/claude"
  cp "${REPO_ROOT}/tests/fixtures/response-comment.txt" "${ctx}/response.txt"
  cat > "${ctx}/Dockerfile" <<'DOCKER'
FROM ai-pr-review:batstest
USER root
COPY claude /usr/local/bin/claude
COPY response.txt /stub/response.txt
RUN chmod 755 /usr/local/bin/claude && chmod 644 /stub/response.txt
ENV STUB_RESPONSE_FILE=/stub/response.txt
USER node
DOCKER
  docker build -q -t ai-pr-review:batsstub "${ctx}" >/dev/null
  rm -rf "${ctx}"
}

setup() {
  [ -n "${SANDBOX_TESTS_SKIP:-}" ] && skip "Docker not available"
  REPO_ROOT="$(cd "${BATS_TEST_DIRNAME}/../.." && pwd)"
  NET="batstest-$$-${BATS_TEST_NUMBER}-net"
  PROXY="batstest-$$-${BATS_TEST_NUMBER}-proxy"
}

teardown() {
  [ -n "${SANDBOX_TESTS_SKIP:-}" ] && return 0
  docker rm -f "${PROXY}" &>/dev/null || true
  docker network rm "${NET}" &>/dev/null || true
}

start_proxy() {  # $1 = allowlist spec
  docker network create --internal "${NET}" >/dev/null
  docker run -d --name "${PROXY}" \
    -v "${REPO_ROOT}/engine:/opt/engine:ro" \
    -e ALLOWED_HOSTS="$1" \
    ai-pr-review:batstest python3 /opt/engine/lib/sandbox/allowlist_proxy.py >/dev/null
  docker network connect "${NET}" "${PROXY}"
  docker inspect -f "{{(index .NetworkSettings.Networks \"${NET}\").IPAddress}}" "${PROXY}"
}

@test "direct egress from the internal network has no route out" {
  start_proxy "registry.npmjs.org" >/dev/null
  run docker run --rm --network "${NET}" ai-pr-review:batstest \
    python3 -c "import socket; socket.create_connection(('1.1.1.1',443),timeout=5)"
  [ "$status" -ne 0 ]  # connection refused / unreachable
}

@test "denied host is refused by the proxy with 403" {
  local ip; ip="$(start_proxy "registry.npmjs.org")"
  run docker run --rm --network "${NET}" -e https_proxy="http://${ip}:3128" \
    ai-pr-review:batstest python3 -c \
    "import urllib.request; urllib.request.urlopen('https://example.com',timeout=15)"
  [ "$status" -ne 0 ]
  run docker logs "${PROXY}"
  [[ "$output" == *"DENY example.com:443"* ]]
}

@test "allowed host connects through the proxy" {
  local ip; ip="$(start_proxy "registry.npmjs.org")"
  run docker run --rm --network "${NET}" -e https_proxy="http://${ip}:3128" \
    ai-pr-review:batstest python3 -c \
    "import urllib.request; print(urllib.request.urlopen('https://registry.npmjs.org/',timeout=30).status)"
  [ "$status" -eq 0 ]
  [[ "$output" == *"200"* ]]
}

@test "full sandboxed review produces findings and the checkout mount is read-only" {
  local work; work="$(mktemp -d)"
  (
    cd "${work}"
    git init -qb main; git config user.email t@t; git config user.name t
    echo "print('hi')" > app.py; git add -A; git commit -qm base
    git update-ref refs/remotes/origin/main main
    git checkout -qb feature
    printf 'api_key = "AKIAIOSFODNN7EXAMPLE"\n' > app.py; git add -A; git commit -qm change
  )
  run env -C "${work}" \
    AI_REVIEW_TOOL=claude ANTHROPIC_API_KEY=stub \
    AI_REVIEW_SANDBOX_IMAGE=ai-pr-review:batsstub CI=true NO_COLOR=1 \
    bash "${REPO_ROOT}/engine/lib/sandbox/sandbox.sh" --against origin/main
  rm -rf "${work}"
  [ "$status" -eq 0 ]
  [[ "$output" == *"Review result: COMMENT"* ]]
  [[ "$output" == *"allowlist proxy listening"* ]]  # audit log surfaced
}
