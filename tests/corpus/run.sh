#!/usr/bin/env bash
# Run the detection corpus: each case is a small diff with expected findings.
#
#   export AI_REVIEW_TOOL=claude
#   export ANTHROPIC_API_KEY=sk-...
#   bash tests/corpus/run.sh                    # every case
#   bash tests/corpus/run.sh 01 04              # only these (prefix match)
#   bash tests/corpus/run.sh --profile base,cms-ars-5.1
#
# Deliberately NOT part of `bash tests/run.sh`: every case is a real model call.
# See README.md in this directory for what the corpus can and cannot tell you.
#
# Exit status is the number of cases that did not meet expectations, capped at
# 125, so CI could gate on it if you ever want that — but the useful signal is
# the DELTA across a rubric change, not a single run's absolute pass count.

set -uo pipefail

CORPUS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${CORPUS_DIR}/../.." && pwd)"
ENGINE="${REPO_ROOT}/engines/security-compliance-review/harness/ai-security-compliance-review"

PROFILE="base"
SELECT=()
while (($#)); do
  case "$1" in
    --profile)
      PROFILE="${2:-base}"
      shift 2
      ;;
    --profile=*)
      PROFILE="${1#*=}"
      shift
      ;;
    -h | --help)
      sed -n '2,16p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
      exit 0
      ;;
    *)
      SELECT+=("$1")
      shift
      ;;
  esac
done

if [[ -z "${AI_REVIEW_TOOL:-}" ]]; then
  echo "AI_REVIEW_TOOL must be set (claude | codex | copilot)." >&2
  echo "The corpus makes real model calls; there is no stub mode." >&2
  exit 2
fi

WORK="$(mktemp -d)"
trap 'rm -rf "${WORK}"' EXIT

selected() {
  ((${#SELECT[@]} == 0)) && return 0
  local name="$1" s
  for s in "${SELECT[@]}"; do [[ "${name}" == "${s}"* ]] && return 0; done
  return 1
}

total_expected=0
total_found=0
cases_failed=0
cases_with_extras=0
declare -a rows=()

for case_dir in "${CORPUS_DIR}"/*/; do
  name="$(basename "${case_dir}")"
  [[ -f "${case_dir}/expected.json" ]] || continue
  selected "${name}" || continue

  # ── Build a scratch repo: base/ as the first commit, head/ overlaid on top ──
  repo="${WORK}/${name}"
  mkdir -p "${repo}"
  (
    cd "${repo}" || exit 1
    git init -q .
    git config user.email corpus@example.com
    git config user.name corpus
    if [[ -d "${case_dir}/base" ]]; then
      cp -R "${case_dir}/base/." .
    else
      # Every case needs a base commit for --against to name. An empty marker
      # keeps `head/` files reading as additions, which is what a new-file
      # finding looks like in a real PR.
      printf 'corpus case: %s\n' "${name}" >.corpus-base
    fi
    git add -A && git commit -q -m base
    cp -R "${case_dir}/head/." .
    git add -A && git commit -q -m head
  ) || {
    echo "  ${name}: could not build the scratch repo" >&2
    cases_failed=$((cases_failed + 1))
    continue
  }

  json="${WORK}/${name}.json"
  (
    cd "${repo}" || exit 1
    AI_REVIEW_PROFILE="${PROFILE}" \
      bash "${ENGINE}" --against HEAD~1 --json-out "${json}" >/dev/null 2>"${WORK}/${name}.log"
  )

  if [[ ! -s "${json}" ]]; then
    rows+=("  ${name}  ENGINE-FAILED  (see ${WORK}/${name}.log)")
    cases_failed=$((cases_failed + 1))
    continue
  fi

  # ── Score it ────────────────────────────────────────────────────────────────
  score="$(python3 "${CORPUS_DIR}/score.py" "${case_dir}/expected.json" "${json}")"
  read -r c_expected c_found c_extra c_verdict <<<"${score}"
  total_expected=$((total_expected + c_expected))
  total_found=$((total_found + c_found))
  ((c_extra > 0)) && cases_with_extras=$((cases_with_extras + 1))
  [[ "${c_verdict}" == "PASS" ]] || cases_failed=$((cases_failed + 1))

  if ((c_expected == 0)); then
    rows+=("$(printf '  %-32s %-11s extra %-3s %s' "${name}" "CLEAN" "${c_extra}" "(expected clean)")")
  else
    rows+=("$(printf '  %-32s FOUND %s/%-5s extra %-3s %s' "${name}" "${c_found}" "${c_expected}" "${c_extra}" "")")
  fi
done

printf '%s\n' "${rows[@]+"${rows[@]}"}"
echo
echo "  profile: ${PROFILE}   tool: ${AI_REVIEW_TOOL}"
if ((total_expected > 0)); then
  echo "  recall ${total_found}/${total_expected} expected finding(s)"
else
  echo "  no positive expectations in the selected cases"
fi
echo "  ${cases_with_extras} case(s) reported findings that were not expected"
echo "  ${cases_failed} case(s) did not meet expectations"
echo
echo "  Compare against a run from BEFORE your rubric change; one run is a"
echo "  sample, not a measurement. Logs and findings JSON: ${WORK}"
trap - EXIT # keep the artifacts for inspection

((cases_failed > 125)) && exit 125
exit "${cases_failed}"
