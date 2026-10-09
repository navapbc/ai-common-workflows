#!/usr/bin/env bats
# End-to-end tests for engines/test-classifier/harness/ai-test-classifier
# using stub CLIs and a throwaway git repo. No API keys, no network — the stubs
# return canned classifier responses and record what `gh` was asked to post.

bats_require_minimum_version 1.5.0

setup() {
  REPO_ROOT="$(cd "${BATS_TEST_DIRNAME}/../.." && pwd)"
  ENGINE="${REPO_ROOT}/engines/test-classifier/harness/ai-test-classifier"
  STUBS="${REPO_ROOT}/tests/stubs"
  FIX="${REPO_ROOT}/tests/fixtures"
  export PATH="${STUBS}:${PATH}"
  export AI_REVIEW_TOOL=claude ANTHROPIC_API_KEY=test CI=true NO_COLOR=1
  # Host/CI tokens and endpoint config must never leak into test behavior.
  unset GITHUB_TOKEN GH_TOKEN AI_REVIEW_PROVIDER AI_REVIEW_MODEL \
    AWS_REGION AWS_DEFAULT_REGION METRICSAI_WEBHOOK_URL METRICSAI_WEBHOOK_KEY || true

  WORK="$(mktemp -d)"
  cd "${WORK}"
  git init -qb main
  git config user.email t@t
  git config user.name t
  mkdir -p src
  echo "print('hi')" > src/app.py
  printf 'def test_reads_api_key():\n    pass\n' > src/app_test.py
  git add -A && git commit -qm base
  git update-ref refs/remotes/origin/main main
  git checkout -qb feature
  printf 'import os\napi_key = os.environ["K"]\nprint(api_key)\n' > src/app.py
  printf 'def test_reads_api_key():\n    assert False\n' > src/app_test.py
  git add -A && git commit -qm change
}

teardown() {
  rm -rf "${WORK}"
}

@test "classifier: CLASSIFIED fixture prints report and exits 0 (advisory)" {
  STUB_RESPONSE_FILE="${FIX}/classifier-response-classified.txt" \
    run bash "${ENGINE}" --against origin/main
  [ "$status" -eq 0 ]
  [[ "$output" == *"Classifier result: CLASSIFIED"* ]]
}

@test "classifier: NO_ACTION fixture exits 0" {
  STUB_RESPONSE_FILE="${FIX}/classifier-response-no-action.txt" \
    run bash "${ENGINE}" --against origin/main
  [ "$status" -eq 0 ]
  [[ "$output" == *"NO_ACTION"* ]]
}

@test "classifier: missing result marker fails (exit 1)" {
  STUB_RESPONSE_FILE="${FIX}/classifier-response-no-marker.txt" \
    run bash "${ENGINE}" --against origin/main
  [ "$status" -eq 1 ]
  [[ "$output" == *"Could not parse classifier result marker"* ]]
}

@test "classifier: --dry-run prints the plan and makes no AI call" {
  export STUB_CALLS="${BATS_TEST_TMPDIR}/calls.log"
  STUB_RESPONSE_FILE="${FIX}/classifier-response-classified.txt" \
    run bash "${ENGINE}" --against origin/main --dry-run
  [ "$status" -eq 0 ]
  [[ "$output" == *"DRY-RUN"* ]]
  [[ "$output" == *"src/app.py"* ]]
  [ ! -s "${STUB_CALLS}" ]
}

@test "classifier: --json-only prints just the classifications JSON" {
  STUB_RESPONSE_FILE="${FIX}/classifier-response-classified.txt" \
    run --separate-stderr bash "${ENGINE}" --against origin/main --json-only
  [ "$status" -eq 0 ]
  echo "$output" | python3 -c 'import json,sys; d=json.loads(sys.stdin.read()); assert len(d["classifications"])==2'
}

@test "classifier: --json-out writes the JSON block to a file" {
  out="${BATS_TEST_TMPDIR}/classifier.json"
  STUB_RESPONSE_FILE="${FIX}/classifier-response-classified.txt" \
    run bash "${ENGINE}" --against origin/main --json-out "${out}"
  [ "$status" -eq 0 ]
  python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); assert d["mode"]=="OBSERVED" and len(d["classifications"])==2' "${out}"
}

@test "classifier: --gate exits 1 on CLASSIFIED" {
  STUB_RESPONSE_FILE="${FIX}/classifier-response-classified.txt" \
    run bash "${ENGINE}" --against origin/main --gate
  [ "$status" -eq 1 ]
}

@test "classifier: --gate exits 0 on NO_ACTION" {
  STUB_RESPONSE_FILE="${FIX}/classifier-response-no-action.txt" \
    run bash "${ENGINE}" --against origin/main --gate
  [ "$status" -eq 0 ]
}

@test "classifier: --gate --no-block exits 0 despite CLASSIFIED" {
  STUB_RESPONSE_FILE="${FIX}/classifier-response-classified.txt" \
    run bash "${ENGINE}" --against origin/main --gate --no-block
  [ "$status" -eq 0 ]
}

@test "classifier: --post-only posts one comment via gh and exits 0" {
  json="${BATS_TEST_TMPDIR}/classifier.json"
  posted="${BATS_TEST_TMPDIR}/posted.log"
  STUB_RESPONSE_FILE="${FIX}/classifier-response-classified.txt" \
    run bash "${ENGINE}" --against origin/main --json-out "${json}"
  [ "$status" -eq 0 ]
  AI_REVIEW_REPO=stub-org/stub-repo STUB_GH_POSTED="${posted}" \
    run bash "${ENGINE}" --post-only --pr 41 --json-in "${json}" --against origin/main
  [ "$status" -eq 0 ]
  grep -q 'test-classifier: AI triage of failing tests' "${posted}"
  grep -q 'APPLICATION_BUG' "${posted}"
  # The comment anchors to a changed test file as a file-level review comment.
  grep -q 'src/app_test.py' "${posted}"
}

# A clean run (nothing needed triage) posts nothing by default: the job's own
# check already says the classifier ran, and a "no action required" comment on
# every green push is how a bot becomes noise. AI_REVIEW_POST_WHEN_CLEAN=true
# opts back in for teams harvesting the true negative's 👍/👎.
@test "classifier: --post-only stays quiet on an empty triage by default" {
  json="${BATS_TEST_TMPDIR}/classifier.json"
  posted="${BATS_TEST_TMPDIR}/posted.log"
  STUB_RESPONSE_FILE="${FIX}/classifier-response-no-action.txt" \
    run bash "${ENGINE}" --against origin/main --json-out "${json}"
  [ "$status" -eq 0 ]
  AI_REVIEW_REPO=stub-org/stub-repo STUB_GH_POSTED="${posted}" \
    run bash "${ENGINE}" --post-only --pr 41 --json-in "${json}" --against origin/main
  [ "$status" -eq 0 ]
  [ ! -e "${posted}" ]
  [[ "$output" == *"Nothing needed triage; not posting a comment"* ]]
  [[ "$output" == *"post-when-clean"* ]]
}

@test "classifier: --post-only posts the 'no action' comment when AI_REVIEW_POST_WHEN_CLEAN=true" {
  json="${BATS_TEST_TMPDIR}/classifier.json"
  posted="${BATS_TEST_TMPDIR}/posted.log"
  STUB_RESPONSE_FILE="${FIX}/classifier-response-no-action.txt" \
    run bash "${ENGINE}" --against origin/main --json-out "${json}"
  [ "$status" -eq 0 ]
  AI_REVIEW_POST_WHEN_CLEAN=true AI_REVIEW_REPO=stub-org/stub-repo STUB_GH_POSTED="${posted}" \
    run bash "${ENGINE}" --post-only --pr 41 --json-in "${json}" --against origin/main
  [ "$status" -eq 0 ]
  grep -q 'test-classifier: AI triage of failing tests' "${posted}"
  grep -q 'no action required' "${posted}"
}

@test "classifier: a non-boolean AI_REVIEW_POST_WHEN_CLEAN warns and stays quiet" {
  json="${BATS_TEST_TMPDIR}/classifier.json"
  posted="${BATS_TEST_TMPDIR}/posted.log"
  STUB_RESPONSE_FILE="${FIX}/classifier-response-no-action.txt" \
    run bash "${ENGINE}" --against origin/main --json-out "${json}"
  [ "$status" -eq 0 ]
  AI_REVIEW_POST_WHEN_CLEAN=yep AI_REVIEW_REPO=stub-org/stub-repo STUB_GH_POSTED="${posted}" \
    run bash "${ENGINE}" --post-only --pr 41 --json-in "${json}" --against origin/main
  [ "$status" -eq 0 ]
  [ ! -e "${posted}" ]
  [[ "$output" == *"is not a boolean"* ]]
}

@test "classifier: post-when-clean never suppresses verdicts" {
  json="${BATS_TEST_TMPDIR}/classifier.json"
  posted="${BATS_TEST_TMPDIR}/posted.log"
  STUB_RESPONSE_FILE="${FIX}/classifier-response-classified.txt" \
    run bash "${ENGINE}" --against origin/main --json-out "${json}"
  [ "$status" -eq 0 ]
  AI_REVIEW_POST_WHEN_CLEAN=false AI_REVIEW_REPO=stub-org/stub-repo STUB_GH_POSTED="${posted}" \
    run bash "${ENGINE}" --post-only --pr 41 --json-in "${json}" --against origin/main
  [ "$status" -eq 0 ]
  grep -q 'APPLICATION_BUG' "${posted}"
}

# The one exception to quiet: a clean run on a PR whose newest classifier
# comment is a VERDICT posts "no action required" so the stale verdict is
# visibly superseded. A newer no-action comment means nothing to supersede, so
# clean pushes never chain.
@test "classifier: a clean run supersedes a posted verdict even by default" {
  json="${BATS_TEST_TMPDIR}/classifier.json"
  posted="${BATS_TEST_TMPDIR}/posted.log"
  comments="${BATS_TEST_TMPDIR}/existing.ndjson"
  printf '{"created_at":"2026-01-01T00:00:00Z","body":"test-classifier: AI triage of failing tests\\n\\n## AI Test Classifier — triage of failing tests\\n..."}\n' > "${comments}"
  STUB_RESPONSE_FILE="${FIX}/classifier-response-no-action.txt" \
    run bash "${ENGINE}" --against origin/main --json-out "${json}"
  [ "$status" -eq 0 ]
  AI_REVIEW_REPO=stub-org/stub-repo STUB_GH_COMMENTS="${comments}" STUB_GH_POSTED="${posted}" \
    run bash "${ENGINE}" --post-only --pr 41 --json-in "${json}" --against origin/main
  [ "$status" -eq 0 ]
  [[ "$output" == *"visibly superseded"* ]]
  grep -q 'no action required' "${posted}"
}

@test "classifier: a clean run does not chain after an earlier no-action comment" {
  json="${BATS_TEST_TMPDIR}/classifier.json"
  posted="${BATS_TEST_TMPDIR}/posted.log"
  comments="${BATS_TEST_TMPDIR}/existing.ndjson"
  {
    printf '{"created_at":"2026-01-01T00:00:00Z","body":"test-classifier: AI triage of failing tests\\n\\n## AI Test Classifier — triage of failing tests"}\n'
    printf '{"created_at":"2026-01-02T00:00:00Z","body":"test-classifier: AI triage of failing tests\\n\\n## AI Test Classifier — no action required"}\n'
  } > "${comments}"
  STUB_RESPONSE_FILE="${FIX}/classifier-response-no-action.txt" \
    run bash "${ENGINE}" --against origin/main --json-out "${json}"
  [ "$status" -eq 0 ]
  AI_REVIEW_REPO=stub-org/stub-repo STUB_GH_COMMENTS="${comments}" STUB_GH_POSTED="${posted}" \
    run bash "${ENGINE}" --post-only --pr 41 --json-in "${json}" --against origin/main
  [ "$status" -eq 0 ]
  [ ! -e "${posted}" ]
  [[ "$output" == *"Nothing needed triage; not posting a comment"* ]]
}

@test "classifier: an unrelated bot comment is not mistaken for a verdict" {
  json="${BATS_TEST_TMPDIR}/classifier.json"
  posted="${BATS_TEST_TMPDIR}/posted.log"
  comments="${BATS_TEST_TMPDIR}/existing.ndjson"
  printf '{"created_at":"2026-01-01T00:00:00Z","body":"security(high): something else entirely"}\n' > "${comments}"
  STUB_RESPONSE_FILE="${FIX}/classifier-response-no-action.txt" \
    run bash "${ENGINE}" --against origin/main --json-out "${json}"
  [ "$status" -eq 0 ]
  AI_REVIEW_REPO=stub-org/stub-repo STUB_GH_COMMENTS="${comments}" STUB_GH_POSTED="${posted}" \
    run bash "${ENGINE}" --post-only --pr 41 --json-in "${json}" --against origin/main
  [ "$status" -eq 0 ]
  [ ! -e "${posted}" ]
}

@test "classifier: AI_REVIEW_POST_WHEN_CLEAN accepts the usual boolean spellings" {
  json="${BATS_TEST_TMPDIR}/classifier.json"
  STUB_RESPONSE_FILE="${FIX}/classifier-response-no-action.txt" \
    run bash "${ENGINE}" --against origin/main --json-out "${json}"
  [ "$status" -eq 0 ]
  local v
  for v in TRUE " 1 " on yes; do
    posted="${BATS_TEST_TMPDIR}/posted-${v// /_}.log"
    AI_REVIEW_POST_WHEN_CLEAN="${v}" AI_REVIEW_REPO=stub-org/stub-repo STUB_GH_POSTED="${posted}" \
      run bash "${ENGINE}" --post-only --pr 41 --json-in "${json}" --against origin/main
    [ "$status" -eq 0 ]
    grep -q 'no action required' "${posted}"
  done
  for v in FALSE 0 off no; do
    posted="${BATS_TEST_TMPDIR}/quiet-${v}.log"
    AI_REVIEW_POST_WHEN_CLEAN="${v}" AI_REVIEW_REPO=stub-org/stub-repo STUB_GH_POSTED="${posted}" \
      run bash "${ENGINE}" --post-only --pr 41 --json-in "${json}" --against origin/main
    [ "$status" -eq 0 ]
    [ ! -e "${posted}" ]
    [[ "$output" != *"is not a boolean"* ]]
  done
}

@test "classifier: --post-comment (in-process) posts the 'no action' comment when opted in" {
  posted="${BATS_TEST_TMPDIR}/posted.log"
  STUB_RESPONSE_FILE="${FIX}/classifier-response-no-action.txt" \
    AI_REVIEW_POST_WHEN_CLEAN=true AI_REVIEW_REPO=stub-org/stub-repo STUB_GH_POSTED="${posted}" \
    run bash "${ENGINE}" --post-comment --pr 41 --against origin/main
  [ "$status" -eq 0 ]
  grep -q 'no action required' "${posted}"
}

@test "classifier: --simulate NO_ACTION with --post-comment stays quiet by default" {
  posted="${BATS_TEST_TMPDIR}/posted.log"
  export STUB_CALLS="${BATS_TEST_TMPDIR}/calls.log"
  AI_SIMULATE_RESULT=NO_ACTION AI_REVIEW_REPO=stub-org/stub-repo STUB_GH_POSTED="${posted}" \
    run bash "${ENGINE}" --simulate --post-comment --pr 41 --against origin/main
  [ "$status" -eq 0 ]
  [ ! -e "${posted}" ]
  [ ! -s "${STUB_CALLS}" ]
  [[ "$output" == *"Nothing needed triage; not posting a comment"* ]]
}

@test "classifier: --post-comment (in-process) stays quiet on an empty triage by default" {
  posted="${BATS_TEST_TMPDIR}/posted.log"
  STUB_RESPONSE_FILE="${FIX}/classifier-response-no-action.txt" \
    AI_REVIEW_REPO=stub-org/stub-repo STUB_GH_POSTED="${posted}" \
    run bash "${ENGINE}" --post-comment --pr 41 --against origin/main
  [ "$status" -eq 0 ]
  [[ "$output" == *"NO_ACTION"* ]]
  [ ! -e "${posted}" ]
  [[ "$output" == *"Nothing needed triage; not posting a comment"* ]]
}

@test "classifier: --post-only without --pr is a config error (exit 2)" {
  json="${BATS_TEST_TMPDIR}/classifier.json"
  echo '{"classifications":[]}' > "${json}"
  run bash "${ENGINE}" --post-only --json-in "${json}" --against origin/main
  [ "$status" -eq 2 ]
}

@test "classifier: OBSERVED is the default prompt mode; --no-run-suite selects INFERRED" {
  export STUB_PROMPT_LOG="${BATS_TEST_TMPDIR}/prompts.log"
  STUB_RESPONSE_FILE="${FIX}/classifier-response-classified.txt" \
    run bash "${ENGINE}" --against origin/main
  [ "$status" -eq 0 ]
  grep -q 'in OBSERVED mode' "${STUB_PROMPT_LOG}"

  : > "${STUB_PROMPT_LOG}"
  STUB_RESPONSE_FILE="${FIX}/classifier-response-classified.txt" \
    run bash "${ENGINE}" --against origin/main --no-run-suite
  [ "$status" -eq 0 ]
  grep -q 'in INFERRED mode' "${STUB_PROMPT_LOG}"
}

@test "classifier: invalid AI_REVIEW_PROVIDER is a config error (exit 2)" {
  AI_REVIEW_PROVIDER=bogus STUB_RESPONSE_FILE="${FIX}/classifier-response-classified.txt" \
    run bash "${ENGINE}" --against origin/main
  [ "$status" -eq 2 ]
}

@test "classifier: provider=bedrock without AWS_REGION is a config error (exit 2)" {
  AI_REVIEW_PROVIDER=bedrock STUB_RESPONSE_FILE="${FIX}/classifier-response-classified.txt" \
    run bash "${ENGINE}" --against origin/main
  [ "$status" -eq 2 ]
  [[ "$output" == *"AWS_REGION"* ]]
}

@test "classifier: no change under test exits 0 without an AI call" {
  git checkout -q main
  export STUB_CALLS="${BATS_TEST_TMPDIR}/calls.log"
  STUB_RESPONSE_FILE="${FIX}/classifier-response-classified.txt" \
    run bash "${ENGINE}" --against origin/main
  [ "$status" -eq 0 ]
  [[ "$output" == *"nothing to classify"* ]]
  [ ! -s "${STUB_CALLS}" ]
}
