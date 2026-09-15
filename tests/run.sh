#!/usr/bin/env bash
# Run the full engine test suite: static checks, bats, and pytest.
# Sandbox bats tests self-skip when Docker is unavailable.
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
    engines/test-classifier/harness/ai-test-classifier \
    engines/_common/harness/core.sh engines/_common/endpoints.sh \
    engines/_common/scm/github.sh engines/_common/sandbox/sandbox.sh \
    workflows/_shared/lib/ci.sh \
    tests/stubs/* tests/run.sh || fail=1
fi

if (( RUN_LINT )) && command -v shfmt &>/dev/null; then
  echo "==> shfmt (diff check)"
  shfmt -d -i 2 -ci engines workflows/_shared/lib || fail=1
fi

echo "==> pytest"
python3 -m pytest tests/python/ -q || fail=1

echo "==> bats: core + e2e + ci_shared + test_classifier"
bats tests/bats/core.bats tests/bats/e2e.bats tests/bats/ci_shared.bats \
  tests/bats/test_classifier.bats || fail=1

# tests/bats/sandbox.bats covers the experimental (unshipped) sandbox and is
# not part of the default suite; run it manually with Docker if working on it.

if (( fail )); then
  echo "SUITE FAILED" >&2
  exit 1
fi
echo "SUITE PASSED"
