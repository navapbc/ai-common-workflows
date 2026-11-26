#!/usr/bin/env bats
# End-to-end tests for engines/security-compliance-review/harness/ai-security-compliance-review
# using stub CLIs and a throwaway
# git repo. No API keys, no network — the stubs return canned AI responses and
# record what `gh` was asked to post.

bats_require_minimum_version 1.5.0

load 'helpers'

setup() {
  REPO_ROOT="$(cd "${BATS_TEST_DIRNAME}/../.." && pwd)"
  ENGINE="${REPO_ROOT}/engines/security-compliance-review/harness/ai-security-compliance-review"
  STUBS="${REPO_ROOT}/tests/stubs"
  FIX="${REPO_ROOT}/tests/fixtures"
  export PATH="${STUBS}:${PATH}"
  export AI_REVIEW_TOOL=claude ANTHROPIC_API_KEY=test CI=true NO_COLOR=1
  # Host/CI config must never leak into engine test behavior.
  unset GITHUB_TOKEN GH_TOKEN AI_REVIEW_PROVIDER AI_REVIEW_MODEL || true
  sanitize_endpoint_env

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

write_review_response() {
  local target="$1" marker="$2" action="$3" comments="$4"
  cat >"${target}" <<EOF
<!-- AI_REVIEW_JSON_BEGIN -->
{"review_action":"${action}","summary":"test response","comments":${comments}}
<!-- AI_REVIEW_JSON_END -->
<<<AI_REVIEW_RESULT:${marker}>>>
EOF
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

@test "--help describes gate as HIGH/CRITICAL plus REQUEST_CHANGES blocking" {
  run bash "${ENGINE}" --help
  [ "$status" -eq 0 ]
  [[ "$output" == *"HIGH/CRITICAL"* ]]
  [[ "$output" == *"REQUEST_CHANGES"* ]]
  [[ "$output" == *"Posting still requires"* ]]
  [[ "$output" != *"still post but do not fail the build"* ]]
}

@test "single-call review rejects a marker that contradicts JSON" {
  local response="${WORK}/response.txt"
  write_review_response "${response}" APPROVE COMMENT '[{"path":"src/app.py","line":3,"perspective":"security","severity":"HIGH","title":"Secret"}]'
  STUB_RESPONSE_FILE="${response}" run bash "${ENGINE}" --against origin/main --json-only
  [ "$status" -eq 1 ]
  [[ "$output" == *"contract"* ]]
}

@test "single-call review rejects APPROVE with findings and COMMENT without findings" {
  local response="${WORK}/response.txt" marker action comments
  for marker in APPROVE COMMENT; do
    if [[ "${marker}" == APPROVE ]]; then
      action=APPROVE
      comments='[{"path":"src/app.py","line":3,"severity":"HIGH","title":"Secret"}]'
    else
      action=COMMENT
      comments='[]'
    fi
    write_review_response "${response}" "${marker}" "${action}" "${comments}"
    STUB_RESPONSE_FILE="${response}" run bash "${ENGINE}" --against origin/main --json-only
    [ "$status" -eq 1 ]
    [[ "$output" == *"contract"* ]]
  done
}

@test "single-call review rejects model-emitted REQUEST_CHANGES" {
  local response="${WORK}/response.txt"
  write_review_response "${response}" REQUEST_CHANGES REQUEST_CHANGES '[{"path":"src/app.py","line":3,"severity":"HIGH","title":"Secret"}]'
  STUB_RESPONSE_FILE="${response}" run bash "${ENGINE}" --against origin/main --json-only
  [ "$status" -eq 1 ]
  [[ "$output" == *"contract"* ]]
}

@test "single-call review rejects an invalid marker after a valid marker" {
  local response="${WORK}/response.txt"
  write_review_response "${response}" APPROVE APPROVE '[]'
  printf '%s\n' '<<<AI_REVIEW_RESULT:INVALID>>>' >>"${response}"
  STUB_RESPONSE_FILE="${response}" run bash "${ENGINE}" --against origin/main --json-only
  [ "$status" -eq 1 ]
  [[ "$output" == *"Could not parse review result marker"* ]]
}

@test "single-call review rejects an unterminated trailing marker" {
  local response="${WORK}/response.txt"
  write_review_response "${response}" APPROVE APPROVE '[]'
  printf '%s\n' '<<<AI_REVIEW_RESULT:COMMENT' >>"${response}"
  STUB_RESPONSE_FILE="${response}" run bash "${ENGINE}" --against origin/main --json-only
  [ "$status" -eq 1 ]
  [[ "$output" == *"Could not parse review result marker"* ]]
}

@test "single-call review rejects missing final marker after JSON" {
  local response="${WORK}/response.txt"
  cat >"${response}" <<'EOF'
<<<AI_REVIEW_RESULT:COMMENT>>>
<!-- AI_REVIEW_JSON_BEGIN -->
{"review_action":"COMMENT","summary":"s","comments":[{"path":"src/app.py","line":3,"side":"RIGHT","perspective":"security","severity":"HIGH","title":"Secret","description":"d","suggestion_kind":"reference","suggestion_language":"python","suggestion_body":"x"}]}
<!-- AI_REVIEW_JSON_END -->
EOF
  STUB_RESPONSE_FILE="${response}" run bash "${ENGINE}" --against origin/main --json-only
  [ "$status" -eq 1 ]
  [[ "$output" == *"parseable JSON block or violated the review contract"* ]]
}

@test "single-call review rejects marker after first JSON block only" {
  local response="${WORK}/response.txt"
  cat >"${response}" <<'EOF'
<!-- AI_REVIEW_JSON_BEGIN -->
{"review_action":"COMMENT","summary":"first","comments":[{"path":"src/app.py","line":3,"side":"RIGHT","perspective":"security","severity":"HIGH","title":"First","description":"d","suggestion_kind":"reference","suggestion_language":"python","suggestion_body":"x"}]}
<!-- AI_REVIEW_JSON_END -->
<<<AI_REVIEW_RESULT:COMMENT>>>
<!-- AI_REVIEW_JSON_BEGIN -->
{"review_action":"COMMENT","summary":"second","comments":[{"path":"src/app.py","line":4,"side":"RIGHT","perspective":"security","severity":"HIGH","title":"Second","description":"d","suggestion_kind":"reference","suggestion_language":"python","suggestion_body":"x"}]}
<!-- AI_REVIEW_JSON_END -->
EOF
  STUB_RESPONSE_FILE="${response}" run bash "${ENGINE}" --against origin/main --json-only
  [ "$status" -eq 1 ]
  [[ "$output" == *"parseable JSON block or violated the review contract"* ]]
}

@test "--dry-run makes no AI call" {
  local calls="${WORK}/calls.log"
  STUB_CALLS="${calls}" STUB_RESPONSE_FILE="${FIX}/response-comment.txt" \
    run bash "${ENGINE}" --against origin/main --dry-run
  [ "$status" -eq 0 ]
  [ ! -f "${calls}" ]
  [[ "$output" == *"DRY-RUN"* ]]
}

@test "review: changed paths with reserved delimiters fail closed" {
  printf 'print("x")\n' >"src/pipe|name.py"
  git add "src/pipe|name.py" && git commit -qm pipe
  run bash "${ENGINE}" --against origin/main --dry-run
  [ "$status" -eq 1 ]
  [[ "$output" == *"Unsupported changed path contains a reserved delimiter character"* ]]
}

@test "review: reserved-delimiter paths fail closed on real runs too" {
  local calls="${WORK}/calls.log"
  printf 'print("x")\n' >"src/pipe|name.py"
  git add "src/pipe|name.py" && git commit -qm pipe
  STUB_CALLS="${calls}" run bash "${ENGINE}" --against origin/main --json-only
  [ "$status" -eq 1 ]
  [[ "$output" == *"Unsupported changed path contains a reserved delimiter character"* ]]
  [ ! -f "${calls}" ]
}

@test "profile: defaults to base" {
  run bash "${ENGINE}" --against origin/main --dry-run
  [ "$status" -eq 0 ]
  [[ "$output" == *"Profile:"* ]]
  [[ "$output" == *"base"* ]]
}

@test "profile: base,cms-ars-5.1 selected via AI_REVIEW_PROFILE" {
  AI_REVIEW_PROFILE=base,cms-ars-5.1 run bash "${ENGINE}" --against origin/main --dry-run
  [ "$status" -eq 0 ]
  [[ "$output" == *"Profile:"*"cms-ars-5.1"* ]]
}

@test "profile: a bare profile name without base is refused" {
  # Dropping the floor has to be deliberate: the review would otherwise run,
  # report a verdict, and have checked almost nothing.
  AI_REVIEW_PROFILE=cms-ars-5.1 run bash "${ENGINE}" --against origin/main --dry-run
  [ "$status" -eq 2 ]
  [[ "$output" == *"must start with 'base' or 'none'"* ]]
}

@test "profile: the compliance floor applies under base; cms-ars-5.1 only adds to it" {
  local log_baseline="${WORK}/prompt-baseline.log"
  STUB_PROMPT_LOG="${log_baseline}" STUB_RESPONSE_FILE="${FIX}/response-comment.txt" \
    run bash "${ENGINE}" --against origin/main --json-only
  [ "$status" -eq 0 ]
  grep -q -- "COMPLIANCE PERSPECTIVE ────" "${log_baseline}"
  ! grep -q -- "ADDITIONS" "${log_baseline}"

  local log_cms="${WORK}/prompt-cms.log"
  AI_REVIEW_PROFILE=base,cms-ars-5.1 STUB_PROMPT_LOG="${log_cms}" STUB_RESPONSE_FILE="${FIX}/response-comment.txt" \
    run bash "${ENGINE}" --against origin/main --json-only
  [ "$status" -eq 0 ]
  grep -q -- "COMPLIANCE PERSPECTIVE ────" "${log_cms}"
  grep -q -- "COMPLIANCE PERSPECTIVE — cms-ars-5.1 ADDITIONS" "${log_cms}"
}

@test "profile: --profile flag sets the rubric sources" {
  run bash "${ENGINE}" --profile base,cms-ars-5.1 --against origin/main --dry-run
  [ "$status" -eq 0 ]
  [[ "$output" == *"Profile:"*"base,cms-ars-5.1"* ]]
}

@test "profile: --profile=<list> form works too" {
  run bash "${ENGINE}" --profile=base,cms-ars-5.1 --against origin/main --dry-run
  [ "$status" -eq 0 ]
  [[ "$output" == *"Profile:"*"base,cms-ars-5.1"* ]]
}

@test "profile: --profile overrides AI_REVIEW_PROFILE" {
  AI_REVIEW_PROFILE=base run bash "${ENGINE}" --profile base,cms-ars-5.1 \
    --against origin/main --dry-run
  [ "$status" -eq 0 ]
  [[ "$output" == *"cms-ars-5.1"* ]]
}

@test "profile: --profile with no value does not swallow the next flag" {
  # `--profile --against main` must not resolve a profile named "--against".
  run bash "${ENGINE}" --profile --against origin/main --dry-run
  [ "$status" -eq 2 ]
  [[ "$output" == *"--profile requires a value"* ]]
}

@test "profile: --profile rejects a bare name without base" {
  run bash "${ENGINE}" --profile cms-ars-5.1 --against origin/main --dry-run
  [ "$status" -eq 2 ]
  [[ "$output" == *"must start with 'base' or 'none'"* ]]
}

@test "profile: unknown name is a config error (exit 2)" {
  AI_REVIEW_PROFILE=base,nope run bash "${ENGINE}" --against origin/main --dry-run
  [ "$status" -eq 2 ]
  [[ "$output" == *"not a known profile"* ]]
}

@test "codex+bedrock passes the amazon-bedrock provider override to the CLI" {
  local args="${WORK}/codex-args.log"
  AI_REVIEW_TOOL=codex AI_REVIEW_PROVIDER=bedrock AWS_REGION=us-east-1 \
    AWS_ACCESS_KEY_ID=AKIAsecret AI_REVIEW_MODEL=us.anthropic.claude-x \
    STUB_ARGS_LOG="${args}" STUB_RESPONSE_FILE="${FIX}/response-comment.txt" \
    run bash "${ENGINE}" --against origin/main --json-only
  [ "$status" -eq 0 ]
  grep -q -- "-c model_provider=amazon-bedrock" "${args}"
  grep -q -- "model_providers.amazon-bedrock.aws.region=us-east-1" "${args}"
}

@test "profile: bring-your-own directory path resolves" {
  local byo="${WORK}/myprofile"
  mkdir -p "${byo}"
  echo "# custom compliance rubric" > "${byo}/iac-compliance.md"
  AI_REVIEW_PROFILE="base,${byo}" run bash "${ENGINE}" --against origin/main --dry-run
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

@test "fan-out review rejects a batch with a contradictory marker and JSON" {
  local response="${WORK}/response.txt"
  write_review_response "${response}" APPROVE COMMENT '[{"path":"src/app.py","line":3,"severity":"HIGH","title":"Secret"}]'
  AI_REVIEW_BATCH_MIN_FILES=1 STUB_RESPONSE_FILE="${response}" \
    run bash "${ENGINE}" --against origin/main --jobs 2 --json-only
  [ "$status" -eq 1 ]
  [[ "$output" == *"Fan-out did not review every batch"* ]]
}

@test "fan-out review rejects a batch with an invalid trailing marker" {
  local response="${WORK}/response.txt"
  write_review_response "${response}" APPROVE APPROVE '[]'
  printf '%s\n' '<<<AI_REVIEW_RESULT:AUDIT_CLEAN>>>' >>"${response}"
  AI_REVIEW_BATCH_MIN_FILES=1 STUB_RESPONSE_FILE="${response}" \
    run bash "${ENGINE}" --against origin/main --jobs 2 --json-only
  [ "$status" -eq 1 ]
  [[ "$output" == *"Fan-out did not review every batch"* ]]
}

@test "fan-out review rejects a batch with an unterminated trailing marker" {
  local response="${WORK}/response.txt"
  write_review_response "${response}" APPROVE APPROVE '[]'
  printf '%s\n' '<<<AI_REVIEW_RESULT:COMMENT' >>"${response}"
  AI_REVIEW_BATCH_MIN_FILES=1 STUB_RESPONSE_FILE="${response}" \
    run bash "${ENGINE}" --against origin/main --jobs 2 --json-only
  [ "$status" -eq 1 ]
  [[ "$output" == *"Fan-out did not review every batch"* ]]
}

@test "fan-out review rejects a batch with no final marker after JSON" {
  local response="${WORK}/response.txt"
  cat >"${response}" <<'EOF'
<<<AI_REVIEW_RESULT:COMMENT>>>
<!-- AI_REVIEW_JSON_BEGIN -->
{"review_action":"COMMENT","summary":"s","comments":[{"path":"src/app.py","line":3,"side":"RIGHT","perspective":"security","severity":"HIGH","title":"Secret","description":"d","suggestion_kind":"reference","suggestion_language":"python","suggestion_body":"x"}]}
<!-- AI_REVIEW_JSON_END -->
EOF
  AI_REVIEW_BATCH_MIN_FILES=1 STUB_RESPONSE_FILE="${response}" \
    run bash "${ENGINE}" --against origin/main --jobs 2 --json-only
  [ "$status" -eq 1 ]
  [[ "$output" == *"Fan-out did not review every batch"* ]]
}

@test "fan-out review rejects marker after first JSON block only" {
  local response="${WORK}/response.txt"
  cat >"${response}" <<'EOF'
<!-- AI_REVIEW_JSON_BEGIN -->
{"review_action":"COMMENT","summary":"first","comments":[{"path":"src/app.py","line":3,"side":"RIGHT","perspective":"security","severity":"HIGH","title":"First","description":"d","suggestion_kind":"reference","suggestion_language":"python","suggestion_body":"x"}]}
<!-- AI_REVIEW_JSON_END -->
<<<AI_REVIEW_RESULT:COMMENT>>>
<!-- AI_REVIEW_JSON_BEGIN -->
{"review_action":"COMMENT","summary":"second","comments":[{"path":"src/app.py","line":4,"side":"RIGHT","perspective":"security","severity":"HIGH","title":"Second","description":"d","suggestion_kind":"reference","suggestion_language":"python","suggestion_body":"x"}]}
<!-- AI_REVIEW_JSON_END -->
EOF
  AI_REVIEW_BATCH_MIN_FILES=1 STUB_RESPONSE_FILE="${response}" \
    run bash "${ENGINE}" --against origin/main --jobs 2 --json-only
  [ "$status" -eq 1 ]
  [[ "$output" == *"Fan-out did not review every batch"* ]]
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

@test "independent review adjudication cannot introduce a new finding" {
  local adj="${WORK}/adjudicated.txt"
  write_review_response "${adj}" COMMENT COMMENT '[{"path":"src/app.py","line":3,"side":"RIGHT","perspective":"security","severity":"LOW","title":"A new finding"}]'
  STUB_RESPONSE_FILE="${FIX}/response-comment.txt" STUB_ADJ_RESPONSE_FILE="${adj}" \
    AI_ADJUDICATION=independent run --separate-stderr bash "${ENGINE}" --against origin/main --json-only
  [ "$status" -eq 0 ]
  [[ "$stderr" == *"keeping the first-pass result"* ]]
  echo "$output" | python3 -c 'import json,sys; d=json.loads(sys.stdin.read()); assert len(d["comments"])==2 and d["comments"][0]["title"]=="Hardcoded AWS access key"'
}

@test "independent review adjudication cannot raise a finding's severity" {
  local adj="${WORK}/adjudicated.txt"
  write_review_response "${adj}" COMMENT COMMENT '[{"path":"infra/rds.tf","line":2,"side":"RIGHT","perspective":"compliance","severity":"CRITICAL","title":"RDS instance without encryption at rest"}]'
  STUB_RESPONSE_FILE="${FIX}/response-comment.txt" STUB_ADJ_RESPONSE_FILE="${adj}" \
    AI_ADJUDICATION=independent run --separate-stderr bash "${ENGINE}" --against origin/main --json-only
  [ "$status" -eq 0 ]
  [[ "$stderr" == *"keeping the first-pass result"* ]]
  echo "$output" | python3 -c 'import json,sys; d=json.loads(sys.stdin.read()); assert len(d["comments"])==2 and d["comments"][1]["severity"]=="HIGH"'
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


# ── PR diff semantics: BASE...HEAD, not BASE..HEAD ──────────────────────────
# The review must cover what THIS branch changed. A two-dot diff also reports,
# inverted, every commit landed on the base since the branch forked — which
# attributes other people's work to this PR, inflates batching, and can fail
# --gate on somebody else's commit.

@test "diff excludes commits made on the base after the branch diverged" {
  # main moves forward with an unrelated change after `feature` forked.
  git checkout -q main
  printf 'shared\nSOMEONE_ELSES_LINE\n' >other.py
  git add -A && git commit -qm "unrelated main commit"
  git update-ref refs/remotes/origin/main main
  git checkout -q feature

  run bash "${ENGINE}" --against origin/main --dry-run
  [ "$status" -eq 0 ]
  # The PR's own files are reviewed...
  [[ "$output" == *"src/app.py"* ]]
  # ...and the file only main touched is NOT attributed to this PR.
  [[ "$output" != *"other.py"* ]]
}

@test "diff source line reports the resolved merge base" {
  run bash "${ENGINE}" --against origin/main --dry-run
  [ "$status" -eq 0 ]
  [[ "$output" == *"merge-base"* ]]
  [[ "$output" == *"origin/main...HEAD"* ]]
}

@test "AI_REVIEW_AGAINST handed to the model is the merge base" {
  # The skills tell the model to run `git diff "$AI_REVIEW_AGAINST" HEAD`, so
  # the exported value must already be the merge base for that to be correct.
  local expected
  expected="$(git merge-base origin/main HEAD)"
  STUB_ENV_LOG="${WORK}/env.log" STUB_RESPONSE_FILE="${FIX}/response-comment.txt" \
    run bash "${ENGINE}" --against origin/main --json-only
  [ "$status" -eq 0 ]
  grep -qx "AI_REVIEW_AGAINST=${expected}" "${WORK}/env.log"
}

@test "no merge base (shallow) warns and still reviews" {
  # A ref with no common ancestor: an orphan commit stands in for a shallow
  # clone whose branch point was never fetched.
  git checkout -q --orphan unrelated-root
  git rm -rq --cached . 2>/dev/null || true
  rm -f src/app.py infra/rds.tf 2>/dev/null || true
  echo x >lonely.txt && git add lonely.txt && git commit -qm orphan
  git update-ref refs/remotes/origin/orphan unrelated-root
  git checkout -q feature

  run bash "${ENGINE}" --against origin/orphan --dry-run
  [ "$status" -eq 0 ]
  [[ "$output" == *"No merge base found"* ]]
  [[ "$output" == *"fetch-depth: 0"* ]]
}
