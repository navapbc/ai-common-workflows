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
  # Every real run now needs somewhere to write its bundle.
  OUT_PARENT="${BATS_TEST_TMPDIR}/audits"
  mkdir -p "${OUT_PARENT}"
  # bats is not a TTY, and the audit refuses to spend without confirmation
  # there. Set once here rather than on every invocation; the refusal itself is
  # tested explicitly below.
  export AI_AUDIT_ASSUME_YES=1
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

# ── resume ──────────────────────────────────────────────────────────────────
# Picking a long audit back up. The failure that matters is a resumed run
# DELETING the segment it was meant to preserve, so most of these assert that
# prior results survive.

_seg() { # $1 = path, $2 = severity, $3 = title
  cat >"${STUB_RESPONSE_FILE}" <<EOF
<!-- AI_REVIEW_JSON_BEGIN -->
{"review_action":"COMMENT","summary":"s","comments":[{"path":"$1","line":1,"side":"RIGHT","perspective":"security","severity":"$2","title":"$3","description":"d","suggestion_kind":"reference","suggestion_language":"python","suggestion_body":"x"}]}
<!-- AI_REVIEW_JSON_END -->
<<<AI_REVIEW_RESULT:AUDIT_FINDINGS>>>
EOF
}

_bundle() { find "${OUT_PARENT}" -maxdepth 1 -mindepth 1 -type d | head -1; }

@test "audit: --resume reuses the existing bundle instead of creating one" {
  _seg "src/app.py" CRITICAL "first"
  bash "${AUDIT}" --output-parent-dir "${OUT_PARENT}" src/ >/dev/null 2>&1
  _seg "terraform/rds.tf" HIGH "second"
  run bash "${AUDIT}" --output-parent-dir "${OUT_PARENT}" --resume
  [ "$status" -eq 0 ]
  [[ "$output" == *"Resuming"* ]]
  [ "$(find "${OUT_PARENT}" -maxdepth 1 -mindepth 1 -type d | wc -l | tr -d ' ')" -eq 1 ]
}

@test "audit: --resume skips directories that already have a report" {
  _seg "src/app.py" CRITICAL "first"
  bash "${AUDIT}" --output-parent-dir "${OUT_PARENT}" src/ >/dev/null 2>&1
  _seg "terraform/rds.tf" HIGH "second"
  run bash "${AUDIT}" --output-parent-dir "${OUT_PARENT}" --resume
  [[ "$output" == *"already covered by an existing report"* ]]
}

@test "audit: --resume does not delete the earlier segment's findings" {
  _seg "src/app.py" CRITICAL "first"
  bash "${AUDIT}" --output-parent-dir "${OUT_PARENT}" src/ >/dev/null 2>&1
  _seg "terraform/rds.tf" HIGH "second"
  bash "${AUDIT}" --output-parent-dir "${OUT_PARENT}" --resume >/dev/null 2>&1
  local dir; dir="$(_bundle)"
  grep -q "first" "${dir}/findings.json"
  grep -q "second" "${dir}/findings.json"
  # the earlier directory doc must still carry its finding
  grep -q '^#### ' "${dir}/src.md"
}

@test "audit: --resume regenerates the index covering both segments" {
  _seg "src/app.py" CRITICAL "first"
  bash "${AUDIT}" --output-parent-dir "${OUT_PARENT}" src/ >/dev/null 2>&1
  _seg "terraform/rds.tf" HIGH "second"
  bash "${AUDIT}" --output-parent-dir "${OUT_PARENT}" --resume >/dev/null 2>&1
  local dir; dir="$(_bundle)"
  grep -q 'src.md#findings' "${dir}/_INDEX.md"
  grep -q 'terraform.md#findings' "${dir}/_INDEX.md"
}

@test "audit: a clean resumed segment does not downgrade the bundle to APPROVE" {
  _seg "src/app.py" CRITICAL "first"
  bash "${AUDIT}" --output-parent-dir "${OUT_PARENT}" src/ >/dev/null 2>&1
  cat >"${STUB_RESPONSE_FILE}" <<'EOF'
<!-- AI_REVIEW_JSON_BEGIN -->
{"review_action":"APPROVE","summary":"clean","comments":[]}
<!-- AI_REVIEW_JSON_END -->
<<<AI_REVIEW_RESULT:AUDIT_CLEAN>>>
EOF
  bash "${AUDIT}" --output-parent-dir "${OUT_PARENT}" --resume >/dev/null 2>&1
  local dir; dir="$(_bundle)"
  grep -q '"review_action": *"COMMENT"' "${dir}/findings.json"
}

@test "audit: --resume appends the new narrative rather than replacing it" {
  _seg "src/app.py" CRITICAL "first"
  bash "${AUDIT}" --output-parent-dir "${OUT_PARENT}" src/ >/dev/null 2>&1
  _seg "terraform/rds.tf" HIGH "second"
  bash "${AUDIT}" --output-parent-dir "${OUT_PARENT}" --resume >/dev/null 2>&1
  grep -q 'Resumed segment' "$(_bundle)/report.md"
}

@test "audit: --resume with nothing left says so and exits 0" {
  _seg "src/app.py" CRITICAL "first"
  bash "${AUDIT}" --output-parent-dir "${OUT_PARENT}" >/dev/null 2>&1
  run bash "${AUDIT}" --output-parent-dir "${OUT_PARENT}" --resume
  [ "$status" -eq 0 ]
  [[ "$output" == *"already complete"* ]]
}

@test "audit: --resume with no existing bundle starts a new one and says so" {
  run bash "${AUDIT}" --output-parent-dir "${OUT_PARENT}" --resume
  [ "$status" -eq 0 ]
  [[ "$output" == *"no existing bundle"* ]]
  [ "$(find "${OUT_PARENT}" -maxdepth 1 -mindepth 1 -type d | wc -l | tr -d ' ')" -eq 1 ]
}

@test "audit: --resume without an output parent is a config error" {
  run bash "${AUDIT}" --resume --json-only
  [ "$status" -eq 2 ]
  [[ "$output" == *"needs --output-parent-dir"* ]]
}

# ── --doctor ────────────────────────────────────────────────────────────────
# One answer instead of four "it did not work" moments. Reports every problem
# in one pass, because a fresh laptop usually has two or three at once.

@test "audit: --doctor reports ready when everything is configured" {
  run bash "${AUDIT}" --doctor --output-parent-dir "${OUT_PARENT}"
  [ "$status" -eq 0 ]
  [[ "$output" == *"Ready to audit"* ]]
  [[ "$output" == *"bash"* ]]
  [[ "$output" == *"python3"* ]]
}

@test "audit: --doctor needs no output directory" {
  run bash "${AUDIT}" --doctor
  [ "$status" -eq 0 ]
  [[ "$output" == *"--output-parent-dir is required for a real run"* ]]
}

@test "audit: --doctor makes no AI call" {
  run bash "${AUDIT}" --doctor --output-parent-dir "${OUT_PARENT}"
  [ "$status" -eq 0 ]
  [ ! -s "${STUB_CALLS}" ]
}

@test "audit: --doctor works outside a git repository" {
  # You should be able to check your setup before cd-ing into a repo.
  cd "${BATS_TEST_TMPDIR}"
  mkdir -p elsewhere && cd elsewhere
  run bash "${AUDIT}" --doctor
  [ "$status" -eq 0 ]
  [[ "$output" == *"not inside a git repository"* ]]
}

@test "audit: --doctor fails and names a missing AI_REVIEW_TOOL" {
  unset AI_REVIEW_TOOL
  run bash "${AUDIT}" --doctor
  [ "$status" -eq 1 ]
  [[ "$output" == *"AI_REVIEW_TOOL"*"MISSING"* ]]
  [[ "$output" == *"export AI_REVIEW_TOOL=claude"* ]]
}

@test "audit: --doctor reports a CLI that is not on PATH" {
  PATH="/usr/bin:/bin" run bash "${AUDIT}" --doctor
  [ "$status" -eq 1 ]
  [[ "$output" == *"claude CLI"*"MISSING"* ]]
}

@test "audit: --doctor surfaces the endpoint error verbatim" {
  unset ANTHROPIC_API_KEY
  run bash "${AUDIT}" --doctor
  [ "$status" -eq 1 ]
  [[ "$output" == *"endpoint"*"FAILED"* ]]
  [[ "$output" == *"requires ANTHROPIC_API_KEY"* ]]
}

@test "audit: --doctor surfaces a bad provider" {
  AI_REVIEW_PROVIDER=nonsense run bash "${AUDIT}" --doctor
  [ "$status" -eq 1 ]
  [[ "$output" == *"not a recognized value"* ]]
}

@test "audit: --doctor surfaces a bad profile" {
  AI_REVIEW_PROFILE=cms-ars run bash "${AUDIT}" --doctor
  [ "$status" -eq 1 ]
  [[ "$output" == *"profile"*"FAILED"* ]]
  [[ "$output" == *"must start with 'base' or 'none'"* ]]
}

@test "audit: --doctor flags a public endpoint without failing" {
  # A public endpoint is a choice, not a defect.
  run bash "${AUDIT}" --doctor --output-parent-dir "${OUT_PARENT}"
  [ "$status" -eq 0 ]
  [[ "$output" == *"PUBLIC"* ]]
}

@test "audit: --doctor does not flag an in-boundary endpoint as public" {
  AI_REVIEW_PROVIDER=bedrock AWS_REGION=us-east-1 AI_REVIEW_MODEL=m \
    run bash "${AUDIT}" --doctor --output-parent-dir "${OUT_PARENT}"
  [ "$status" -eq 0 ]
  [[ "$output" == *"bedrock — in your boundary"* ]]
}

@test "audit: --doctor fails on an output directory that does not exist" {
  run bash "${AUDIT}" --doctor --output-parent-dir "${BATS_TEST_TMPDIR}/nope"
  [ "$status" -eq 1 ]
  [[ "$output" == *"does not exist"* ]]
}

@test "audit: --doctor reports every problem in one pass, not just the first" {
  unset AI_REVIEW_TOOL
  run bash "${AUDIT}" --doctor --output-parent-dir "${BATS_TEST_TMPDIR}/nope"
  [ "$status" -eq 1 ]
  [[ "$output" == *"AI_REVIEW_TOOL"* ]]
  [[ "$output" == *"does not exist"* ]]
}

# ── confirmation before spending ────────────────────────────────────────────

@test "audit: refuses to start non-interactively without --yes" {
  unset AI_AUDIT_ASSUME_YES
  run bash -c "bash '${AUDIT}' --output-parent-dir '${OUT_PARENT}' </dev/null 2>&1"
  [ "$status" -eq 2 ]
  [[ "$output" == *"stdin is not a TTY"* ]]
  [[ "$output" == *"--yes"* ]]
}

@test "audit: the refusal names the cost it would have incurred" {
  unset AI_AUDIT_ASSUME_YES
  run bash -c "bash '${AUDIT}' --output-parent-dir '${OUT_PARENT}' </dev/null 2>&1"
  [[ "$output" == *"file(s) across"* ]]
  [[ "$output" == *"batch(es)"* ]]
}

@test "audit: --yes skips the prompt" {
  unset AI_AUDIT_ASSUME_YES
  run bash "${AUDIT}" --output-parent-dir "${OUT_PARENT}" --yes
  [ "$status" -eq 0 ]
  [[ "$output" != *"Proceed?"* ]]
}

@test "audit: -y is accepted too" {
  unset AI_AUDIT_ASSUME_YES
  run bash "${AUDIT}" --output-parent-dir "${OUT_PARENT}" -y
  [ "$status" -eq 0 ]
}

@test "audit: AI_AUDIT_ASSUME_YES=1 skips the prompt" {
  AI_AUDIT_ASSUME_YES=1 run bash "${AUDIT}" --output-parent-dir "${OUT_PARENT}"
  [ "$status" -eq 0 ]
  [[ "$output" != *"Proceed?"* ]]
}

@test "audit: the no-AI-call paths never prompt" {
  # Inspecting scope or cost must not require confirming a spend.
  unset AI_AUDIT_ASSUME_YES
  run bash "${AUDIT}" --dry-run
  [ "$status" -eq 0 ]
  [[ "$output" != *"Proceed?"* ]]
  run bash "${AUDIT}" --list-files
  [ "$status" -eq 0 ]
  run bash "${AUDIT}" --list-batches
  [ "$status" -eq 0 ]
}

@test "audit: --jobs controls fan-out concurrency" {
  run bash "${AUDIT}" --jobs 8 --dry-run
  [ "$status" -eq 0 ]
  [[ "$output" == *"concurrency 8"* ]]
  run bash "${AUDIT}" --jobs 1 --dry-run
  [ "$status" -eq 0 ]
  [[ "$output" == *"concurrency 1"* ]]
}

# ── report bundle ───────────────────────────────────────────────────────────

@test "audit: --output-parent-dir is required for a real run" {
  run bash "${AUDIT}" terraform/
  [ "$status" -eq 2 ]
  [[ "$output" == *"--output-parent-dir is required"* ]]
}

@test "audit: a missing parent directory is an error and is NOT created" {
  local parent="${BATS_TEST_TMPDIR}/nope/deeper"
  run bash "${AUDIT}" --output-parent-dir "${parent}" terraform/
  [ "$status" -eq 2 ]
  [[ "$output" == *"does not exist"* ]]
  [ ! -d "${parent}" ]
}

@test "audit: --output-parent-dir with no value does not swallow the next flag" {
  run bash "${AUDIT}" --output-parent-dir --dry-run
  [ "$status" -eq 2 ]
  [[ "$output" == *"requires an existing directory"* ]]
}

@test "audit: --json-only needs no output directory" {
  run bash "${AUDIT}" --json-only
  [ "$status" -eq 0 ]
  [[ "$output" == *'"review_action"'* ]]
}

@test "audit: --dry-run and --list-files need no output directory" {
  run bash "${AUDIT}" --dry-run
  [ "$status" -eq 0 ]
  run bash "${AUDIT}" --list-files
  [ "$status" -eq 0 ]
}

@test "audit: the bundle is written to <repo>-<date>-NN with an _INDEX.md" {
  local parent="${BATS_TEST_TMPDIR}/audits"
  mkdir -p "${parent}"
  run bash "${AUDIT}" --output-parent-dir "${parent}"
  [ "$status" -eq 0 ]
  [[ "$output" == *"_INDEX.md"* ]]
  local dir
  dir="$(find "${parent}" -maxdepth 1 -mindepth 1 -type d)"
  [[ "$(basename "${dir}")" =~ ^audit-repo-[0-9]{8}-01$ ]]
  [ -f "${dir}/_INDEX.md" ]
  [ -f "${dir}/findings.json" ]
  [ -f "${dir}/report.md" ]
}

@test "audit: the run number increments rather than overwriting" {
  local parent="${BATS_TEST_TMPDIR}/audits"
  mkdir -p "${parent}"
  bash "${AUDIT}" --output-parent-dir "${parent}" >/dev/null 2>&1
  bash "${AUDIT}" --output-parent-dir "${parent}" >/dev/null 2>&1
  [ "$(find "${parent}" -maxdepth 1 -mindepth 1 -type d | wc -l | tr -d ' ')" -eq 2 ]
  [ -d "${parent}/$(basename "$(git rev-parse --show-toplevel)")-$(date +%Y%m%d)-02" ]
}

@test "audit: a two-digit run number is parsed as base 10, not octal" {
  # 08 and 09 are invalid octal; without 10# the ninth run of a day crashes.
  local parent="${BATS_TEST_TMPDIR}/audits"
  local repo; repo="$(basename "$(git rev-parse --show-toplevel)")"
  mkdir -p "${parent}/${repo}-$(date +%Y%m%d)-08"
  run bash "${AUDIT}" --output-parent-dir "${parent}"
  [ "$status" -eq 0 ]
  [ -d "${parent}/${repo}-$(date +%Y%m%d)-09" ]
}

@test "audit: per-directory docs use __ for slashes and carry the findings" {
  local parent="${BATS_TEST_TMPDIR}/audits"
  mkdir -p "${parent}"
  bash "${AUDIT}" --output-parent-dir "${parent}" >/dev/null 2>&1
  local dir; dir="$(find "${parent}" -maxdepth 1 -mindepth 1 -type d)"
  [ -f "${dir}/src.md" ]
  grep -q '^#### ' "${dir}/src.md"
}

@test "audit: the grep convention lists only docs with findings" {
  local parent="${BATS_TEST_TMPDIR}/audits"
  mkdir -p "${parent}"
  bash "${AUDIT}" --output-parent-dir "${parent}" >/dev/null 2>&1
  local dir; dir="$(find "${parent}" -maxdepth 1 -mindepth 1 -type d)"
  # terraform/ has no finding in the stub response, so it must not match.
  run bash -c "cd '${dir}' && grep -rl '^#### ' . | sort"
  [[ "$output" != *"terraform"* ]]
}

@test "audit: the index carries the advisory disclaimer" {
  local parent="${BATS_TEST_TMPDIR}/audits"
  mkdir -p "${parent}"
  bash "${AUDIT}" --output-parent-dir "${parent}" >/dev/null 2>&1
  local dir; dir="$(find "${parent}" -maxdepth 1 -mindepth 1 -type d)"
  grep -q "Advisory, not exhaustive" "${dir}/_INDEX.md"
  grep -q "control IDs" "${dir}/_INDEX.md"
}

@test "audit: nothing is written into the audited repo when a bundle is produced" {
  local parent="${BATS_TEST_TMPDIR}/audits"
  mkdir -p "${parent}"
  local before; before="$(git status --porcelain; git ls-files)"
  bash "${AUDIT}" --output-parent-dir "${parent}" >/dev/null 2>&1
  [ "$(git status --porcelain; git ls-files)" = "${before}" ]
}

# ── endpoint / data path ────────────────────────────────────────────────────
# An audit sends the whole scope to the endpoint, not a diff, so an ignored
# provider setting is the worst failure this tool can have: the entire codebase
# to the wrong place, with nothing reported. configure_endpoint was missing
# entirely, so AI_REVIEW_PROVIDER was silently discarded.

@test "audit: the dry-run plan names the provider" {
  run bash "${AUDIT}" --dry-run
  [ "$status" -eq 0 ]
  [[ "$output" == *"Provider:"* ]]
}

@test "audit: the default provider is flagged as a PUBLIC endpoint" {
  run bash "${AUDIT}" --dry-run
  [ "$status" -eq 0 ]
  [[ "$output" == *"PUBLIC endpoint"* ]]
}

@test "audit: an in-boundary provider is not flagged as public" {
  AI_REVIEW_PROVIDER=bedrock AWS_REGION=us-east-1 run bash "${AUDIT}" --dry-run
  [ "$status" -eq 0 ]
  [[ "$output" == *"Provider:"*"bedrock"* ]]
  [[ "$output" != *"PUBLIC endpoint"* ]]
}

@test "audit: provider=bedrock without a region fails rather than using the public API" {
  # The engine must not quietly fall back to the public endpoint.
  run bash -c "AI_REVIEW_PROVIDER=bedrock bash '${AUDIT}' --output-parent-dir '${OUT_PARENT}' terraform/ 2>&1"
  [[ "$output" == *"requires AWS_REGION"* ]]
}

@test "audit: provider=azure without an endpoint is a config error" {
  run bash -c "AI_REVIEW_TOOL=codex AI_REVIEW_PROVIDER=azure bash '${AUDIT}' --output-parent-dir '${OUT_PARENT}' terraform/ 2>&1"
  [[ "$output" == *"provider=azure requires"* ]]
}

@test "audit: an unrecognized provider is rejected" {
  run bash -c "AI_REVIEW_PROVIDER=nonsense bash '${AUDIT}' --output-parent-dir '${OUT_PARENT}' terraform/ 2>&1"
  [[ "$output" == *"not a recognized value"* ]]
}

@test "audit: --dry-run needs no endpoint credentials" {
  # Endpoint validation runs after the dry-run gate, so someone can inspect the
  # plan — including where the code would go — before holding any credential.
  AI_REVIEW_PROVIDER=bedrock run bash "${AUDIT}" --dry-run
  [ "$status" -eq 0 ]
}

# ── a full stubbed run ──────────────────────────────────────────────────────

@test "audit: completes and reports the finding count" {
  run bash "${AUDIT}" --output-parent-dir "${OUT_PARENT}"
  [ "$status" -eq 0 ]
  [[ "$output" == *"Audit complete: 1 finding(s)"* ]]
}

@test "audit: --json-out writes the findings JSON outside the audited repo" {
  local out="${BATS_TEST_TMPDIR}/findings.json"
  run bash "${AUDIT}" --output-parent-dir "${OUT_PARENT}" --json-out "${out}"
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
  run bash "${AUDIT}" --output-parent-dir "${OUT_PARENT}"
  [ "$status" -eq 0 ]
  after="$(git status --porcelain; git ls-files)"
  [ "${before}" = "${after}" ]
}

@test "audit: a missing result marker fails rather than reporting clean" {
  cat >"${STUB_RESPONSE_FILE}" <<'EOF'
## Codebase Audit Report
no marker here
EOF
  run bash "${AUDIT}" --output-parent-dir "${OUT_PARENT}"
  [ "$status" -eq 1 ]
}

@test "audit: findings but no JSON block fails rather than reporting clean" {
  cat >"${STUB_RESPONSE_FILE}" <<'EOF'
## Codebase Audit Report
<<<AI_REVIEW_RESULT:AUDIT_FINDINGS>>>
EOF
  run bash "${AUDIT}" --output-parent-dir "${OUT_PARENT}"
  [ "$status" -eq 1 ]
}

@test "audit: an AI CLI failure is a runtime error" {
  STUB_EXIT=9 run bash "${AUDIT}" --output-parent-dir "${OUT_PARENT}"
  [ "$status" -eq 1 ]
}

@test "audit: warns when CI is set" {
  CI=true run bash "${AUDIT}" --list-files
  [ "$status" -eq 0 ]
  [[ "$output" == *"ad-hoc local tool"* ]]
}

@test "audit: the prompt carries the audit rubric and the scope, not a diff" {
  export STUB_PROMPT_LOG="${BATS_TEST_TMPDIR}/prompt.log"
  run bash "${AUDIT}" --output-parent-dir "${OUT_PARENT}" terraform/
  [ "$status" -eq 0 ]
  grep -q "CODEBASE-AUDIT INSTRUCTIONS" "${STUB_PROMPT_LOG}"
  grep -q "AUDIT SCOPE" "${STUB_PROMPT_LOG}"
  grep -q "terraform/rds.tf" "${STUB_PROMPT_LOG}"
}

@test "audit: the compliance perspective is included when IaC is in scope" {
  export STUB_PROMPT_LOG="${BATS_TEST_TMPDIR}/prompt.log"
  run bash "${AUDIT}" --output-parent-dir "${OUT_PARENT}" terraform/
  [ "$status" -eq 0 ]
  grep -q "COMPLIANCE PERSPECTIVE" "${STUB_PROMPT_LOG}"
}

@test "audit: the compliance perspective is omitted when no IaC is in scope" {
  export STUB_PROMPT_LOG="${BATS_TEST_TMPDIR}/prompt.log"
  run bash "${AUDIT}" --output-parent-dir "${OUT_PARENT}" src/
  [ "$status" -eq 0 ]
  ! grep -q "COMPLIANCE PERSPECTIVE" "${STUB_PROMPT_LOG}"
}
