#!/usr/bin/env bash
# workflows/_shared/lib/ci.sh
#
# Shared GitHub Actions plumbing for ai-common-workflows composite actions.
# A per-workflow action.yml *sources* this file (it is never executed directly)
# via an absolute path derived from ${{ github.action_path }}, e.g.
#
#   source "$(cd "${GITHUB_ACTION_PATH}/../_shared/lib" && pwd)/ci.sh"
#
# Sourcing by absolute path is deliberate: a composite action CANNOT reference a
# sibling composite (`uses: ./workflows/_shared`) because GitHub resolves `./`
# against the *consumer's* checkout, not this repo. Bash `source` has no such
# limitation.
#
# Each function reads its inputs from environment variables the calling step
# sets, and appends to $GITHUB_OUTPUT where noted. NOTHING here handles the SCM
# token — that separation stays visible in the action.yml step `env:` blocks, by
# design, so the security property is auditable in one place.

# ci::validate_inputs — validate AI_TOOL + PROVIDER and their compatibility.
# Reads: AI_TOOL, PROVIDER. Returns non-zero (with a ::error::) on bad input.
ci::validate_inputs() {
  case "${AI_TOOL}" in
    claude | codex | copilot) ;;
    *)
      echo "::error::ai-tool must be claude | codex | copilot (got '${AI_TOOL}')"
      return 1
      ;;
  esac
  case "${PROVIDER}" in
    api | bedrock | vertex | azure) ;;
    *)
      echo "::error::provider must be api | bedrock | vertex | azure (got '${PROVIDER}')"
      return 1
      ;;
  esac
  case "${PROVIDER}" in
    bedrock)
      if [[ "${AI_TOOL}" != "claude" && "${AI_TOOL}" != "codex" ]]; then
        echo "::error::provider=bedrock is only supported with ai-tool=claude or codex"
        return 1
      fi
      ;;
    vertex)
      if [[ "${AI_TOOL}" != "claude" ]]; then
        echo "::error::provider=vertex is only supported with ai-tool=claude"
        return 1
      fi
      ;;
    azure)
      if [[ "${AI_TOOL}" != "codex" ]]; then
        echo "::error::provider=azure is only supported with ai-tool=codex (Azure OpenAI serves OpenAI models)"
        return 1
      fi
      ;;
  esac
}

# ci::resolve_pr_context — determine the PR number + base ref and write
# skip/pr/base to $GITHUB_OUTPUT. Reads: PR_NUMBER_INPUT, EVENT_PR_NUMBER,
# EVENT_BASE_REF.
ci::resolve_pr_context() {
  local pr base
  pr="${PR_NUMBER_INPUT:-${EVENT_PR_NUMBER:-}}"
  base="${EVENT_BASE_REF:-}"
  if [[ -z "${pr}" ]]; then
    echo "::notice::No PR context (not a pull_request event and no pr-number given). Skipping review."
    echo "skip=true" >>"${GITHUB_OUTPUT}"
    return 0
  fi
  if [[ -z "${base}" ]]; then
    echo "::error::Could not determine the PR base ref. On non-pull_request events, run on a PR or provide the base via checkout."
    return 1
  fi
  {
    echo "skip=false"
    echo "pr=${pr}"
    echo "base=${base}"
  } >>"${GITHUB_OUTPUT}"
}

# ci::ensure_base_ref — make origin/<base> resolvable locally for `git diff`.
# actions/checkout fetches the PR head; consumers who set fetch-depth: 0 already
# have the base. Reads: BASE, BASE_REF_TOKEN (optional).
#
# On a PRIVATE repo this fetch needs credentials. `actions/checkout` leaves a
# token in .git/config by default, but docs/security.md recommends
# `persist-credentials: false` so the AI phase cannot read one — which also
# strips the credential this fetch would have used. So when BASE_REF_TOKEN is
# provided we authenticate explicitly, via a per-invocation credential helper
# that reads the token from the ENVIRONMENT when git calls it. That keeps the
# secret out of argv (and therefore out of the process list and the log) and
# writes nothing to .git/config, so the later AI phase still runs against a
# credential-free repository.
#
# Failure is a warning, not silence: without the base ref the review cannot
# produce a diff, and "Git ref not found" several steps later is a confusing
# way to learn that a fetch was refused.
# BASE is an env var set by the calling step; the lowercase `base` in
# resolve_pr_context is unrelated (SC2153 misfires on the pair).
# shellcheck disable=SC2153
ci::ensure_base_ref() {
  local -a cred=()
  if [[ -n "${BASE_REF_TOKEN:-}" ]]; then
    # Single-quoted ON PURPOSE (SC2016): ${BASE_REF_TOKEN} must NOT expand
    # here. Leaving it unexpanded is what keeps the token out of argv — git
    # runs this helper as a shell snippet and the expansion happens inside
    # that subshell, reading the value from the inherited environment.
    # The empty first value resets any inherited helper chain (git appends).
    # shellcheck disable=SC2016
    cred=(-c 'credential.helper=' -c
      'credential.helper=!f() { printf "username=x-access-token\npassword=%s\n" "${BASE_REF_TOKEN}"; }; f')
  fi
  local out rc=0
  out="$(git "${cred[@]+"${cred[@]}"}" fetch --no-tags --depth=200 origin \
    "+refs/heads/${BASE}:refs/remotes/origin/${BASE}" 2>&1)" || rc=$?
  if ((rc != 0)); then
    printf '%s\n' "${out}"
    echo "::warning::Could not fetch the base ref '${BASE}' (git exit ${rc}). The review needs it to build the diff. On a private repository, either let the action use the workflow token (the default) or check out with 'fetch-depth: 0' so the base ref is already present."
    return 0
  fi

  # The engine reviews BASE...HEAD (what this branch changed), which needs the
  # branch point in local history. actions/checkout defaults to fetch-depth: 1,
  # so it usually is not there — deepen once, bounded, rather than pulling the
  # full history of a large repository. If this still isn't enough the engine
  # warns and falls back to a direct BASE→HEAD diff.
  if [[ "$(git rev-parse --is-shallow-repository 2>/dev/null)" == "true" ]] &&
    ! git merge-base "refs/remotes/origin/${BASE}" HEAD >/dev/null 2>&1; then
    git "${cred[@]+"${cred[@]}"}" fetch --no-tags \
      --deepen="${BASE_REF_DEEPEN:-500}" origin >/dev/null 2>&1 || true
    if ! git merge-base "refs/remotes/origin/${BASE}" HEAD >/dev/null 2>&1; then
      echo "::warning::No common ancestor with '${BASE}' within ${BASE_REF_DEEPEN:-500} commits of history. The review will diff ${BASE}→HEAD directly, which can attribute commits made on ${BASE} since this branch diverged to this PR. Check out with 'fetch-depth: 0' for an exact PR diff."
    fi
  fi
}

# ci::install_ai_cli — npm-install the chosen AI CLI on the runner.
# Reads: AI_TOOL, CLI_VERSION.
ci::install_ai_cli() {
  case "${AI_TOOL}" in
    claude) npm install -g "@anthropic-ai/claude-code@${CLI_VERSION}" ;;
    codex) npm install -g "@openai/codex@${CLI_VERSION}" ;;
    copilot) npm install -g "@github/copilot@${CLI_VERSION}" ;;
  esac
}

# ci::gate_result — read review_action from the findings JSON, echo it, write it
# to $GITHUB_OUTPUT, and fail the job when GATE=true and the result is not
# APPROVE. Reads: REVIEW_JSON, GATE.
#
# The `result` output is ALWAYS written, so consumers can gate on it (the
# read-only mode documented in docs/github-action.md relies on exactly that).
# An absent findings file means the engine exited 0 without writing one, which
# only happens when the diff is empty — there is nothing to flag, so that is
# APPROVE. This matches the Jenkins plugin's readReviewAction().
#
# A findings file that EXISTS but cannot be parsed is an engine malfunction and
# fails the step rather than defaulting to APPROVE — never fail open on the
# verdict that drives the gate.
ci::gate_result() {
  local result
  if [[ ! -f "${REVIEW_JSON}" ]]; then
    result="APPROVE"
    echo "[ai-review] no findings file (empty diff); reporting APPROVE."
  elif ! result="$(python3 -c '
import json, sys
d = json.load(open(sys.argv[1]))
a = d["review_action"]
if a not in ("APPROVE", "COMMENT", "REQUEST_CHANGES"):
    raise SystemExit(f"unrecognized review_action: {a!r}")
print(a)' "${REVIEW_JSON}")"; then
    echo "::error::Could not read a valid review_action from ${REVIEW_JSON}. Refusing to assume APPROVE."
    return 1
  fi
  echo "result=${result}" >>"${GITHUB_OUTPUT}"
  echo "[ai-review] result: ${result}"

  # One knob. `gate` is the severity at which the job starts failing; `off` and
  # `any` are the two ends of the same scale. true/false are accepted so the
  # boolean form keeps working.
  local gate
  gate="$(printf '%s' "${GATE:-off}" | tr '[:upper:]' '[:lower:]')"
  case "${gate}" in
    off | false | no | 0 | "") return 0 ;;
    any | all | true | 1) gate="any" ;;
    high | critical) ;;
    *)
      echo "::error::unrecognized gate '${GATE}' (expected: off | critical | high | any)."
      return 1
      ;;
  esac

  [[ "${result}" == "APPROVE" ]] && return 0

  # REQUEST_CHANGES is never emitted by the AI; if a dispatcher or a future
  # engine does emit it, treat it as a verdict rather than re-deriving one from
  # severities, and block at every gate level.
  if [[ "${gate}" == "any" || "${result}" == "REQUEST_CHANGES" ]]; then
    echo "::error::AI review result is ${result} and gate is '${gate}'."
    return 1
  fi

  # Reads the engine's own JSON, so findings that could not be anchored to a
  # diff line still count — whether a comment could be placed must not change
  # the verdict.
  local hits
  if ! hits="$(python3 -c '
import json, sys

RANK = {"LOW": 1, "MEDIUM": 2, "HIGH": 3, "CRITICAL": 4}
floor = {"high": 3, "critical": 4}[sys.argv[2]]

data = json.load(open(sys.argv[1]))
comments = data.get("comments") or []
if not isinstance(comments, list):
    raise SystemExit("comments is not a list")

blocking, unknown = [], []
for c in comments:
    if not isinstance(c, dict):
        raise SystemExit("comment entry is not an object")
    raw = str(c.get("severity", "")).strip().upper()
    rank = RANK.get(raw)
    if rank is None:
        # Never let an unreadable severity buy a pass: count it as blocking and
        # say so, rather than silently treating it as LOW.
        unknown.append(raw or "<missing>")
        blocking.append(c.get("title", "untitled"))
    elif rank >= floor:
        blocking.append(c.get("title", "untitled"))

for u in unknown:
    print(f"UNKNOWN\t{u}")
for b in blocking:
    print(f"BLOCK\t{b}")
' "${REVIEW_JSON}" "${gate}")"; then
    echo "::error::Could not evaluate finding severities in ${REVIEW_JSON}. Refusing to assume the gate passes."
    return 1
  fi

  local unknown_count blocking_count
  unknown_count="$(grep -c '^UNKNOWN' <<<"${hits}" || true)"
  blocking_count="$(grep -c '^BLOCK' <<<"${hits}" || true)"
  if [[ "${unknown_count}" -gt 0 ]]; then
    echo "::warning::${unknown_count} finding(s) carry an unrecognized severity; counting them as blocking."
  fi
  if [[ "${blocking_count}" -gt 0 ]]; then
    grep '^BLOCK' <<<"${hits}" | cut -f2- | sed 's/^/[ai-review]   /'
    echo "::error::${blocking_count} finding(s) at '${gate}' or above; failing the job."
    return 1
  fi
  echo "[ai-review] result is ${result}, but nothing reaches '${gate}'; not blocking."
}
