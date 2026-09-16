#!/usr/bin/env bats
# Unit tests for engines/_common/harness/core.sh — marker parsing, JSON
# extraction, batch
# planning/packing/folding, and the endpoint matrix.

setup() {
  # ENGINE_HOME = the workflow engine; the shared runtime is its _common sibling.
  ENGINE_HOME="$(cd "${BATS_TEST_DIRNAME}/../../engines/security-compliance-review" && pwd)"
  AI_COMMON_HOME="$(cd "${BATS_TEST_DIRNAME}/../../engines/_common" && pwd)"
  export AI_COMMON_HOME
  export ENGINE_HOME
  SKILL_NAME="test"
  CI=true
  # shellcheck disable=SC1091
  source "${AI_COMMON_HOME}/harness/core.sh"
  # shellcheck disable=SC1091
  source "${AI_COMMON_HOME}/endpoints.sh"
}

# ── parse_result: last marker wins (transcript-echo hazard) ─────────────────

@test "parse_result picks COMMENT" {
  run ai_review::parse_result "blah
<<<AI_REVIEW_RESULT:COMMENT>>>"
  [ "$output" = "COMMENT" ]
}

@test "parse_result takes the LAST marker, not an earlier echo" {
  # The prompt echo lists all three markers; the real verdict is last.
  run ai_review::parse_result "instructions mention <<<AI_REVIEW_RESULT:APPROVE>>> and <<<AI_REVIEW_RESULT:REQUEST_CHANGES>>>
report...
<<<AI_REVIEW_RESULT:COMMENT>>>"
  [ "$output" = "COMMENT" ]
}

@test "parse_result returns UNPARSEABLE when no marker present" {
  run ai_review::parse_result "no marker here"
  [ "$output" = "UNPARSEABLE" ]
}

# ── extract_review_json: last closed block wins ─────────────────────────────

@test "extract_review_json returns the last closed block" {
  input='<!-- AI_REVIEW_JSON_BEGIN -->
{ ...placeholder... }
<!-- AI_REVIEW_JSON_END -->
report
<!-- AI_REVIEW_JSON_BEGIN -->
{"review_action":"APPROVE"}
<!-- AI_REVIEW_JSON_END -->'
  run ai_review::extract_review_json "$input"
  [[ "$output" == *'"review_action":"APPROVE"'* ]]
  [[ "$output" != *placeholder* ]]
}

@test "extract_review_json empty when no block" {
  run ai_review::extract_review_json "just prose"
  [ -z "$output" ]
}

# ── adjudication_mode ───────────────────────────────────────────────────────

@test "adjudication_mode defaults to self" {
  unset AI_ADJUDICATION AI_REVIEW_NO_ADJUDICATE
  run ai_review::adjudication_mode
  [ "$output" = "self" ]
}

@test "adjudication_mode honors independent" {
  AI_ADJUDICATION=independent run ai_review::adjudication_mode
  [ "$output" = "independent" ]
}

@test "adjudication_mode: --no-adjudicate forces off" {
  AI_REVIEW_NO_ADJUDICATE=1 AI_ADJUDICATION=independent run ai_review::adjudication_mode
  [ "$output" = "off" ]
}

# (Fan-out verdict folding is done by fold_review_json.py — covered by the
# pytest suite and the e2e fan-out test — not by a separate marker fold.)

# ── should_batch thresholds ─────────────────────────────────────────────────

@test "should_batch: fans out above threshold with jobs>1 and >1 batch" {
  AI_REVIEW_JOBS=4 AI_REVIEW_BATCH_MIN_FILES=10 run ai_review::should_batch 12 4
  [ "$status" -eq 0 ]
}

@test "should_batch: single batch never fans out" {
  AI_REVIEW_JOBS=4 AI_REVIEW_BATCH_MIN_FILES=10 run ai_review::should_batch 12 1
  [ "$status" -ne 0 ]
}

@test "should_batch: below min files stays single" {
  AI_REVIEW_JOBS=4 AI_REVIEW_BATCH_MIN_FILES=10 run ai_review::should_batch 5 3
  [ "$status" -ne 0 ]
}

@test "should_batch: jobs=1 never fans out" {
  AI_REVIEW_JOBS=1 AI_REVIEW_BATCH_MIN_FILES=10 run ai_review::should_batch 50 9
  [ "$status" -ne 0 ]
}

# ── pack_batches: bins to at most N ─────────────────────────────────────────

@test "pack_batches coalesces to at most N bins" {
  run bash -c 'source "'"${AI_COMMON_HOME}"'/harness/core.sh"; printf "d1\ta|b\nd2\tc\nd3\td\nd4\te\nd5\tf\n" | ai_review::pack_batches 3 | wc -l'
  [ "$output" -le 3 ]
}

@test "pack_batches passes through when already within cap" {
  run bash -c 'source "'"${AI_COMMON_HOME}"'/harness/core.sh"; printf "d1\ta\nd2\tb\n" | ai_review::pack_batches 4 | wc -l'
  [ "$output" -eq 2 ]
}

# ── context_budget clamps ───────────────────────────────────────────────────

@test "context_budget clamps to floor of 4" {
  run ai_review::context_budget 1
  [ "$output" -eq 4 ]
}

@test "context_budget clamps to the configured ceiling" {
  AI_REVIEW_CONTEXT_BUDGET=15 run ai_review::context_budget 100
  [ "$output" -eq 15 ]
}

# ── endpoint matrix ─────────────────────────────────────────────────────────

@test "endpoint: claude+api requires ANTHROPIC_API_KEY" {
  AI_REVIEW_TOOL_RESOLVED=claude AI_REVIEW_PROVIDER=api run ai_review::configure_endpoint
  [ "$status" -eq 2 ]
  [[ "$output" == *"requires ANTHROPIC_API_KEY"* ]]
}

@test "endpoint: bedrock requires AWS_REGION" {
  AI_REVIEW_TOOL_RESOLVED=claude AI_REVIEW_PROVIDER=bedrock run ai_review::configure_endpoint
  [ "$status" -eq 2 ]
  [[ "$output" == *"requires AWS_REGION"* ]]
}

@test "endpoint: bedrock rejects copilot" {
  AI_REVIEW_TOOL_RESOLVED=copilot AI_REVIEW_PROVIDER=bedrock run ai_review::configure_endpoint
  [ "$status" -eq 2 ]
  [[ "$output" == *"only supported with AI_REVIEW_TOOL=claude or codex"* ]]
}

@test "endpoint: bedrock audit line names provider and region, no keys" {
  export AI_REVIEW_TOOL_RESOLVED=claude AI_REVIEW_PROVIDER=bedrock AWS_REGION=us-east-1
  export AWS_ACCESS_KEY_ID=AKIAsecret AI_REVIEW_MODEL=us.anthropic.claude-x
  run ai_review::configure_endpoint
  [ "$status" -eq 0 ]
  [[ "$output" == *"provider=bedrock"* ]]
  [[ "$output" == *"region=us-east-1"* ]]
  [[ "$output" != *"AKIAsecret"* ]]
}

@test "endpoint: codex+bedrock selects the amazon-bedrock provider" {
  export AI_REVIEW_TOOL_RESOLVED=codex AI_REVIEW_PROVIDER=bedrock AWS_REGION=us-east-1
  export AWS_ACCESS_KEY_ID=AKIAsecret AI_REVIEW_MODEL=us.anthropic.claude-x
  run ai_review::configure_endpoint
  [ "$status" -eq 0 ]
  [[ "$output" == *"provider=bedrock"* ]]
  [[ "$output" == *"region=us-east-1"* ]]
}

@test "endpoint: codex+bedrock exports the codex provider selector" {
  export AI_REVIEW_TOOL_RESOLVED=codex AI_REVIEW_PROVIDER=bedrock AWS_REGION=us-east-1
  export AWS_ACCESS_KEY_ID=AKIAsecret AI_REVIEW_MODEL=us.anthropic.claude-x
  ai_review::configure_endpoint >/dev/null 2>&1
  [ "${AI_REVIEW_CODEX_MODEL_PROVIDER}" = "amazon-bedrock" ]
}

@test "endpoint: codex+bedrock requires a model id" {
  AI_REVIEW_TOOL_RESOLVED=codex AI_REVIEW_PROVIDER=bedrock AWS_REGION=us-east-1 \
    run ai_review::configure_endpoint
  [ "$status" -eq 2 ]
  [[ "$output" == *"requires AI_REVIEW_MODEL to be a Bedrock model ID"* ]]
}

@test "endpoint: copilot BYOK base URL shows in audit line, no key leak" {
  export AI_REVIEW_TOOL_RESOLVED=copilot AI_REVIEW_PROVIDER=api
  export COPILOT_PROVIDER_BASE_URL=https://llm-gw.internal/v1 GH_TOKEN=t
  export COPILOT_PROVIDER_API_KEY=byoksecret
  run ai_review::configure_endpoint
  [ "$status" -eq 0 ]
  [[ "$output" == *"llm-gw.internal"* ]]
  [[ "$output" != *"byoksecret"* ]]
}

@test "endpoint: copilot set-but-empty BYOK vars are unset (empty input hardening)" {
  export AI_REVIEW_TOOL_RESOLVED=copilot AI_REVIEW_PROVIDER=api GH_TOKEN=t
  export COPILOT_PROVIDER_BASE_URL="" COPILOT_PROVIDER_TYPE="" \
    COPILOT_PROVIDER_API_KEY="" COPILOT_MODEL=""
  ai_review::configure_endpoint >/dev/null 2>&1
  [ -z "${COPILOT_PROVIDER_BASE_URL+x}" ]
  [ -z "${COPILOT_PROVIDER_TYPE+x}" ]
  [ -z "${COPILOT_PROVIDER_API_KEY+x}" ]
  [ -z "${COPILOT_MODEL+x}" ]
}

@test "endpoint: copilot non-empty BYOK vars survive the hardening" {
  export AI_REVIEW_TOOL_RESOLVED=copilot AI_REVIEW_PROVIDER=api GH_TOKEN=t
  export COPILOT_PROVIDER_BASE_URL=https://llm-gw.internal/v1
  export COPILOT_PROVIDER_TYPE=anthropic COPILOT_MODEL=claude-sonnet-4-5
  ai_review::configure_endpoint >/dev/null 2>&1
  [ "${COPILOT_PROVIDER_BASE_URL}" = "https://llm-gw.internal/v1" ]
  [ "${COPILOT_PROVIDER_TYPE}" = "anthropic" ]
  [ "${COPILOT_MODEL}" = "claude-sonnet-4-5" ]
}

@test "endpoint: vertex requires project id and region" {
  AI_REVIEW_TOOL_RESOLVED=claude AI_REVIEW_PROVIDER=vertex run ai_review::configure_endpoint
  [ "$status" -eq 2 ]
}

@test "endpoint: azure rejects non-codex tools" {
  AI_REVIEW_TOOL_RESOLVED=claude AI_REVIEW_PROVIDER=azure run ai_review::configure_endpoint
  [ "$status" -eq 2 ]
  [[ "$output" == *"only supported with AI_REVIEW_TOOL=codex"* ]]
}

@test "endpoint: azure requires AZURE_OPENAI_ENDPOINT" {
  AI_REVIEW_TOOL_RESOLVED=codex AI_REVIEW_PROVIDER=azure AI_REVIEW_MODEL=gpt-review \
    run ai_review::configure_endpoint
  [ "$status" -eq 2 ]
  [[ "$output" == *"requires AZURE_OPENAI_ENDPOINT"* ]]
}

@test "endpoint: azure requires a deployment via AI_REVIEW_MODEL" {
  AI_REVIEW_TOOL_RESOLVED=codex AI_REVIEW_PROVIDER=azure \
    AZURE_OPENAI_ENDPOINT=https://res.openai.azure.com run ai_review::configure_endpoint
  [ "$status" -eq 2 ]
  [[ "$output" == *"Azure deployment name"* ]]
}

@test "endpoint: azure derives the deployment base URL, no key leak" {
  export AI_REVIEW_TOOL_RESOLVED=codex AI_REVIEW_PROVIDER=azure
  export AZURE_OPENAI_ENDPOINT=https://res.openai.azure.com AI_REVIEW_MODEL=gpt-review
  export AZURE_OPENAI_API_KEY=azuresecret AZURE_OPENAI_API_VERSION=2024-10-21
  run ai_review::configure_endpoint
  [ "$status" -eq 0 ]
  [[ "$output" == *"provider=azure"* ]]
  [[ "$output" == *"openai/deployments/gpt-review"* ]]
  [[ "$output" == *"api-version=2024-10-21"* ]]
  [[ "$output" != *"azuresecret"* ]]
}

# ── profiles: additive everywhere, last listed wins ─────────────────────────
# A profile may only ADD to the rubric. There is no override path: the base
# skill always reaches the prompt, and a profile's copy of the same filename is
# appended after it. Several profiles may be listed, and each addition claims
# precedence over everything above it, so the last one listed wins.

_profile_fixture() { # $1 = profile name, rest = rubric filenames to create
  local name="$1"; shift
  local d="${BATS_TEST_TMPDIR}/${name}"
  mkdir -p "${d}"
  local f
  for f in "$@"; do printf 'ADDITION-FROM-%s\n' "${name}" >"${d}/${f}"; done
  printf '%s' "${d}"
}

@test "profiles: a single name resolves to one directory" {
  AI_REVIEW_PROFILE=cms-ars ai_review::resolve_profiles
  [[ "${AI_REVIEW_PROFILE_DIRS}" == *"profiles/cms-ars"* ]]
  [ "$(printf '%s' "${AI_REVIEW_PROFILE_DIRS}" | grep -c .)" -eq 1 ]
}

@test "profiles: a comma list resolves in order" {
  AI_REVIEW_PROFILE=baseline,cms-ars ai_review::resolve_profiles
  [ "$(printf '%s' "${AI_REVIEW_PROFILE_DIRS}" | grep -c .)" -eq 2 ]
  [[ "$(printf '%s' "${AI_REVIEW_PROFILE_DIRS}" | head -1)" == *baseline ]]
  [[ "$(printf '%s' "${AI_REVIEW_PROFILE_DIRS}" | tail -1)" == *cms-ars ]]
}

@test "profiles: surrounding whitespace in a list is tolerated" {
  AI_REVIEW_PROFILE="baseline , cms-ars" ai_review::resolve_profiles
  [ "$(printf '%s' "${AI_REVIEW_PROFILE_DIRS}" | grep -c .)" -eq 2 ]
}

@test "profiles: a directory path is accepted alongside a bundled name" {
  local d; d="$(_profile_fixture mine code-security.md)"
  AI_REVIEW_PROFILE="cms-ars,${d}" ai_review::resolve_profiles
  [ "$(printf '%s' "${AI_REVIEW_PROFILE_DIRS}" | grep -c .)" -eq 2 ]
}

@test "profiles: an unknown name in a list is a config error" {
  AI_REVIEW_PROFILE="cms-ars,nope" run ai_review::resolve_profiles
  [ "$status" -eq 2 ]
  [[ "$output" == *"'nope' is not a known profile"* ]]
  [[ "$output" == *"may be combined"* ]]
}

@test "profiles: additions are emitted for each profile that has the file" {
  local a b; a="$(_profile_fixture one code-security.md)"; b="$(_profile_fixture two code-security.md)"
  AI_REVIEW_PROFILE="${a},${b}" ai_review::resolve_profiles
  run ai_review::profile_additions code-security.md "SECURITY PERSPECTIVE"
  [ "$status" -eq 0 ]
  [[ "$output" == *"ADDITION-FROM-one"* ]]
  [[ "$output" == *"ADDITION-FROM-two"* ]]
}

@test "profiles: the last listed profile's addition comes last" {
  local a b; a="$(_profile_fixture one code-security.md)"; b="$(_profile_fixture two code-security.md)"
  AI_REVIEW_PROFILE="${a},${b}" ai_review::resolve_profiles
  run ai_review::profile_additions code-security.md "SECURITY PERSPECTIVE"
  local first_pos last_pos
  first_pos="$(printf '%s' "$output" | grep -n 'ADDITION-FROM-one' | cut -d: -f1)"
  last_pos="$(printf '%s' "$output" | grep -n 'ADDITION-FROM-two' | cut -d: -f1)"
  [ "${first_pos}" -lt "${last_pos}" ]
}

@test "profiles: each addition claims precedence over everything above it" {
  local a; a="$(_profile_fixture one code-security.md)"
  AI_REVIEW_PROFILE="${a}" ai_review::resolve_profiles
  run ai_review::profile_additions code-security.md "SECURITY PERSPECTIVE"
  [[ "$output" == *"ADDS to everything above it and never replaces it"* ]]
  [[ "$output" == *"this section takes precedence"* ]]
}

@test "profiles: a profile with no copy of the file contributes nothing" {
  # baseline ships only a README, so it adds nothing to any rubric.
  AI_REVIEW_PROFILE=baseline ai_review::resolve_profiles
  run ai_review::profile_additions code-security.md "SECURITY PERSPECTIVE"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "profiles: a profile copy never replaces the base (no override path)" {
  # The engine reads skills/base/<file> unconditionally; grep the entrypoints
  # rather than the prompt so this fails if an override helper comes back.
  ! grep -qE 'rubric (pr-review|code-security|codebase-audit)\.md' \
    "${ENGINE_HOME}/harness/ai-security-compliance-review" \
    "${ENGINE_HOME}/harness/ai-security-compliance-audit"
}

# ── azure + a per-pass adjudication model ───────────────────────────────────
# Azure resolves the deployment from the URL path, not the CLI model flag, so
# AI_ADJUDICATION_MODEL needs its own URL. Before this it was silently ignored:
# the flag changed, the URL did not, and the "independent" second opinion ran
# on the first-pass deployment.

@test "endpoint: azure records a URL template so adjudication can swap the deployment" {
  AI_REVIEW_TOOL_RESOLVED=codex AI_REVIEW_PROVIDER=azure AI_REVIEW_MODEL=gpt-review
  export AI_REVIEW_TOOL_RESOLVED AI_REVIEW_PROVIDER AI_REVIEW_MODEL
  export AZURE_OPENAI_ENDPOINT=https://res.openai.azure.com
  export AZURE_OPENAI_API_KEY=azuresecret
  ai_review::configure_endpoint >/dev/null 2>&1
  [[ "${AI_REVIEW_AZURE_URL_TEMPLATE}" == *"deployments/{MODEL}?api-version="* ]]
}

@test "endpoint: azure with a caller-supplied base URL rejects AI_ADJUDICATION_MODEL" {
  AI_REVIEW_TOOL_RESOLVED=codex AI_REVIEW_PROVIDER=azure AI_REVIEW_MODEL=gpt-review     OPENAI_BASE_URL=https://gw.example/v1     AI_ADJUDICATION=independent AI_ADJUDICATION_MODEL=gpt-audit     run ai_review::configure_endpoint
  [ "$status" -eq 2 ]
  [[ "$output" == *"cannot honor AI_ADJUDICATION_MODEL"* ]]
}

@test "endpoint: azure with a caller-supplied base URL is fine without an adjudication model" {
  AI_REVIEW_TOOL_RESOLVED=codex AI_REVIEW_PROVIDER=azure AI_REVIEW_MODEL=gpt-review     OPENAI_BASE_URL=https://gw.example/v1 AZURE_OPENAI_API_KEY=k     run ai_review::configure_endpoint
  [ "$status" -eq 0 ]
}

@test "endpoint: azure self-adjudication with a custom URL is not rejected" {
  # Only the independent pass makes a second call; self-adjudication is one
  # call on the first-pass deployment, so the model override is irrelevant.
  AI_REVIEW_TOOL_RESOLVED=codex AI_REVIEW_PROVIDER=azure AI_REVIEW_MODEL=gpt-review     OPENAI_BASE_URL=https://gw.example/v1 AZURE_OPENAI_API_KEY=k     AI_ADJUDICATION=self AI_ADJUDICATION_MODEL=gpt-audit     run ai_review::configure_endpoint
  [ "$status" -eq 0 ]
}

@test "adjudicate: azure swaps the deployment in the URL for the second pass" {
  export AI_REVIEW_AZURE_URL_TEMPLATE="https://res.openai.azure.com/openai/deployments/{MODEL}?api-version=2024-10-21"
  export AI_ADJUDICATION_MODEL=gpt-audit
  export OPENAI_BASE_URL="https://res.openai.azure.com/openai/deployments/gpt-review?api-version=2024-10-21"
  # Capture what invoke_tool would see instead of calling a CLI.
  ai_review::invoke_tool() { printf 'url=%s model=%s\n' "${OPENAI_BASE_URL}" "$2"; }
  ai_review::build_adjudication_prompt() { printf 'prompt'; }
  run ai_review::adjudicate '{"review_action":"COMMENT"}'
  [ "$status" -eq 0 ]
  [[ "$output" == *"deployments/gpt-audit"* ]]
  [[ "$output" == *"model=gpt-audit"* ]]
}

@test "adjudicate: no template means the URL is left alone (non-azure providers)" {
  unset AI_REVIEW_AZURE_URL_TEMPLATE || true
  export AI_ADJUDICATION_MODEL=claude-other
  ai_review::invoke_tool() { printf 'url=%s model=%s\n' "${OPENAI_BASE_URL:-none}" "$2"; }
  ai_review::build_adjudication_prompt() { printf 'prompt'; }
  run ai_review::adjudicate '{"review_action":"COMMENT"}'
  [ "$status" -eq 0 ]
  [[ "$output" == *"url=none"* ]]
  [[ "$output" == *"model=claude-other"* ]]
}

@test "endpoint: invalid provider rejected" {
  AI_REVIEW_TOOL_RESOLVED=claude AI_REVIEW_PROVIDER=nonsense run ai_review::configure_endpoint
  [ "$status" -eq 2 ]
  [[ "$output" == *"not a recognized value"* ]]
}

@test "endpoint: custom base url passes and shows in audit line" {
  export AI_REVIEW_TOOL_RESOLVED=claude AI_REVIEW_PROVIDER=api
  export ANTHROPIC_BASE_URL=https://gw.internal/v1 ANTHROPIC_API_KEY=x
  run ai_review::configure_endpoint
  [ "$status" -eq 0 ]
  [[ "$output" == *"gw.internal"* ]]
}
