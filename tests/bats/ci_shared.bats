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
  PR_NUMBER_INPUT="7" EVENT_PR_NUMBER="" BASE_REF_INPUT="" EVENT_BASE_REF="" run ci::resolve_pr_context
  [ "$status" -ne 0 ]
  [[ "$output" == *"base ref"* ]]
  # Name the input that fixes it, and the PR it was asked about. The old
  # message said only "provide the base via checkout", which points at the
  # wrong knob: nothing a consumer does in actions/checkout populates this.
  [[ "$output" == *"base-ref"* ]]
  [[ "$output" == *"#7"* ]]
}

@test "resolve_pr_context writes pr and base" {
  PR_NUMBER_INPUT="" EVENT_PR_NUMBER="42" BASE_REF_INPUT="" EVENT_BASE_REF="main" run ci::resolve_pr_context
  [ "$status" -eq 0 ]
  grep -qx "skip=false" "${GITHUB_OUTPUT}"
  grep -qx "pr=42" "${GITHUB_OUTPUT}"
  grep -qx "base=main" "${GITHUB_OUTPUT}"
}

# ── forked pull requests ────────────────────────────────────────────────────
# GitHub withholds secrets and issues a read-only token for a fork PR, so
# there is no configuration in which the review can run or post. Skipping with
# a notice beats the old behaviour: the engine exited 2 with "requires
# ANTHROPIC_API_KEY", putting a red X on every external contribution.

@test "resolve_pr_context: a fork pull_request skips with a notice" {
  EVENT_NAME=pull_request IS_FORK_PR=true PR_NUMBER_INPUT="" EVENT_PR_NUMBER="42" \
    BASE_REF_INPUT="" EVENT_BASE_REF="main" run ci::resolve_pr_context
  [ "$status" -eq 0 ]
  grep -qx "skip=true" "${GITHUB_OUTPUT}"
  [[ "$output" == *"::notice::"* ]]
  [[ "$output" == *"fork"* ]]
}

@test "resolve_pr_context: the fork notice says how to review it anyway" {
  # Silence that looks like nothing happened sends a maintainer hunting for a
  # broken secret; the way out is a manual run.
  EVENT_NAME=pull_request IS_FORK_PR=true EVENT_PR_NUMBER="42" EVENT_BASE_REF="main" \
    run ci::resolve_pr_context
  [[ "$output" == *"pr-number"* ]]
  [[ "$output" == *"base-ref"* ]]
}

@test "resolve_pr_context: a same-repo pull_request is not skipped" {
  EVENT_NAME=pull_request IS_FORK_PR=false PR_NUMBER_INPUT="" EVENT_PR_NUMBER="42" \
    BASE_REF_INPUT="" EVENT_BASE_REF="main" run ci::resolve_pr_context
  [ "$status" -eq 0 ]
  grep -qx "skip=false" "${GITHUB_OUTPUT}"
  grep -qx "pr=42" "${GITHUB_OUTPUT}"
}

@test "resolve_pr_context: a manual run against a fork PR is NOT skipped" {
  # workflow_dispatch runs in the base repo: secrets and a write token are
  # both present, so the maintainer escape hatch must keep working. Guarding
  # on IS_FORK_PR alone would break exactly the path the notice recommends.
  EVENT_NAME=workflow_dispatch IS_FORK_PR=true PR_NUMBER_INPUT="99" \
    BASE_REF_INPUT="main" run ci::resolve_pr_context
  [ "$status" -eq 0 ]
  grep -qx "skip=false" "${GITHUB_OUTPUT}"
  grep -qx "pr=99" "${GITHUB_OUTPUT}"
}

@test "resolve_pr_context: a missing fork signal reviews, it does not skip" {
  # The default direction matters more than it looks. If IS_FORK_PR is unset or
  # empty — a renamed input, an event shape where the expression yields "" —
  # defaulting to "fork" would silently skip EVERY pull request: the workflow
  # stays green, posts nothing, and looks installed. Failing toward reviewing
  # is loud and recoverable; failing toward skipping is neither.
  EVENT_NAME=pull_request PR_NUMBER_INPUT="" EVENT_PR_NUMBER="42" \
    BASE_REF_INPUT="" EVENT_BASE_REF="main" run ci::resolve_pr_context
  [ "$status" -eq 0 ]
  grep -qx "skip=false" "${GITHUB_OUTPUT}"

  : >"${GITHUB_OUTPUT}"
  EVENT_NAME=pull_request IS_FORK_PR="" EVENT_PR_NUMBER="42" EVENT_BASE_REF="main" \
    run ci::resolve_pr_context
  [ "$status" -eq 0 ]
  grep -qx "skip=false" "${GITHUB_OUTPUT}"
}

@test "resolve_pr_context: absent fork signal behaves as before" {
  # Older callers, and the bats suite, set neither variable.
  PR_NUMBER_INPUT="" EVENT_PR_NUMBER="42" BASE_REF_INPUT="" EVENT_BASE_REF="main" \
    run ci::resolve_pr_context
  [ "$status" -eq 0 ]
  grep -qx "skip=false" "${GITHUB_OUTPUT}"
}

# The workflow_dispatch shape: no pull_request payload at all, both halves of
# the context supplied as inputs. This is what `pr-number` always implied was
# possible and never was.
@test "resolve_pr_context: base-ref input carries a dispatch with no event payload" {
  PR_NUMBER_INPUT="99" EVENT_PR_NUMBER="" BASE_REF_INPUT="develop" EVENT_BASE_REF="" \
    run ci::resolve_pr_context
  [ "$status" -eq 0 ]
  grep -qx "skip=false" "${GITHUB_OUTPUT}"
  grep -qx "pr=99" "${GITHUB_OUTPUT}"
  grep -qx "base=develop" "${GITHUB_OUTPUT}"
}

@test "resolve_pr_context: base-ref input wins over the event base ref" {
  PR_NUMBER_INPUT="" EVENT_PR_NUMBER="42" BASE_REF_INPUT="release-1.x" EVENT_BASE_REF="main" \
    run ci::resolve_pr_context
  [ "$status" -eq 0 ]
  grep -qx "base=release-1.x" "${GITHUB_OUTPUT}"
}

# Asymmetry is the bug this pair of inputs exists to prevent: an override for
# the number with none for the base is unusable off a pull_request event.
@test "resolve_pr_context: base-ref alone still skips, it does not invent a PR" {
  PR_NUMBER_INPUT="" EVENT_PR_NUMBER="" BASE_REF_INPUT="main" EVENT_BASE_REF="" \
    run ci::resolve_pr_context
  [ "$status" -eq 0 ]
  grep -qx "skip=true" "${GITHUB_OUTPUT}"
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
  [[ "$output" == *"review_action is REQUEST_CHANGES"* ]]
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

# ── gate_result: what `gate: true` blocks on ────────────────────────────────
# `gate` is a boolean; true fails the job on HIGH or CRITICAL. MEDIUM and LOW
# still post as comments — gating changes the pass/fail decision, not the
# report.

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

@test "gate=true does NOT block on MEDIUM or LOW" {
  local json="${BATS_TEST_TMPDIR}/f.json"
  _findings "${json}" MEDIUM LOW
  REVIEW_JSON="${json}" GATE=true run ci::gate_result
  [ "$status" -eq 0 ]
}

@test "gate=true blocks on HIGH" {
  local json="${BATS_TEST_TMPDIR}/f.json"
  _findings "${json}" HIGH
  REVIEW_JSON="${json}" GATE=true run ci::gate_result
  [ "$status" -eq 1 ]
}

@test "gate=true blocks on CRITICAL" {
  local json="${BATS_TEST_TMPDIR}/f.json"
  _findings "${json}" CRITICAL
  REVIEW_JSON="${json}" GATE=true run ci::gate_result
  [ "$status" -eq 1 ]
}

@test "severity values in the JSON are matched case-insensitively" {
  local json="${BATS_TEST_TMPDIR}/f.json"
  _findings "${json}" critical
  REVIEW_JSON="${json}" GATE=true run ci::gate_result
  [ "$status" -eq 1 ]
}

@test "an unrecognized severity is counted as blocking, not ignored" {
  local json="${BATS_TEST_TMPDIR}/f.json"
  _findings "${json}" SEV_BANANA
  REVIEW_JSON="${json}" GATE=true run ci::gate_result
  [ "$status" -eq 1 ]
  [[ "$output" == *"unrecognized severity"* ]]
}

@test "a missing severity field is counted as blocking" {
  local json="${BATS_TEST_TMPDIR}/f.json"
  echo '{"review_action":"COMMENT","comments":[{"title":"no severity"}]}' >"${json}"
  REVIEW_JSON="${json}" GATE=true run ci::gate_result
  [ "$status" -eq 1 ]
}

@test "threshold gating never blocks an APPROVE" {
  local json="${BATS_TEST_TMPDIR}/f.json"
  echo '{"review_action":"APPROVE","comments":[]}' >"${json}"
  REVIEW_JSON="${json}" GATE=true run ci::gate_result
  [ "$status" -eq 0 ]
}

@test "REQUEST_CHANGES blocks regardless of the threshold" {
  local json="${BATS_TEST_TMPDIR}/f.json"
  echo '{"review_action":"REQUEST_CHANGES","comments":[{"severity":"LOW","title":"x"}]}' >"${json}"
  REVIEW_JSON="${json}" GATE=true run ci::gate_result
  [ "$status" -eq 1 ]
}

@test "COMMENT with no comments array does not block under a threshold" {
  local json="${BATS_TEST_TMPDIR}/f.json"
  echo '{"review_action":"COMMENT"}' >"${json}"
  REVIEW_JSON="${json}" GATE=true run ci::gate_result
  [ "$status" -eq 0 ]
}

@test "a malformed comments array fails closed rather than passing the gate" {
  local json="${BATS_TEST_TMPDIR}/f.json"
  echo '{"review_action":"COMMENT","comments":["oops"]}' >"${json}"
  REVIEW_JSON="${json}" GATE=true run ci::gate_result
  [ "$status" -eq 1 ]
}

@test "a non-boolean gate value is a configuration error" {
  local json="${BATS_TEST_TMPDIR}/f.json"
  _findings "${json}" LOW
  REVIEW_JSON="${json}" GATE=critical run ci::gate_result
  [ "$status" -eq 1 ]
  [[ "$output" == *"gate takes true or false"* ]]
}

@test "gate=off is accepted as a synonym for false" {
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

@test "gate=false is advisory" {
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
