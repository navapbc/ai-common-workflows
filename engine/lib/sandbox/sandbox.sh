#!/usr/bin/env bash
# engine/lib/sandbox/sandbox.sh
#
# Runs the AI PR review inside a Docker sandbox with default-deny egress.
#
# Topology (see docs/security.md for the threat model):
#
#   ┌───────────────────────────── internal network (no route out) ──┐
#   │  review container                     proxy sidecar            │
#   │  - AI CLI + engine (AI phase)  ────▶  - allowlist_proxy.py ────┼──▶ LLM endpoint only
#   │  - checkout mounted READ-ONLY         - also on the bridge     │
#   │  - NO SCM token                       - logs ALLOW/DENY        │
#   └─────────────────────────────────────────────────────────────────┘
#   post container (default bridge, trusted, no AI): gh api posting only
#
# The internal network is kernel-enforced: even a malicious binary that
# ignores proxy environment variables has no route to the outside. The
# review phase's allowlist contains only the LLM endpoint derived from the
# provider configuration (plus AI_REVIEW_EXTRA_ALLOWED_HOSTS for gateways).
# The SCM token exists only in the post phase, which runs no AI.
#
# Usage (from the reviewed repository's root):
#   sandbox.sh --against origin/main [--pr N --post-comments] [--gate]
#              [--no-block] [engine flags passed through to the AI phase]
#
# Environment:
#   AI_REVIEW_SANDBOX_IMAGE        review image (digest-pinned reference)
#   AI_REVIEW_EXTRA_ALLOWED_HOSTS  extra egress hosts (gateways), space/comma
#   ...plus the engine's own environment (AI_REVIEW_TOOL, provider config,
#   LLM credentials, tuning). GITHUB_TOKEN/GH_TOKEN are passed ONLY to the
#   post phase — with one documented exception: AI_REVIEW_TOOL=copilot needs
#   a token inside the sandbox because its *model* auth is a GitHub token.
#
# Exit codes mirror the engine: 0 ok/advisory, 1 gate-fail or error, 2 config.

set -euo pipefail

SANDBOX_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENGINE_HOME="$(cd "${SANDBOX_DIR}/../.." && pwd)"

log() { printf '[sandbox] %s\n' "$*" >&2; }
err() { printf '[sandbox] ERROR: %s\n' "$*" >&2; }

# ── Flag parsing ────────────────────────────────────────────────────────────
PR_NUMBER=""
POST_COMMENTS=0
GATE_MODE=0
NO_BLOCK=0
AGAINST=""
ENGINE_ARGS=()

while [[ $# -gt 0 ]]; do
  case "$1" in
    --pr)
      PR_NUMBER="${2:?--pr requires a value}"
      shift 2
      ;;
    --pr=*)
      PR_NUMBER="${1#*=}"
      shift
      ;;
    --against)
      AGAINST="${2:?--against requires a value}"
      shift 2
      ;;
    --against=*)
      AGAINST="${1#*=}"
      shift
      ;;
    --post-comments)
      POST_COMMENTS=1
      shift
      ;;
    --gate)
      GATE_MODE=1
      shift
      ;;
    --no-block)
      NO_BLOCK=1
      shift
      ;;
    *)
      ENGINE_ARGS+=("$1")
      shift
      ;;
  esac
done

if [[ -z "${AGAINST}" ]]; then
  err "--against <ref> is required in sandbox mode (PR discovery needs the SCM, which the sandbox cannot reach)."
  exit 2
fi
if ((POST_COMMENTS == 1)) && [[ -z "${PR_NUMBER}" ]]; then
  err "--post-comments requires --pr <number> in sandbox mode."
  exit 2
fi
if ! command -v docker &>/dev/null; then
  err "docker is required for sandbox mode. Install Docker, or run with sandbox disabled (direct mode)."
  exit 2
fi
IMAGE="${AI_REVIEW_SANDBOX_IMAGE:-}"
if [[ -z "${IMAGE}" ]]; then
  err "AI_REVIEW_SANDBOX_IMAGE is not set (the review container image, ideally digest-pinned)."
  exit 2
fi

# ── Egress allowlist derivation ─────────────────────────────────────────────
# The review phase may reach exactly one thing: its model endpoint. Derived
# from the same provider parameters the engine validates, so consumers never
# maintain a separate list.
url_host() { # print host[:port] from a URL; empty on empty input
  local url="${1:-}"
  [[ -z "${url}" ]] && return 0
  local host="${url#*://}"
  host="${host%%/*}"
  printf '%s' "${host}"
}

derive_allowlist() {
  local tool provider hosts=""
  tool="$(printf '%s' "${AI_REVIEW_TOOL:-}" | tr '[:upper:]' '[:lower:]')"
  provider="$(printf '%s' "${AI_REVIEW_PROVIDER:-api}" | tr '[:upper:]' '[:lower:]')"

  case "${tool}" in
    claude)
      if [[ -n "${ANTHROPIC_BASE_URL:-}" ]]; then
        hosts="$(url_host "${ANTHROPIC_BASE_URL}")"
      elif [[ "${provider}" == "bedrock" ]]; then
        local region="${AWS_REGION:-${AWS_DEFAULT_REGION:-}}"
        hosts="bedrock-runtime.${region}.amazonaws.com sts.${region}.amazonaws.com sts.amazonaws.com"
      elif [[ "${provider}" == "vertex" ]]; then
        hosts="aiplatform.googleapis.com ${CLOUD_ML_REGION:+${CLOUD_ML_REGION}-aiplatform.googleapis.com} oauth2.googleapis.com"
      else
        hosts="api.anthropic.com"
      fi
      ;;
    codex)
      if [[ -n "${OPENAI_BASE_URL:-}" ]]; then
        hosts="$(url_host "${OPENAI_BASE_URL}")"
      elif [[ "${provider}" == "azure" && -n "${AZURE_OPENAI_ENDPOINT:-}" ]]; then
        # Azure OpenAI: allow the resource endpoint host (the engine derives
        # OPENAI_BASE_URL from it, but that may not be set yet at this point).
        hosts="$(url_host "${AZURE_OPENAI_ENDPOINT}")"
      else
        hosts="api.openai.com"
      fi
      ;;
    copilot)
      # Copilot's model auth is a GitHub token, so its auth+model hosts are
      # unavoidable in the sandbox — the documented exception.
      hosts="api.githubcopilot.com api.github.com github.com ${GH_HOST:-}"
      ;;
    *)
      err "AI_REVIEW_TOOL='${AI_REVIEW_TOOL:-}' is not a recognized value (claude | codex | copilot)."
      exit 2
      ;;
  esac

  printf '%s %s' "${hosts}" "${AI_REVIEW_EXTRA_ALLOWED_HOSTS:-}"
}

ALLOWED_HOSTS="$(derive_allowlist | xargs)"
log "Egress allowlist for the review phase: ${ALLOWED_HOSTS}"

# ── Environment passthrough for the review (AI) phase ──────────────────────
# LLM credentials and engine tuning only. Deliberately absent: GITHUB_TOKEN /
# GH_TOKEN (post phase only; copilot excepted below).
REVIEW_ENV_VARS=(
  AI_REVIEW_TOOL AI_REVIEW_PROVIDER AI_REVIEW_MODEL
  ANTHROPIC_API_KEY ANTHROPIC_AUTH_TOKEN ANTHROPIC_BASE_URL
  OPENAI_API_KEY OPENAI_BASE_URL
  AWS_REGION AWS_DEFAULT_REGION AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY AWS_SESSION_TOKEN
  ANTHROPIC_VERTEX_PROJECT_ID CLOUD_ML_REGION GOOGLE_APPLICATION_CREDENTIALS
  AI_ADJUDICATION AI_ADJUDICATION_MODEL
  AI_REVIEW_JOBS AI_REVIEW_BATCH_BY AI_REVIEW_BATCH_MIN_FILES AI_REVIEW_CONTEXT_BUDGET
  CI NO_COLOR
)

review_env_args() {
  local v
  for v in "${REVIEW_ENV_VARS[@]}"; do
    if [[ -n "${!v:-}" ]]; then
      printf -- '--env\n%s\n' "${v}"
    fi
  done
  if [[ "$(printf '%s' "${AI_REVIEW_TOOL:-}" | tr '[:upper:]' '[:lower:]')" == "copilot" ]]; then
    for v in GITHUB_TOKEN GH_TOKEN; do
      [[ -n "${!v:-}" ]] && printf -- '--env\n%s\n' "${v}"
    done
  fi
  return 0
}

# ── Sandbox lifecycle ───────────────────────────────────────────────────────
RUN_ID="ai-review-$$-${RANDOM}"
NET="${RUN_ID}-net"
PROXY="${RUN_ID}-proxy"
OUT_DIR="$(mktemp -d)"

# shellcheck disable=SC2329,SC2317  # invoked via the EXIT trap below
teardown() {
  local audit
  if audit="$(docker logs "${PROXY}" 2>&1)" && [[ -n "${audit}" ]]; then
    log "Proxy audit log:"
    printf '%s\n' "${audit}" | sed 's/^/[sandbox]   /' >&2
  fi
  docker rm -f "${PROXY}" &>/dev/null || true
  docker network rm "${NET}" &>/dev/null || true
  rm -rf "${OUT_DIR}"
}
trap teardown EXIT

log "Creating internal network ${NET} (no external route)"
docker network create --internal "${NET}" >/dev/null

# The sidecar starts on the default bridge (its way out), then attaches to
# the internal network (its face toward the review container).
docker run -d --name "${PROXY}" \
  --volume "${ENGINE_HOME}:/opt/engine:ro" \
  --env ALLOWED_HOSTS="${ALLOWED_HOSTS}" \
  --cap-drop ALL --security-opt no-new-privileges --read-only \
  "${IMAGE}" python3 /opt/engine/lib/sandbox/allowlist_proxy.py >/dev/null
docker network connect "${NET}" "${PROXY}"

PROXY_IP="$(docker inspect -f "{{(index .NetworkSettings.Networks \"${NET}\").IPAddress}}" "${PROXY}")"
if [[ -z "${PROXY_IP}" ]]; then
  err "could not determine the proxy sidecar's address on ${NET}."
  exit 1
fi
log "Proxy sidecar up at ${PROXY_IP}:3128"

# ── Phase 1: sandboxed review ───────────────────────────────────────────────
log "Running the AI review phase (internal network; allowlist above; checkout read-only)"
REVIEW_ENV_ARGS=()
while IFS= read -r line; do REVIEW_ENV_ARGS+=("${line}"); done < <(review_env_args)

ENGINE_CMD=(bash /opt/engine/bin/ai-pr-review --against "${AGAINST}" --json-out /out/review.json)
((NO_BLOCK == 1)) && ENGINE_CMD+=(--no-block)
ENGINE_CMD+=("${ENGINE_ARGS[@]+"${ENGINE_ARGS[@]}"}")

review_rc=0
docker run --rm --name "${RUN_ID}-review" \
  --network "${NET}" \
  --volume "$(pwd):/workspace:ro" \
  --volume "${ENGINE_HOME}:/opt/engine:ro" \
  --volume "${OUT_DIR}:/out" \
  --workdir /workspace \
  --cap-drop ALL --security-opt no-new-privileges \
  --read-only --tmpfs /tmp:exec,size=512m \
  --env HOME=/tmp/home \
  --env GIT_OPTIONAL_LOCKS=0 \
  --env HTTP_PROXY="http://${PROXY_IP}:3128" \
  --env HTTPS_PROXY="http://${PROXY_IP}:3128" \
  --env http_proxy="http://${PROXY_IP}:3128" \
  --env https_proxy="http://${PROXY_IP}:3128" \
  --env NO_PROXY="" \
  "${REVIEW_ENV_ARGS[@]}" \
  "${IMAGE}" \
  "${ENGINE_CMD[@]}" ||
  review_rc=$?

if ((review_rc != 0)); then
  err "review phase exited ${review_rc}."
  exit "${review_rc}"
fi
if [[ ! -s "${OUT_DIR}/review.json" ]]; then
  err "review phase produced no findings JSON."
  ((NO_BLOCK == 1)) && exit 0
  exit 1
fi

# The JSON is engine-generated, so this minimal extraction is safe without
# a host python dependency (Jenkins sandbox-mode agents only need Docker).
RESULT="$(sed -n 's/.*"review_action"[[:space:]]*:[[:space:]]*"\([A-Z_]*\)".*/\1/p' "${OUT_DIR}/review.json" | head -1)"
log "Review result: ${RESULT:-UNKNOWN}"

# Expose the findings JSON on the host when asked (the container-internal copy
# in OUT_DIR is discarded on teardown). Frontends use this for step outputs.
if [[ -n "${AI_REVIEW_HOST_JSON_OUT:-}" ]]; then
  cp "${OUT_DIR}/review.json" "${AI_REVIEW_HOST_JSON_OUT}"
fi

# ── Phase 2: trusted post (no AI, normal network, token present) ───────────
if ((POST_COMMENTS == 1)); then
  log "Posting review to PR #${PR_NUMBER} (trusted post phase)"
  POST_ENV_ARGS=()
  for v in GITHUB_TOKEN GH_TOKEN GH_HOST GH_ENTERPRISE_TOKEN CI NO_COLOR; do
    [[ -n "${!v:-}" ]] && POST_ENV_ARGS+=(--env "${v}")
  done
  docker run --rm --name "${RUN_ID}-post" \
    --volume "$(pwd):/workspace:ro" \
    --volume "${ENGINE_HOME}:/opt/engine:ro" \
    --volume "${OUT_DIR}:/out:ro" \
    --workdir /workspace \
    --cap-drop ALL --security-opt no-new-privileges \
    --read-only --tmpfs /tmp:size=64m \
    --env HOME=/tmp/home \
    --env GIT_OPTIONAL_LOCKS=0 \
    "${POST_ENV_ARGS[@]+"${POST_ENV_ARGS[@]}"}" \
    "${IMAGE}" \
    bash /opt/engine/bin/ai-pr-review --post-only --pr "${PR_NUMBER}" --json-in /out/review.json
fi

# ── Gate ────────────────────────────────────────────────────────────────────
if ((GATE_MODE == 1)) && [[ "${RESULT}" != "APPROVE" ]]; then
  if ((NO_BLOCK == 1)); then
    log "--no-block in effect: exiting 0 despite --gate and result ${RESULT}."
    exit 0
  fi
  err "--gate mode: review result is ${RESULT}, exiting non-zero to fail the build."
  exit 1
fi

exit 0
