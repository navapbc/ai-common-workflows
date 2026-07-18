#!/usr/bin/env bats
# End-to-end tests for engine/bin/ai-pr-review using stub CLIs and a throwaway
# git repo. No API keys, no network — the stubs return canned AI responses and
# record what `gh` was asked to post.

bats_require_minimum_version 1.5.0

setup() {
  REPO_ROOT="$(cd "${BATS_TEST_DIRNAME}/../.." && pwd)"
  ENGINE="${REPO_ROOT}/engine/bin/ai-pr-review"
  STUBS="${REPO_ROOT}/tests/stubs"
  FIX="${REPO_ROOT}/tests/fixtures"
  export PATH="${STUBS}:${PATH}"
  export AI_REVIEW_TOOL=claude ANTHROPIC_API_KEY=test CI=true NO_COLOR=1

  WORK="$(mktemp -d)"
  cd "${WORK}"
  git init -qb main
  git config user.email t@t
  git config user.name t
  mkdir -p src infra
  echo "print('hi')" > src/app.py
  git add -A && git commit -qm base
  git update-ref refs/remotes/origin/main main
  git checkout -qb feature
  printf 'import os\napi_key = "AKIAIOSFODNN7EXAMPLE"\nprint(api_key)\n' > src/app.py
  printf 'resource "aws_db_instance" "db" {\n  allocated_storage = 10\n}\n' > infra/rds.tf
  git add -A && git commit -qm change
}

teardown() {
  rm -rf "${WORK}"
}

@test "single-call review prints report and exits 0 (advisory)" {
  STUB_RESPONSE_FILE="${FIX}/response-comment.txt" run bash "${ENGINE}" --against origin/main
  [ "$status" -eq 0 ]
  [[ "$output" == *"Review result: COMMENT"* ]]
}

@test "--json-only prints just the findings JSON" {
  # --separate-stderr so $output is stdout only (status logs go to stderr).
  STUB_RESPONSE_FILE="${FIX}/response-comment.txt" run --separate-stderr bash "${ENGINE}" --against origin/main --json-only
  [ "$status" -eq 0 ]
  echo "$output" | python3 -c 'import json,sys; d=json.loads(sys.stdin.read()); assert len(d["comments"])==2'
}

@test "--gate exits 1 on COMMENT" {
  STUB_RESPONSE_FILE="${FIX}/response-comment.txt" run bash "${ENGINE}" --against origin/main --gate
  [ "$status" -eq 1 ]
}

@test "--gate --no-block exits 0 despite findings" {
  STUB_RESPONSE_FILE="${FIX}/response-comment.txt" run bash "${ENGINE}" --against origin/main --gate --no-block
  [ "$status" -eq 0 ]
}

@test "APPROVE fixture exits 0 even with --gate" {
  STUB_RESPONSE_FILE="${FIX}/response-approve.txt" run bash "${ENGINE}" --against origin/main --gate
  [ "$status" -eq 0 ]
}

@test "--dry-run makes no AI call" {
  local calls="${WORK}/calls.log"
  STUB_CALLS="${calls}" STUB_RESPONSE_FILE="${FIX}/response-comment.txt" \
    run bash "${ENGINE}" --against origin/main --dry-run
  [ "$status" -eq 0 ]
  [ ! -f "${calls}" ]
  [[ "$output" == *"DRY-RUN"* ]]
}

@test "profile: defaults to cms-ars" {
  run bash "${ENGINE}" --against origin/main --dry-run
  [ "$status" -eq 0 ]
  [[ "$output" == *"Profile:"* ]]
  [[ "$output" == *"cms-ars"* ]]
}

@test "profile: baseline selected via AI_REVIEW_PROFILE" {
  AI_REVIEW_PROFILE=baseline run bash "${ENGINE}" --against origin/main --dry-run
  [ "$status" -eq 0 ]
  [[ "$output" == *"Profile:"*"baseline"* ]]
}

@test "profile: unknown name is a config error (exit 2)" {
  AI_REVIEW_PROFILE=nope run bash "${ENGINE}" --against origin/main --dry-run
  [ "$status" -eq 2 ]
  [[ "$output" == *"not a known profile"* ]]
}

@test "profile: bring-your-own directory path resolves" {
  local byo="${WORK}/myprofile"
  mkdir -p "${byo}"
  echo "# custom compliance rubric" > "${byo}/iac-compliance.md"
  AI_REVIEW_PROFILE="${byo}" run bash "${ENGINE}" --against origin/main --dry-run
  [ "$status" -eq 0 ]
  [[ "$output" == *"${byo}"* ]]
}

@test "--post-comments records a review payload via gh" {
  local posted="${WORK}/posted.ndjson"
  STUB_RESPONSE_FILE="${FIX}/response-comment.txt" STUB_GH_POSTED="${posted}" GITHUB_TOKEN=t \
    run bash "${ENGINE}" --against origin/main --pr 41 --post-comments
  [ "$status" -eq 0 ]
  [ -f "${posted}" ]
  python3 -c 'import json; p=json.load(open("'"${posted}"'")); assert p["event"]=="COMMENT"; assert len(p["comments"])==2'
}

@test "idempotent re-run posts nothing new when findings already anchored" {
  local comments="${WORK}/existing.ndjson" posted="${WORK}/posted.ndjson"
  # Both findings already carry a live AI comment on their current lines.
  {
    printf '{"path":"src/app.py","line":3,"body":"security(critical): x\\n_Reviewed by AI, was this helpful?_"}\n'
    printf '{"path":"infra/rds.tf","line":2,"body":"compliance(high): y\\n_Reviewed by AI, was this helpful?_"}\n'
  } > "${comments}"
  STUB_RESPONSE_FILE="${FIX}/response-comment.txt" STUB_GH_COMMENTS="${comments}" \
    STUB_GH_POSTED="${posted}" GITHUB_TOKEN=t \
    run bash "${ENGINE}" --against origin/main --pr 41 --post-comments
  [ "$status" -eq 0 ]
  [ ! -f "${posted}" ]   # nothing posted
  [[ "$output" == *"No new findings to post"* ]]
}

@test "422 on inline post falls back to summary-only" {
  local posted="${WORK}/posted.ndjson"
  # First reviews POST 422s; the engine retries body-only. The stub 422s every
  # POST, so we assert the fallback was attempted (two payloads recorded, the
  # second with no inline comments).
  STUB_RESPONSE_FILE="${FIX}/response-comment.txt" STUB_GH_POSTED="${posted}" \
    STUB_GH_POST_EXIT=1 GITHUB_TOKEN=t \
    run bash "${ENGINE}" --against origin/main --pr 41 --post-comments
  [ "$status" -eq 1 ]  # both attempts failed in the stub → error surfaced
  # The retry payload (last line) must have an empty comments array.
  tail -1 "${posted}" | python3 -c 'import json,sys; assert json.loads(sys.stdin.read())["comments"]==[]'
}

@test "AI CLI failure fails safe (exit 1)" {
  STUB_RESPONSE_FILE="${FIX}/response-comment.txt" STUB_EXIT=7 \
    run bash "${ENGINE}" --against origin/main
  [ "$status" -eq 1 ]
}

@test "AI CLI failure with --no-block exits 0" {
  STUB_RESPONSE_FILE="${FIX}/response-comment.txt" STUB_EXIT=7 \
    run bash "${ENGINE}" --against origin/main --no-block
  [ "$status" -eq 0 ]
}

@test "missing AI_REVIEW_TOOL is a config error (exit 2)" {
  AI_REVIEW_TOOL="" STUB_RESPONSE_FILE="${FIX}/response-comment.txt" \
    run bash "${ENGINE}" --against origin/main
  [ "$status" -eq 2 ]
}

@test "fan-out over a many-file diff invokes the CLI per batch and merges once" {
  for d in a b c d; do
    mkdir -p "mod_${d}"
    for i in 1 2 3; do echo "x = ${i}" > "mod_${d}/f${i}.py"; done
  done
  git add -A && git commit -qm many
  local calls="${WORK}/calls.log"
  STUB_RESPONSE_FILE="${FIX}/response-comment.txt" STUB_CALLS="${calls}" \
    run --separate-stderr bash "${ENGINE}" --against origin/main --jobs 4 --json-only
  [ "$status" -eq 0 ]
  # 4 directories → 4 batches → 4 CLI invocations.
  [ "$(wc -l < "${calls}")" -eq 4 ]
  # Merged output still parses and carries the deduped finding set.
  echo "$output" | python3 -c 'import json,sys; d=json.loads(sys.stdin.read()); assert d["review_action"]=="COMMENT"; assert "diff batch(es)" in d["summary"]'
}

@test "independent adjudication runs a second call and can clear findings" {
  local calls="${WORK}/calls.log"
  STUB_RESPONSE_FILE="${FIX}/response-comment.txt" \
    STUB_ADJ_RESPONSE_FILE="${FIX}/response-adjudicated-empty.txt" \
    AI_ADJUDICATION=independent STUB_CALLS="${calls}" \
    run --separate-stderr bash "${ENGINE}" --against origin/main --json-only
  [ "$status" -eq 0 ]
  [ "$(wc -l < "${calls}")" -eq 2 ]  # first pass + adjudication
  echo "$output" | python3 -c 'import json,sys; d=json.loads(sys.stdin.read()); assert d["review_action"]=="APPROVE"; assert d["comments"]==[]'
}

@test "post-only mode posts without any AI call" {
  local calls="${WORK}/calls.log" posted="${WORK}/posted.ndjson"
  cp "${FIX}/response-comment.txt" /dev/null 2>/dev/null || true
  # Produce a findings JSON, then post it in a separate --post-only run.
  local jf="${WORK}/findings.json"
  printf '%s\n' '{"review_action":"COMMENT","summary":"s","comments":[{"path":"src/app.py","line":3,"side":"RIGHT","perspective":"security","severity":"CRITICAL","title":"t","description":"d","suggestion_kind":"applicable","suggestion_body":"x"}]}' > "${jf}"
  STUB_CALLS="${calls}" STUB_GH_POSTED="${posted}" GITHUB_TOKEN=t \
    run bash "${ENGINE}" --post-only --pr 41 --json-in "${jf}"
  [ "$status" -eq 0 ]
  [ ! -f "${calls}" ]   # no AI invocation
  [ -f "${posted}" ]
}

@test "AI phase (--json-out, no --post-comments) never touches the SCM" {
  # This is the token-free phase the front ends run: it must not call gh at all.
  local jf="${WORK}/findings.json" posted="${WORK}/posted.ndjson"
  STUB_RESPONSE_FILE="${FIX}/response-comment.txt" STUB_GH_POSTED="${posted}" \
    run bash "${ENGINE}" --against origin/main --json-out "${jf}"
  [ "$status" -eq 0 ]
  [ -f "${jf}" ]        # findings written for the post phase to consume
  [ ! -f "${posted}" ] # gh was never invoked
}

@test "dry-run needs no LLM credentials" {
  # --dry-run must short-circuit before endpoint/credential validation.
  AI_REVIEW_TOOL=claude ANTHROPIC_API_KEY="" \
    run bash "${ENGINE}" --against origin/main --dry-run
  [ "$status" -eq 0 ]
}
