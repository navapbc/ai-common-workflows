#!/usr/bin/env bash
# Run the full engine test suite: static checks, bats, and pytest.
#
#   tests/run.sh            # everything
#   tests/run.sh --no-lint  # skip shellcheck/shfmt (e.g. not installed)
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "${REPO_ROOT}"

RUN_LINT=1
[[ "${1:-}" == "--no-lint" ]] && RUN_LINT=0

fail=0

if (( RUN_LINT )) && command -v shellcheck &>/dev/null; then
  echo "==> shellcheck"
  shellcheck -x -P SCRIPTDIR \
    engines/security-compliance-review/harness/ai-security-compliance-review \
    engines/security-compliance-review/harness/ai-security-compliance-audit \
    engines/test-classifier/harness/ai-test-classifier \
    engines/_common/harness/core.sh engines/_common/endpoints.sh \
    engines/_common/scm/github.sh \
    workflows/_shared/lib/ci.sh \
    tests/stubs/* tests/run.sh tests/lint_workflow_shell.sh || fail=1
fi

if (( RUN_LINT )) && command -v shfmt &>/dev/null; then
  echo "==> shfmt (diff check)"
  shfmt -d -i 2 -ci engines workflows/_shared/lib || fail=1
fi

echo "==> pytest"
python3 -m pytest tests/python/ -q || fail=1

echo "==> embedded workflow shell"
bash tests/lint_workflow_shell.sh || fail=1

echo "==> bats: core + e2e + ci_shared + test_classifier + audit + release"
bats tests/bats/core.bats tests/bats/e2e.bats tests/bats/ci_shared.bats \
  tests/bats/test_classifier.bats tests/bats/audit.bats \
  tests/bats/release.bats || fail=1

# tests/corpus/ is the DETECTION corpus — fixture diffs with expected findings.
# Everything above tests the envelope (does the JSON parse, does the gate fire)
# and would still pass if the rubric reported nothing; the corpus is what tests
# whether the review is any good. It makes real model calls, so it runs on
# demand:  bash tests/corpus/run.sh   (see tests/corpus/README.md)

if (( fail )); then
  echo "SUITE FAILED" >&2
  exit 1
fi
echo "SUITE PASSED"
