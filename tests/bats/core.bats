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

@test "adjudication_mode defaults to off" {
  # Off because a current model verifies its own work unprompted; measured on
  # tests/corpus, self suppressed nothing and cost more. The modes remain for
  # older pinned models and for codex/copilot, which the guidance behind this
  # does not cover.
  unset AI_ADJUDICATION AI_REVIEW_NO_ADJUDICATE
  run ai_review::adjudication_mode
  [ "$output" = "off" ]
}

@test "adjudication_mode still honors self when asked" {
  # The modes are kept, not removed — only the default moved.
  AI_ADJUDICATION=self run ai_review::adjudication_mode
  [ "$output" = "self" ]
  AI_ADJUDICATION=inline run ai_review::adjudication_mode
  [ "$output" = "self" ]
}

@test "adjudication_mode: an unrecognized value falls back to off, loudly" {
  # It used to fall back to self. The fallback has to track the default, or a
  # typo silently buys the behaviour the default deliberately declines.
  AI_ADJUDICATION=slef run ai_review::adjudication_mode
  [[ "$output" == *"not recognized"* ]]
  # bats merges stderr into $output; the resolved mode is the last line.
  [ "${lines[$((${#lines[@]} - 1))]}" = "off" ]
}

@test "adjudication_mode: the warning does not corrupt the captured mode" {
  # Callers do m="$(ai_review::adjudication_mode)". A warning on stdout would
  # make the mode "WARN: ...\noff" and match no case downstream.
  AI_ADJUDICATION=slef
  local mode
  mode="$(ai_review::adjudication_mode 2>/dev/null)"
  [ "${mode}" = "off" ]
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

# ── CLI-native auth ─────────────────────────────────────────────────────────
# `claude` and `codex` can be logged in interactively, leaving no key in the
# environment at all. The credential check could not see that, so it refused a
# configuration that works — which is the normal local setup, and it blocked
# the audit and the detection corpus on any developer machine.
#
# The escape hatch must stay EXPLICIT. Inferring it from a usable CLI login
# would recreate the failure the check exists for: meaning to run in-boundary,
# forgetting AI_REVIEW_PROVIDER, and silently sending the diff to the public
# API on a personal login.

@test "endpoint: CLI-native auth lets claude+api run with no key" {
  # setup() sets CI=true to suppress colour; this exercises the LOCAL path.
  unset CI GITHUB_ACTIONS JENKINS_URL BUILD_ID
  AI_REVIEW_TOOL_RESOLVED=claude AI_REVIEW_PROVIDER=api \
    AI_REVIEW_CLI_NATIVE_AUTH=1 run ai_review::configure_endpoint
  [ "$status" -eq 0 ]
}

@test "endpoint: CLI-native auth lets codex+api run with no key" {
  # setup() sets CI=true to suppress colour; this exercises the LOCAL path.
  unset CI GITHUB_ACTIONS JENKINS_URL BUILD_ID
  AI_REVIEW_TOOL_RESOLVED=codex AI_REVIEW_PROVIDER=api \
    AI_REVIEW_CLI_NATIVE_AUTH=1 run ai_review::configure_endpoint
  [ "$status" -eq 0 ]
}

@test "endpoint: CLI-native auth says the traffic is public" {
  # Silence here would be the whole problem: the operator has opted into the
  # public endpoint and has to be told so.
  # setup() sets CI=true to suppress colour; this exercises the LOCAL path.
  unset CI GITHUB_ACTIONS JENKINS_URL BUILD_ID
  AI_REVIEW_TOOL_RESOLVED=claude AI_REVIEW_PROVIDER=api \
    AI_REVIEW_CLI_NATIVE_AUTH=1 run ai_review::configure_endpoint
  [[ "$output" == *"PUBLIC"* ]]
  [[ "$output" == *"own login"* ]]
}

@test "endpoint: CLI-native auth is not inferred from an absent key" {
  # The var unset must behave exactly as before.
  AI_REVIEW_TOOL_RESOLVED=claude AI_REVIEW_PROVIDER=api run ai_review::configure_endpoint
  [ "$status" -ne 0 ]
  [[ "$output" == *"requires ANTHROPIC_API_KEY"* ]]
}

@test "endpoint: only 1 opts in — a truthy-looking value does not" {
  # "true"/"yes" are the spellings someone reaches for. Accepting them widens
  # the ways a boundary run can silently become a public one; refusing keeps
  # one exact opt-in, and the error still names it.
  for v in true yes on TRUE 2 ""; do
    AI_REVIEW_TOOL_RESOLVED=claude AI_REVIEW_PROVIDER=api \
      AI_REVIEW_CLI_NATIVE_AUTH="${v}" run ai_review::configure_endpoint
    [ "$status" -ne 0 ]
  done
}

@test "endpoint: the error names the escape hatch" {
  # Discoverability is the point — a developer whose CLI is logged in has no
  # other way to learn this exists.
  AI_REVIEW_TOOL_RESOLVED=claude AI_REVIEW_PROVIDER=api run ai_review::configure_endpoint
  [[ "$output" == *"AI_REVIEW_CLI_NATIVE_AUTH=1"* ]]
  AI_REVIEW_TOOL_RESOLVED=codex AI_REVIEW_PROVIDER=api run ai_review::configure_endpoint
  [[ "$output" == *"AI_REVIEW_CLI_NATIVE_AUTH=1"* ]]
}

# ── ...and is refused in CI ─────────────────────────────────────────────────
# The variable is not an input on either action.yml, but a job-level env: in a
# consumer's own workflow propagates into composite steps, so "not an input" is
# not a guarantee. On a hosted runner the opt-in would only trade a clear
# missing-key error for a confusing CLI failure; on a SELF-HOSTED runner with a
# persisted login it would quietly use that login against the public API.

@test "endpoint: CLI-native auth is refused when CI is set" {
  CI=true AI_REVIEW_TOOL_RESOLVED=claude AI_REVIEW_PROVIDER=api \
    AI_REVIEW_CLI_NATIVE_AUTH=1 run ai_review::configure_endpoint
  [ "$status" -ne 0 ]
  [[ "$output" == *"requires ANTHROPIC_API_KEY"* ]]
}

@test "endpoint: the CI refusal says why, rather than ignoring it silently" {
  CI=true AI_REVIEW_TOOL_RESOLVED=claude AI_REVIEW_PROVIDER=api \
    AI_REVIEW_CLI_NATIVE_AUTH=1 run ai_review::configure_endpoint
  [[ "$output" == *"ignored in CI"* ]]
  [[ "$output" == *"local runs only"* ]]
}

@test "endpoint: every CI marker refuses it, not just CI=true" {
  # Jenkins does not reliably set CI. A marker this check misses is a boundary
  # violation, so the detection is deliberately broad — and each marker is
  # asserted, because "covered by CI=true" is how the others quietly stop
  # working.
  local marker
  for marker in CI GITHUB_ACTIONS JENKINS_URL BUILD_ID; do
    unset CI GITHUB_ACTIONS JENKINS_URL BUILD_ID
    export "${marker}=x"
    AI_REVIEW_TOOL_RESOLVED=claude AI_REVIEW_PROVIDER=api \
      AI_REVIEW_CLI_NATIVE_AUTH=1 run ai_review::configure_endpoint
    [ "$status" -ne 0 ]
    unset "${marker}"
  done
}

@test "endpoint: CI does not break the normal keyed path" {
  # The refusal must only affect the opt-in. A pipeline with a real key is the
  # overwhelmingly common case and has to be untouched.
  CI=true AI_REVIEW_TOOL_RESOLVED=claude AI_REVIEW_PROVIDER=api \
    ANTHROPIC_API_KEY=sk-test run ai_review::configure_endpoint
  [ "$status" -eq 0 ]
  [[ "$output" != *"ignored in CI"* ]]
}

@test "endpoint: CLI-native auth still works with no CI marker present" {
  # Guard against in_ci matching something that is always set.
  unset CI GITHUB_ACTIONS JENKINS_URL BUILD_ID
  AI_REVIEW_TOOL_RESOLVED=claude AI_REVIEW_PROVIDER=api \
    AI_REVIEW_CLI_NATIVE_AUTH=1 run ai_review::configure_endpoint
  [ "$status" -eq 0 ]
}

@test "endpoint: CLI-native auth does not weaken the in-boundary providers" {
  # It is an api-provider escape hatch only. A bedrock run with no region is
  # still a hard error — otherwise the opt-out would become a way to make any
  # misconfiguration pass.
  AI_REVIEW_TOOL_RESOLVED=claude AI_REVIEW_PROVIDER=bedrock \
    AI_REVIEW_CLI_NATIVE_AUTH=1 run ai_review::configure_endpoint
  [ "$status" -ne 0 ]
}

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

# ── rubric composition: base is an explicit list member ─────────────────────
# `profile` is an ordered list of rubric sources, base among them. Sources only
# add; the last listed wins. The first entry must be `base` or `none`, because
# dropping the floor by accident is silent and severe — the review still runs
# and reports a verdict having checked almost nothing.

_profile_fixture() { # $1 = name, rest = rubric filenames to create
  local name="$1"; shift
  local d="${BATS_TEST_TMPDIR}/${name}"
  mkdir -p "${d}"
  local f
  for f in "$@"; do printf 'ADDITION-FROM-%s\n' "${name}" >"${d}/${f}"; done
  printf '%s' "${d}"
}

_dirs_count() { printf '%s' "${AI_REVIEW_RUBRIC_DIRS}" | grep -c . ; }

@test "rubric: base alone resolves to the base directory" {
  AI_REVIEW_PROFILE=base ai_review::resolve_profiles
  [ "$(_dirs_count)" -eq 1 ]
  [[ "${AI_REVIEW_RUBRIC_DIRS}" == *"/skills/base"* ]]
}

@test "rubric: default is base" {
  unset AI_REVIEW_PROFILE || true
  ai_review::resolve_profiles
  [[ "${AI_REVIEW_RUBRIC_DIRS}" == *"/skills/base"* ]]
}

@test "rubric: base,cms-ars resolves both in order" {
  AI_REVIEW_PROFILE=base,cms-ars ai_review::resolve_profiles
  [ "$(_dirs_count)" -eq 2 ]
  [[ "$(printf '%s' "${AI_REVIEW_RUBRIC_DIRS}" | head -1)" == *"/skills/base" ]]
  [[ "$(printf '%s' "${AI_REVIEW_RUBRIC_DIRS}" | tail -1)" == *cms-ars ]]
}

@test "rubric: whitespace around list entries is tolerated" {
  AI_REVIEW_PROFILE="base , cms-ars" ai_review::resolve_profiles
  [ "$(_dirs_count)" -eq 2 ]
}

@test "rubric: a directory path may follow base" {
  local d; d="$(_profile_fixture mine code-security.md)"
  AI_REVIEW_PROFILE="base,${d}" ai_review::resolve_profiles
  [ "$(_dirs_count)" -eq 2 ]
}

# ── the guards ──────────────────────────────────────────────────────────────

@test "rubric: omitting base or none is a config error, not a quiet downgrade" {
  AI_REVIEW_PROFILE=cms-ars run ai_review::resolve_profiles
  [ "$status" -eq 2 ]
  [[ "$output" == *"must start with 'base' or 'none'"* ]]
  [[ "$output" == *"by accident"* ]]
}

@test "rubric: base listed after a profile is a config error" {
  AI_REVIEW_PROFILE=cms-ars,base run ai_review::resolve_profiles
  [ "$status" -eq 2 ]
  [[ "$output" == *"must be the FIRST entry"* ]]
}

@test "rubric: none listed after a profile is a config error" {
  AI_REVIEW_PROFILE=cms-ars,none run ai_review::resolve_profiles
  [ "$status" -eq 2 ]
  [[ "$output" == *"must be the FIRST entry"* ]]
}

@test "rubric: none with nothing after it is a config error" {
  AI_REVIEW_PROFILE=none run ai_review::resolve_profiles
  [ "$status" -eq 2 ]
  [[ "$output" == *"resolved to no rubric sources"* ]]
}

@test "rubric: an unknown name in the list is a config error" {
  AI_REVIEW_PROFILE=base,nope run ai_review::resolve_profiles
  [ "$status" -eq 2 ]
  [[ "$output" == *"'nope' is not a known profile"* ]]
}

# ── composition ─────────────────────────────────────────────────────────────

@test "rubric: the first source supplying a file is emitted verbatim" {
  AI_REVIEW_PROFILE=base ai_review::resolve_profiles
  run ai_review::rubric_block code-security.md "SECURITY PERSPECTIVE"
  [ "$status" -eq 0 ]
  [[ "$output" == *"Security Perspective"* ]]
  [[ "$output" != *"ADDITIONS"* ]]
}

@test "rubric: later sources are appended as additions, in order" {
  local a b; a="$(_profile_fixture one code-security.md)"; b="$(_profile_fixture two code-security.md)"
  AI_REVIEW_PROFILE="base,${a},${b}" ai_review::resolve_profiles
  run ai_review::rubric_block code-security.md "SECURITY PERSPECTIVE"
  [ "$status" -eq 0 ]
  [[ "$output" == *"Security Perspective"* ]]          # base still there
  local p1 p2
  p1="$(printf '%s' "$output" | grep -n 'ADDITION-FROM-one' | cut -d: -f1)"
  p2="$(printf '%s' "$output" | grep -n 'ADDITION-FROM-two' | cut -d: -f1)"
  [ "${p1}" -lt "${p2}" ]
}

@test "rubric: each addition claims precedence over everything above it" {
  local a; a="$(_profile_fixture one code-security.md)"
  AI_REVIEW_PROFILE="base,${a}" ai_review::resolve_profiles
  run ai_review::rubric_block code-security.md "SECURITY PERSPECTIVE"
  [[ "$output" == *"ADDS to everything above it and never replaces it"* ]]
  [[ "$output" == *"this section takes precedence"* ]]
}

@test "rubric: none,<profile> emits only the profile's rubric" {
  local a; a="$(_profile_fixture only code-security.md)"
  AI_REVIEW_PROFILE="none,${a}" ai_review::resolve_profiles
  run ai_review::rubric_block code-security.md "SECURITY PERSPECTIVE"
  [ "$status" -eq 0 ]
  [[ "$output" == *"ADDITION-FROM-only"* ]]
  [[ "$output" != *"Security Perspective"* ]]          # the floor is genuinely gone
}

@test "rubric: a source without the file contributes nothing" {
  local a; a="$(_profile_fixture nofiles)"
  AI_REVIEW_PROFILE="none,${a}" ai_review::resolve_profiles
  run ai_review::rubric_block code-security.md "SECURITY PERSPECTIVE"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

# ── the output-contract guard ───────────────────────────────────────────────

@test "rubric: require_rubric passes when a source supplies the file" {
  AI_REVIEW_PROFILE=base ai_review::resolve_profiles
  run ai_review::require_rubric pr-review.md
  [ "$status" -eq 0 ]
}

@test "rubric: require_rubric fails when no source supplies the contract file" {
  local a; a="$(_profile_fixture partial code-security.md)"
  AI_REVIEW_PROFILE="none,${a}" ai_review::resolve_profiles
  run ai_review::require_rubric pr-review.md
  [ "$status" -eq 2 ]
  [[ "$output" == *"No rubric source supplies pr-review.md"* ]]
  [[ "$output" == *"result marker"* ]]
}

@test "rubric: finding-adjudication.md is read from base, outside the list" {
  # `none` must not cost a program its false-positive filter.
  local a; a="$(_profile_fixture only code-security.md pr-review.md)"
  AI_REVIEW_PROFILE="none,${a}" ai_review::resolve_profiles
  export AI_REVIEW_AGAINST=origin/main # the adjudication prompt names the base ref
  run ai_review::build_adjudication_prompt '{"review_action":"COMMENT","comments":[]}'
  [ "$status" -eq 0 ]
  [[ "$output" == *"Finding Adjudication"* ]]
}

@test "rubric: no override path exists in either entrypoint" {
  # The old override helpers, by name. rubric_block (the additive composer) is
  # expected; pr_review::rubric / audit::rubric returning a path is not.
  ! grep -qE '(pr_review|audit)::rubric\b' \
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
