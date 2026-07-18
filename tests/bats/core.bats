#!/usr/bin/env bats
# Unit tests for engine/lib/core.sh — marker parsing, JSON extraction, batch
# planning/packing/folding, and the endpoint matrix.

setup() {
  ENGINE_HOME="$(cd "${BATS_TEST_DIRNAME}/../../engine" && pwd)"
  export ENGINE_HOME
  SKILL_NAME="test"
  CI=true
  # shellcheck disable=SC1091
  source "${ENGINE_HOME}/lib/core.sh"
  # shellcheck disable=SC1091
  source "${ENGINE_HOME}/lib/endpoints.sh"
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
  run bash -c 'source "'"${ENGINE_HOME}"'/lib/core.sh"; printf "d1\ta|b\nd2\tc\nd3\td\nd4\te\nd5\tf\n" | ai_review::pack_batches 3 | wc -l'
  [ "$output" -le 3 ]
}

@test "pack_batches passes through when already within cap" {
  run bash -c 'source "'"${ENGINE_HOME}"'/lib/core.sh"; printf "d1\ta\nd2\tb\n" | ai_review::pack_batches 4 | wc -l'
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

@test "endpoint: bedrock rejects non-claude tools" {
  AI_REVIEW_TOOL_RESOLVED=codex AI_REVIEW_PROVIDER=bedrock run ai_review::configure_endpoint
  [ "$status" -eq 2 ]
  [[ "$output" == *"only supported with AI_REVIEW_TOOL=claude"* ]]
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

@test "endpoint: vertex requires project id and region" {
  AI_REVIEW_TOOL_RESOLVED=claude AI_REVIEW_PROVIDER=vertex run ai_review::configure_endpoint
  [ "$status" -eq 2 ]
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
