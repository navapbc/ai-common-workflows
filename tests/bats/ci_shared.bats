#!/usr/bin/env bats
#
# Unit tests for the shared GitHub Actions plumbing (workflows/_shared/lib/ci.sh).
# These functions back the composite action's generic steps; testing them here
# is the payoff of factoring them into bash instead of inline YAML (inline
# composite steps cannot be run outside GitHub).

setup() {
  REPO_ROOT="$(cd "${BATS_TEST_DIRNAME}/../.." && pwd)"
  CI_LIB="${REPO_ROOT}/workflows/_shared/lib/ci.sh"
  # shellcheck disable=SC1090
  source "${CI_LIB}"
  export GITHUB_OUTPUT="${BATS_TEST_TMPDIR}/gh-output"
  : >"${GITHUB_OUTPUT}"
}

# ── validate_inputs ─────────────────────────────────────────────────────────

@test "validate_inputs accepts claude+api" {
  AI_TOOL=claude PROVIDER=api run ci::validate_inputs
  [ "$status" -eq 0 ]
}

@test "validate_inputs rejects an unknown tool" {
  AI_TOOL=bard PROVIDER=api run ci::validate_inputs
  [ "$status" -ne 0 ]
  [[ "$output" == *"ai-tool must be"* ]]
}

@test "validate_inputs rejects an unknown provider" {
  AI_TOOL=claude PROVIDER=nonsense run ci::validate_inputs
  [ "$status" -ne 0 ]
  [[ "$output" == *"provider must be"* ]]
}

@test "validate_inputs: bedrock accepts claude and codex" {
  AI_TOOL=claude PROVIDER=bedrock run ci::validate_inputs
  [ "$status" -eq 0 ]
  AI_TOOL=codex PROVIDER=bedrock run ci::validate_inputs
  [ "$status" -eq 0 ]
}

@test "validate_inputs: bedrock rejects copilot" {
  AI_TOOL=copilot PROVIDER=bedrock run ci::validate_inputs
  [ "$status" -ne 0 ]
  [[ "$output" == *"claude or codex"* ]]
}

@test "validate_inputs: azure requires codex" {
  AI_TOOL=claude PROVIDER=azure run ci::validate_inputs
  [ "$status" -ne 0 ]
  [[ "$output" == *"only supported with ai-tool=codex"* ]]
}

@test "validate_inputs accepts codex+azure" {
  AI_TOOL=codex PROVIDER=azure run ci::validate_inputs
  [ "$status" -eq 0 ]
}

# ── resolve_pr_context ──────────────────────────────────────────────────────

@test "resolve_pr_context skips when no PR number" {
  PR_NUMBER_INPUT="" EVENT_PR_NUMBER="" EVENT_BASE_REF="" run ci::resolve_pr_context
  [ "$status" -eq 0 ]
  grep -qx "skip=true" "${GITHUB_OUTPUT}"
}

@test "resolve_pr_context errors when PR present but base missing" {
  PR_NUMBER_INPUT="7" EVENT_PR_NUMBER="" EVENT_BASE_REF="" run ci::resolve_pr_context
  [ "$status" -ne 0 ]
  [[ "$output" == *"base ref"* ]]
}

@test "resolve_pr_context writes pr and base" {
  PR_NUMBER_INPUT="" EVENT_PR_NUMBER="42" EVENT_BASE_REF="main" run ci::resolve_pr_context
  [ "$status" -eq 0 ]
  grep -qx "skip=false" "${GITHUB_OUTPUT}"
  grep -qx "pr=42" "${GITHUB_OUTPUT}"
  grep -qx "base=main" "${GITHUB_OUTPUT}"
}

# ── gate_result ─────────────────────────────────────────────────────────────

@test "gate_result writes result and does not fail when advisory" {
  local json="${BATS_TEST_TMPDIR}/findings.json"
  echo '{"review_action":"COMMENT"}' >"${json}"
  REVIEW_JSON="${json}" GATE=false run ci::gate_result
  [ "$status" -eq 0 ]
  grep -qx "result=COMMENT" "${GITHUB_OUTPUT}"
}

@test "gate_result fails on non-APPROVE when gate=true" {
  local json="${BATS_TEST_TMPDIR}/findings.json"
  echo '{"review_action":"REQUEST_CHANGES"}' >"${json}"
  REVIEW_JSON="${json}" GATE=true run ci::gate_result
  [ "$status" -ne 0 ]
  [[ "$output" == *"gate is enabled"* ]]
}

@test "gate_result passes on APPROVE with gate=true" {
  local json="${BATS_TEST_TMPDIR}/findings.json"
  echo '{"review_action":"APPROVE"}' >"${json}"
  REVIEW_JSON="${json}" GATE=true run ci::gate_result
  [ "$status" -eq 0 ]
  grep -qx "result=APPROVE" "${GITHUB_OUTPUT}"
}

@test "gate_result no-ops when the findings file is absent" {
  REVIEW_JSON="${BATS_TEST_TMPDIR}/nope.json" GATE=true run ci::gate_result
  [ "$status" -eq 0 ]
}
