#!/usr/bin/env bats
#
# Tests the release workflow's gates by EXTRACTING and RUNNING their real
# shell from .github/workflows/release.yml against scratch repositories.
#
# Why extract rather than re-implement: a release workflow fires a few times a
# year, on a tag, with no pull request in front of it — so its gates are the
# least-exercised code in the repo and the last place a mistake surfaces. The
# first cut shipped `git merge-base --is-ancestor "${GITHUB_SHA}"
# origin/FETCH_HEAD`, and `origin/FETCH_HEAD` is not a ref: merge-base exited
# non-zero for every input, so the gate rejected the first tag ever pushed at
# it (v0.1.0, which was sitting exactly on main's HEAD). A gate that cannot
# pass is indistinguishable from a gate that works until you try it.
#
# A copy of the snippet pasted into this file would have drifted away from the
# workflow and reproduced the bug in both places, so these tests read the
# shipped YAML.

setup() {
  REPO_ROOT="$(cd "${BATS_TEST_DIRNAME}/../.." && pwd)"
  WORKFLOW="${REPO_ROOT}/.github/workflows/release.yml"
  export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@example.com
  export GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@example.com
}

# Pull one step's `run:` block out of the workflow and write it to a file.
# Body lines are indented ten spaces under `        run: |`; the block ends at
# the first non-blank line indented less than that.
extract_step() {
  local step_name="$1" dest="$2"
  awk -v want="      - name: ${step_name}" '
    $0 == want            { found = 1; next }
    found && $0 == "        run: |" { body = 1; found = 0; next }
    body {
      if ($0 ~ /^[[:space:]]*$/) { print ""; next }
      if (substr($0, 1, 10) == "          ") { print substr($0, 11); next }
      exit
    }
  ' "${WORKFLOW}" >"${dest}"
}

# A bare "remote" with `main`, plus a commit that never reached it.
make_repo() {
  UP="${BATS_TEST_TMPDIR}/upstream.git"
  WORK="${BATS_TEST_TMPDIR}/work"
  git init -q --bare -b main "${UP}"
  git init -q -b main "${WORK}"
  git -C "${WORK}" remote add origin "${UP}"
  git -C "${WORK}" commit -q --allow-empty -m first
  git -C "${WORK}" commit -q --allow-empty -m second
  ON_MAIN="$(git -C "${WORK}" rev-parse HEAD)"
  git -C "${WORK}" push -q origin main

  git -C "${WORK}" checkout -q -b sidebranch
  git -C "${WORK}" commit -q --allow-empty -m "never merged"
  OFF_MAIN="$(git -C "${WORK}" rev-parse HEAD)"
  git -C "${WORK}" checkout -q main
}

# ── the extractor itself ────────────────────────────────────────────────────
#
# Without this, an extractor that silently produced an empty file would make
# every test below pass vacuously: `bash /dev/null` exits 0.

@test "the ancestry gate is found in the workflow and is non-trivial" {
  extract_step "The tag must be on main" "${BATS_TEST_TMPDIR}/gate.sh"
  [ -s "${BATS_TEST_TMPDIR}/gate.sh" ]
  grep -q "merge-base" "${BATS_TEST_TMPDIR}/gate.sh"
  grep -q "exit 1" "${BATS_TEST_TMPDIR}/gate.sh"
}

# ── the ancestry gate ───────────────────────────────────────────────────────

@test "ancestry gate: accepts a commit that is on main" {
  make_repo
  extract_step "The tag must be on main" "${BATS_TEST_TMPDIR}/gate.sh"
  cd "${WORK}"
  GITHUB_SHA="${ON_MAIN}" GITHUB_REF_NAME=v0.1.0 run bash "${BATS_TEST_TMPDIR}/gate.sh"
  [ "$status" -eq 0 ]
  [[ "$output" == *"Tag is on main."* ]]
}

@test "ancestry gate: accepts main's tip (the shape v0.1.0 had)" {
  make_repo
  extract_step "The tag must be on main" "${BATS_TEST_TMPDIR}/gate.sh"
  cd "${WORK}"
  # The bug that motivated this file: the tag pointed at exactly main's HEAD
  # and the gate still refused it.
  [ "$(git rev-parse HEAD)" = "${ON_MAIN}" ]
  GITHUB_SHA="${ON_MAIN}" GITHUB_REF_NAME=v0.1.0 run bash "${BATS_TEST_TMPDIR}/gate.sh"
  [ "$status" -eq 0 ]
}

@test "ancestry gate: rejects a commit that never reached main" {
  make_repo
  extract_step "The tag must be on main" "${BATS_TEST_TMPDIR}/gate.sh"
  cd "${WORK}"
  GITHUB_SHA="${OFF_MAIN}" GITHUB_REF_NAME=v9.9.9 run bash "${BATS_TEST_TMPDIR}/gate.sh"
  [ "$status" -ne 0 ]
  [[ "$output" == *"is not an ancestor of main"* ]]
}

@test "ancestry gate: an old commit deep in main's history is still accepted" {
  make_repo
  extract_step "The tag must be on main" "${BATS_TEST_TMPDIR}/gate.sh"
  cd "${WORK}"
  first="$(git rev-list --max-parents=0 HEAD)"
  GITHUB_SHA="${first}" GITHUB_REF_NAME=v0.0.1 run bash "${BATS_TEST_TMPDIR}/gate.sh"
  [ "$status" -eq 0 ]
}

# ── the surface gate ────────────────────────────────────────────────────────

@test "surface gate: passes against this repo's own tree" {
  extract_step "The consumer surface is present and runnable" "${BATS_TEST_TMPDIR}/surface.sh"
  [ -s "${BATS_TEST_TMPDIR}/surface.sh" ]
  cd "${REPO_ROOT}"
  run bash "${BATS_TEST_TMPDIR}/surface.sh"
  [ "$status" -eq 0 ]
  [[ "$output" == *"Surface present"* ]]
}

@test "surface gate: fails when a required path is missing" {
  extract_step "The consumer surface is present and runnable" "${BATS_TEST_TMPDIR}/surface.sh"
  cd "${BATS_TEST_TMPDIR}"
  mkdir -p empty
  cd empty
  run bash "${BATS_TEST_TMPDIR}/surface.sh"
  [ "$status" -ne 0 ]
  [[ "$output" == *"missing from the release tree"* ]]
}

@test "surface gate: fails when an entrypoint loses its exec bit" {
  extract_step "The consumer surface is present and runnable" "${BATS_TEST_TMPDIR}/surface.sh"
  # A copy of the tree, so the real one keeps its modes.
  tree="${BATS_TEST_TMPDIR}/tree"
  mkdir -p "${tree}"
  (cd "${REPO_ROOT}" && git ls-files -z | xargs -0 tar cf -) | tar xf - -C "${tree}"
  entry="$(cd "${tree}" && ls engines/*/harness/ai-* | head -1)"
  chmod -x "${tree}/${entry}"
  cd "${tree}"
  run bash "${BATS_TEST_TMPDIR}/surface.sh"
  [ "$status" -ne 0 ]
  [[ "$output" == *"not executable"* ]]
}
