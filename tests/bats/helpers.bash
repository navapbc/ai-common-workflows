# Shared setup for the engine's bats suites.
#
# Each test gets a throwaway git repo with a seeded two-file diff (one
# application file, one Terraform file) between origin/main and HEAD, and a
# PATH that resolves the AI CLIs and gh to the stubs in tests/stubs/.

REPO_ROOT="$(cd "${BATS_TEST_DIRNAME}/../.." && pwd)"
ENGINE="${REPO_ROOT}/engine/bin/ai-pr-review"
CORE_LIB="${REPO_ROOT}/engine/lib/core.sh"
ENDPOINTS_LIB="${REPO_ROOT}/engine/lib/endpoints.sh"
FIXTURES="${REPO_ROOT}/tests/fixtures"
STUBS="${REPO_ROOT}/tests/stubs"

common_setup() {
  export PATH="${STUBS}:${PATH}"
  export CI=true
  export AI_REVIEW_TOOL=claude
  export ANTHROPIC_API_KEY=stub-key
  export STUB_RESPONSE_FILE="${FIXTURES}/response-comment.txt"
  export STUB_CALLS="${BATS_TEST_TMPDIR}/stub-calls.log"
  # Ensure host/CI GitHub tokens never leak into engine test behavior.
  unset GITHUB_TOKEN GH_TOKEN AI_REVIEW_PROVIDER AI_REVIEW_MODEL || true
}

# Creates a scratch repo with a 2-file diff (src/app.py + infra/rds.tf) and
# cds into it. origin/main is simulated with a local ref.
make_scratch_repo() {
  SCRATCH_REPO="${BATS_TEST_TMPDIR}/repo"
  mkdir -p "${SCRATCH_REPO}"
  cd "${SCRATCH_REPO}"
  git init -qb main
  git config user.email test@example.com
  git config user.name test
  mkdir -p src infra
  echo "print('hello')" > src/app.py
  git add -A
  git commit -qm base
  git checkout -qb feature
  printf 'import os\napi_key = os.environ["K"]\nprint(api_key)\n' > src/app.py
  printf 'resource "aws_db_instance" "db" {\n  allocated_storage = 10\n}\n' > infra/rds.tf
  git add -A
  git commit -qm change
  git update-ref refs/remotes/origin/main main
}

# Adds 12 more files across 4 directories so the diff crosses the fan-out
# threshold (default AI_REVIEW_BATCH_MIN_FILES=10).
add_many_files() {
  local d i
  for d in a b c d; do
    mkdir -p "mod_${d}"
    for i in 1 2 3; do
      echo "x = ${i}" > "mod_${d}/file${i}.py"
    done
  done
  git add -A
  git commit -qm "many files"
}

# Sources core.sh in the current shell for unit-testing its functions.
source_core() {
  SKILL_NAME="pr-review"
  # shellcheck disable=SC1090
  source "${CORE_LIB}"
}
