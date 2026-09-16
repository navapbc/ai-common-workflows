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
  [[ "$output" == *"AI review result is REQUEST_CHANGES"* ]]
}

@test "gate_result passes on APPROVE with gate=true" {
  local json="${BATS_TEST_TMPDIR}/findings.json"
  echo '{"review_action":"APPROVE"}' >"${json}"
  REVIEW_JSON="${json}" GATE=true run ci::gate_result
  [ "$status" -eq 0 ]
  grep -qx "result=APPROVE" "${GITHUB_OUTPUT}"
}

@test "gate_result reports APPROVE when the findings file is absent (empty diff)" {
  # The engine exits 0 without writing a findings file only when there is no
  # diff. `result` must still be set: docs tell consumers to gate on it, and an
  # empty output silently breaks their condition. Matches the Jenkins plugin.
  REVIEW_JSON="${BATS_TEST_TMPDIR}/nope.json" GATE=true run ci::gate_result
  [ "$status" -eq 0 ]
  grep -qx "result=APPROVE" "${GITHUB_OUTPUT}"
}

@test "gate_result FAILS on an unparseable findings file (never assumes APPROVE)" {
  local json="${BATS_TEST_TMPDIR}/truncated.json"
  printf '{"review_action": "COMM' >"${json}"
  REVIEW_JSON="${json}" GATE=false run ci::gate_result
  [ "$status" -eq 1 ]
  [[ "$output" == *"Refusing to assume APPROVE"* ]]
  ! grep -q "result=" "${GITHUB_OUTPUT}"
}

@test "gate_result FAILS on an unrecognized review_action" {
  local json="${BATS_TEST_TMPDIR}/weird.json"
  echo '{"review_action":"LGTM"}' >"${json}"
  REVIEW_JSON="${json}" GATE=false run ci::gate_result
  [ "$status" -eq 1 ]
  [[ "$output" == *"Refusing to assume APPROVE"* ]]
}

# ── gate_result: severity levels ────────────────────────────────────────────
# GATE is one knob: off | critical | high | any (true/false alias any/off).
# Everything still posts as a comment; only the pass/fail decision changes.

_findings() { # $1 = file, rest = severities
  local f="$1"; shift
  local out='{"review_action":"COMMENT","comments":['
  local sep=""
  for sev in "$@"; do
    out+="${sep}{\"severity\":\"${sev}\",\"title\":\"finding ${sev}\"}"
    sep=","
  done
  echo "${out}]}" >"${f}"
}

@test "gate=high does not block a MEDIUM-only review" {
  local json="${BATS_TEST_TMPDIR}/f.json"
  _findings "${json}" MEDIUM LOW
  REVIEW_JSON="${json}" GATE=high run ci::gate_result
  [ "$status" -eq 0 ]
  grep -qx "result=COMMENT" "${GITHUB_OUTPUT}"
}

@test "gate=high blocks on HIGH" {
  local json="${BATS_TEST_TMPDIR}/f.json"
  _findings "${json}" LOW HIGH
  REVIEW_JSON="${json}" GATE=high run ci::gate_result
  [ "$status" -eq 1 ]
}

@test "gate=high blocks on CRITICAL" {
  local json="${BATS_TEST_TMPDIR}/f.json"
  _findings "${json}" CRITICAL
  REVIEW_JSON="${json}" GATE=high run ci::gate_result
  [ "$status" -eq 1 ]
}

@test "gate=critical does not block on HIGH" {
  local json="${BATS_TEST_TMPDIR}/f.json"
  _findings "${json}" HIGH
  REVIEW_JSON="${json}" GATE=critical run ci::gate_result
  [ "$status" -eq 0 ]
}

@test "gate=any (default) still blocks on a single LOW" {
  local json="${BATS_TEST_TMPDIR}/f.json"
  _findings "${json}" LOW
  REVIEW_JSON="${json}" GATE=true run ci::gate_result
  [ "$status" -eq 1 ]
}

@test "gate is case-insensitive about the severity values" {
  local json="${BATS_TEST_TMPDIR}/f.json"
  _findings "${json}" critical
  REVIEW_JSON="${json}" GATE=high run ci::gate_result
  [ "$status" -eq 1 ]
}

@test "an unrecognized severity is counted as blocking, not ignored" {
  local json="${BATS_TEST_TMPDIR}/f.json"
  _findings "${json}" SEV_BANANA
  REVIEW_JSON="${json}" GATE=critical run ci::gate_result
  [ "$status" -eq 1 ]
  [[ "$output" == *"unrecognized severity"* ]]
}

@test "a missing severity field is counted as blocking" {
  local json="${BATS_TEST_TMPDIR}/f.json"
  echo '{"review_action":"COMMENT","comments":[{"title":"no severity"}]}' >"${json}"
  REVIEW_JSON="${json}" GATE=critical run ci::gate_result
  [ "$status" -eq 1 ]
}

@test "threshold gating never blocks an APPROVE" {
  local json="${BATS_TEST_TMPDIR}/f.json"
  echo '{"review_action":"APPROVE","comments":[]}' >"${json}"
  REVIEW_JSON="${json}" GATE=high run ci::gate_result
  [ "$status" -eq 0 ]
}

@test "REQUEST_CHANGES blocks regardless of the threshold" {
  local json="${BATS_TEST_TMPDIR}/f.json"
  echo '{"review_action":"REQUEST_CHANGES","comments":[{"severity":"LOW","title":"x"}]}' >"${json}"
  REVIEW_JSON="${json}" GATE=critical run ci::gate_result
  [ "$status" -eq 1 ]
}

@test "COMMENT with no comments array does not block under a threshold" {
  local json="${BATS_TEST_TMPDIR}/f.json"
  echo '{"review_action":"COMMENT"}' >"${json}"
  REVIEW_JSON="${json}" GATE=high run ci::gate_result
  [ "$status" -eq 0 ]
}

@test "a malformed comments array fails closed rather than passing the gate" {
  local json="${BATS_TEST_TMPDIR}/f.json"
  echo '{"review_action":"COMMENT","comments":["oops"]}' >"${json}"
  REVIEW_JSON="${json}" GATE=high run ci::gate_result
  [ "$status" -eq 1 ]
}

@test "an unrecognized gate value is a configuration error" {
  local json="${BATS_TEST_TMPDIR}/f.json"
  _findings "${json}" LOW
  REVIEW_JSON="${json}" GATE=medium run ci::gate_result
  [ "$status" -eq 1 ]
  [[ "$output" == *"unrecognized gate"* ]]
}

@test "gate=off is advisory even with CRITICAL findings" {
  local json="${BATS_TEST_TMPDIR}/f.json"
  _findings "${json}" CRITICAL
  REVIEW_JSON="${json}" GATE=off run ci::gate_result
  [ "$status" -eq 0 ]
  grep -qx "result=COMMENT" "${GITHUB_OUTPUT}"
}

@test "gate unset defaults to advisory" {
  local json="${BATS_TEST_TMPDIR}/f.json"
  _findings "${json}" CRITICAL
  REVIEW_JSON="${json}" run ci::gate_result
  [ "$status" -eq 0 ]
}

@test "gate=true remains an alias for any" {
  local json="${BATS_TEST_TMPDIR}/f.json"
  _findings "${json}" LOW
  REVIEW_JSON="${json}" GATE=true run ci::gate_result
  [ "$status" -eq 1 ]
}

@test "gate=false remains an alias for off" {
  local json="${BATS_TEST_TMPDIR}/f.json"
  _findings "${json}" CRITICAL
  REVIEW_JSON="${json}" GATE=false run ci::gate_result
  [ "$status" -eq 0 ]
}

@test "ensure_base_ref warns (not silently) when the base ref cannot be fetched" {
  cd "${BATS_TEST_TMPDIR}"
  git init -q norepo && cd norepo
  git config user.email t@t && git config user.name t
  git commit -q --allow-empty -m x
  git remote add origin "${BATS_TEST_TMPDIR}/does-not-exist.git"
  BASE=main run ci::ensure_base_ref
  [ "$status" -eq 0 ]
  [[ "$output" == *"::warning::"* ]]
  [[ "$output" == *"Could not fetch the base ref"* ]]
}

@test "ensure_base_ref does not persist the token into .git/config" {
  cd "${BATS_TEST_TMPDIR}"
  git init -q --bare up.git
  git init -q src && cd src
  git config user.email t@t && git config user.name t
  git checkout -qb main && echo a >f && git add -A && git commit -qm base
  git remote add origin "${BATS_TEST_TMPDIR}/up.git" && git push -q origin main
  BASE=main BASE_REF_TOKEN=super-secret-value run ci::ensure_base_ref
  [ "$status" -eq 0 ]
  run git rev-parse --verify --quiet origin/main
  [ "$status" -eq 0 ]
  ! grep -q "super-secret-value" .git/config
}
