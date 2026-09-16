#!/usr/bin/env bats
# Tests for engines/security-compliance-review/harness/ai-security-compliance-audit
#
# The audit's risk is not the AI call — it is scope selection. A scope that
# silently drops files produces a clean-looking audit of code nobody examined,
# so most of these assert on what lands in scope and what is skipped, with the
# AI stubbed out entirely.

load 'helpers'

AUDIT="${REPO_ROOT}/engines/security-compliance-review/harness/ai-security-compliance-audit"

setup() {
  common_setup
  unset CI # the audit warns under CI; most tests want the quiet path
  AUDIT_REPO="${BATS_TEST_TMPDIR}/audit-repo"
  mkdir -p "${AUDIT_REPO}/src" "${AUDIT_REPO}/terraform" "${AUDIT_REPO}/vendor"
  cd "${AUDIT_REPO}"
  git init -q .
  git config user.email t@example.com
  git config user.name t
  echo 'api_key = "AKIAIOSFODNN7EXAMPLE"' >src/app.py
  echo 'resource "aws_db_instance" "x" {}' >terraform/rds.tf
  echo 'helper' >src/util.py
  echo 'third party' >vendor/lib.py
  git add -A
  git commit -qm init
  export STUB_RESPONSE_FILE="${BATS_TEST_TMPDIR}/resp.txt"
  cat >"${STUB_RESPONSE_FILE}" <<'EOF'
## Codebase Audit Report

<!-- AI_REVIEW_JSON_BEGIN -->
{"review_action":"COMMENT","summary":"s","comments":[{"path":"src/app.py","line":1,"side":"RIGHT","perspective":"security","severity":"CRITICAL","title":"Hardcoded key","description":"d","suggestion_kind":"reference","suggestion_language":"python","suggestion_body":"x"}]}
<!-- AI_REVIEW_JSON_END -->

<<<AI_REVIEW_RESULT:AUDIT_FINDINGS>>>
EOF
}

# ── scope selection ─────────────────────────────────────────────────────────

@test "audit: no paths audits every tracked file" {
  run bash "${AUDIT}" --list-files
  [ "$status" -eq 0 ]
  [[ "$output" == *"src/app.py"* ]]
  [[ "$output" == *"terraform/rds.tf"* ]]
  [[ "$output" == *"vendor/lib.py"* ]]
}

@test "audit: a directory path narrows the scope" {
  run bash "${AUDIT}" --list-files terraform/
  [ "$status" -eq 0 ]
  [[ "$output" == *"terraform/rds.tf"* ]]
  [[ "$output" != *"src/app.py"* ]]
}

@test "audit: multiple paths are unioned" {
  run bash "${AUDIT}" --list-files terraform/ src/
  [ "$status" -eq 0 ]
  [[ "$output" == *"terraform/rds.tf"* ]]
  [[ "$output" == *"src/app.py"* ]]
  [[ "$output" != *"vendor/lib.py"* ]]
}

@test "audit: a single file path works" {
  run bash "${AUDIT}" --list-files src/app.py
  [ "$status" -eq 0 ]
  [[ "$output" == *"src/app.py"* ]]
  [[ "$output" != *"src/util.py"* ]]
}

@test "audit: --exclude drops matching paths" {
  run bash "${AUDIT}" --list-files --exclude 'vendor/*'
  [ "$status" -eq 0 ]
  [[ "$output" != *"vendor/lib.py"* ]]
  [[ "$output" == *"src/app.py"* ]]
}

@test "audit: --include keeps only matching paths" {
  run bash "${AUDIT}" --list-files --include '*.tf'
  [ "$status" -eq 0 ]
  [[ "$output" == *"terraform/rds.tf"* ]]
  [[ "$output" != *"src/app.py"* ]]
}

@test "audit: untracked files are not audited" {
  echo 'secret = "x"' >src/untracked.py
  run bash "${AUDIT}" --list-files
  [ "$status" -eq 0 ]
  [[ "$output" != *"untracked.py"* ]]
}

@test "audit: gitignored files are not audited" {
  echo 'ignored/' >.gitignore
  mkdir -p ignored
  echo 'x' >ignored/thing.py
  git add .gitignore && git commit -qm ignore
  run bash "${AUDIT}" --list-files
  [ "$status" -eq 0 ]
  [[ "$output" != *"ignored/thing.py"* ]]
}

@test "audit: a binary file is skipped, and says so" {
  printf 'head\x00\x01tail' >src/blob.bin
  git add -A && git commit -qm blob
  run bash "${AUDIT}" --list-files
  [ "$status" -eq 0 ]
  [[ "$output" != *"src/blob.bin"$'\n'* ]] || false
  [[ "$output" == *"SKIP"*"src/blob.bin"*"binary"* ]]
}

@test "audit: a text file is NOT mistaken for binary" {
  run bash "${AUDIT}" --list-files
  [ "$status" -eq 0 ]
  [[ "$output" != *"src/app.py	binary"* ]]
  [[ "$output" == *"src/app.py"* ]]
}

@test "audit: --max-file-bytes skips oversized files, and says so" {
  head -c 2000 /dev/zero | tr '\0' 'a' >src/big.py
  git add -A && git commit -qm big
  run bash "${AUDIT}" --list-files --max-file-bytes 500
  [ "$status" -eq 0 ]
  [[ "$output" == *"SKIP"*"src/big.py"*"larger than 500"* ]]
}

@test "audit: an empty scope is a config error, not a clean audit" {
  run bash "${AUDIT}" nonexistent/
  [ "$status" -eq 2 ]
  [[ "$output" == *"No files in scope"* ]]
}

@test "audit: outside a git repo is a config error" {
  cd "${BATS_TEST_TMPDIR}"
  mkdir -p notarepo && cd notarepo
  run bash "${AUDIT}" --list-files
  [ "$status" -eq 2 ]
  [[ "$output" == *"Not a git repository"* ]]
}

# ── profile ─────────────────────────────────────────────────────────────────

@test "audit: --profile selects a bundled profile after base" {
  run bash "${AUDIT}" --profile base,cms-ars --dry-run
  [ "$status" -eq 0 ]
  [[ "$output" == *"Profile:"*"cms-ars"* ]]
}

@test "audit: default profile is base" {
  run bash "${AUDIT}" --dry-run
  [ "$status" -eq 0 ]
  [[ "$output" == *"Profile:"*"base"* ]]
}

@test "audit: a bare profile name without base is refused" {
  run bash "${AUDIT}" --profile cms-ars --dry-run
  [ "$status" -eq 2 ]
  [[ "$output" == *"must start with 'base' or 'none'"* ]]
}

@test "audit: --profile with no value does not swallow the next flag" {
  run bash "${AUDIT}" --profile --dry-run
  [ "$status" -eq 2 ]
  [[ "$output" == *"--profile requires a value"* ]]
}

@test "audit: --json-out with no value does not swallow the next flag" {
  run bash "${AUDIT}" --json-out --dry-run
  [ "$status" -eq 2 ]
  [[ "$output" == *"--json-out requires a path"* ]]
}

@test "audit: an unknown profile is a config error listing the bundled ones" {
  run bash "${AUDIT}" --profile base,nope --dry-run
  [ "$status" -eq 2 ]
  [[ "$output" == *"not a known profile"* ]]
  [[ "$output" == *"cms-ars"* ]]
}

@test "audit: --profile accepts a custom directory path after base" {
  mkdir -p "${BATS_TEST_TMPDIR}/myprofile"
  run bash "${AUDIT}" --profile "base,${BATS_TEST_TMPDIR}/myprofile" --dry-run
  [ "$status" -eq 0 ]
}

@test "audit: none without a profile supplying codebase-audit.md is refused" {
  mkdir -p "${BATS_TEST_TMPDIR}/empty"
  run bash "${AUDIT}" --profile "none,${BATS_TEST_TMPDIR}/empty" --dry-run
  [ "$status" -eq 2 ]
  [[ "$output" == *"No rubric source supplies codebase-audit.md"* ]]
}

# ── no AI call on the planning paths ────────────────────────────────────────

@test "audit: --list-files makes no AI call" {
  run bash "${AUDIT}" --list-files
  [ "$status" -eq 0 ]
  [ ! -s "${STUB_CALLS}" ]
}

@test "audit: --dry-run makes no AI call and reports the expected call count" {
  run bash "${AUDIT}" --dry-run
  [ "$status" -eq 0 ]
  [[ "$output" == *"Expected calls:"* ]]
  [ ! -s "${STUB_CALLS}" ]
}

@test "audit: --list-batches makes no AI call" {
  run bash "${AUDIT}" --list-batches
  [ "$status" -eq 0 ]
  [[ "$output" == *"Batch plan"* ]]
  [ ! -s "${STUB_CALLS}" ]
}

# ── the flags the audit deliberately refuses ────────────────────────────────

@test "audit: --gate is refused with a pointer to the review" {
  run bash "${AUDIT}" --gate
  [ "$status" -eq 2 ]
  [[ "$output" == *"ai-security-compliance-review"* ]]
}

@test "audit: --post-comments is refused" {
  run bash "${AUDIT}" --post-comments
  [ "$status" -eq 2 ]
}

@test "audit: --against is refused (the audit reads the working tree)" {
  run bash "${AUDIT}" --against main
  [ "$status" -eq 2 ]
}

@test "audit: an unknown flag is a config error" {
  run bash "${AUDIT}" --nope
  [ "$status" -eq 2 ]
  [[ "$output" == *"Unknown flag"* ]]
}

# ── a full stubbed run ──────────────────────────────────────────────────────

@test "audit: completes and reports the finding count" {
  run bash "${AUDIT}"
  [ "$status" -eq 0 ]
  [[ "$output" == *"Audit complete: 1 finding(s)"* ]]
}

@test "audit: --json-out writes the findings JSON outside the audited repo" {
  local out="${BATS_TEST_TMPDIR}/findings.json"
  run bash "${AUDIT}" --json-out "${out}"
  [ "$status" -eq 0 ]
  [ -s "${out}" ]
  grep -q '"review_action"' "${out}"
}

@test "audit: --json-only prints only the JSON" {
  run bash "${AUDIT}" --json-only
  [ "$status" -eq 0 ]
  [[ "$output" == *'"review_action"'* ]]
  [[ "$output" != *"Codebase Audit Report"* ]]
}

@test "audit: writes nothing into the audited repo" {
  local before after
  before="$(git status --porcelain; git ls-files)"
  run bash "${AUDIT}"
  [ "$status" -eq 0 ]
  after="$(git status --porcelain; git ls-files)"
  [ "${before}" = "${after}" ]
}

@test "audit: a missing result marker fails rather than reporting clean" {
  cat >"${STUB_RESPONSE_FILE}" <<'EOF'
## Codebase Audit Report
no marker here
EOF
  run bash "${AUDIT}"
  [ "$status" -eq 1 ]
}

@test "audit: findings but no JSON block fails rather than reporting clean" {
  cat >"${STUB_RESPONSE_FILE}" <<'EOF'
## Codebase Audit Report
<<<AI_REVIEW_RESULT:AUDIT_FINDINGS>>>
EOF
  run bash "${AUDIT}"
  [ "$status" -eq 1 ]
}

@test "audit: an AI CLI failure is a runtime error" {
  STUB_EXIT=9 run bash "${AUDIT}"
  [ "$status" -eq 1 ]
}

@test "audit: warns when CI is set" {
  CI=true run bash "${AUDIT}" --list-files
  [ "$status" -eq 0 ]
  [[ "$output" == *"ad-hoc local tool"* ]]
}

@test "audit: the prompt carries the audit rubric and the scope, not a diff" {
  export STUB_PROMPT_LOG="${BATS_TEST_TMPDIR}/prompt.log"
  run bash "${AUDIT}" terraform/
  [ "$status" -eq 0 ]
  grep -q "CODEBASE-AUDIT INSTRUCTIONS" "${STUB_PROMPT_LOG}"
  grep -q "AUDIT SCOPE" "${STUB_PROMPT_LOG}"
  grep -q "terraform/rds.tf" "${STUB_PROMPT_LOG}"
}

@test "audit: the compliance perspective is included when IaC is in scope" {
  export STUB_PROMPT_LOG="${BATS_TEST_TMPDIR}/prompt.log"
  run bash "${AUDIT}" terraform/
  [ "$status" -eq 0 ]
  grep -q "COMPLIANCE PERSPECTIVE" "${STUB_PROMPT_LOG}"
}

@test "audit: the compliance perspective is omitted when no IaC is in scope" {
  export STUB_PROMPT_LOG="${BATS_TEST_TMPDIR}/prompt.log"
  run bash "${AUDIT}" src/
  [ "$status" -eq 0 ]
  ! grep -q "COMPLIANCE PERSPECTIVE" "${STUB_PROMPT_LOG}"
}
