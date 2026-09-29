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
# skip/pr/base to $GITHUB_OUTPUT.
# Reads: PR_NUMBER_INPUT, EVENT_PR_NUMBER, BASE_REF_INPUT, EVENT_BASE_REF.
#
# Both halves of the context take an explicit input that wins over the event
# payload, and they must stay symmetric. `pr-number` alone used to be
# overridable, which made it look usable on workflow_dispatch while the base
# ref silently stayed empty — so every manual run died here instead of at the
# input it was actually missing.
ci::resolve_pr_context() {
  local pr base
  pr="${PR_NUMBER_INPUT:-${EVENT_PR_NUMBER:-}}"
  base="${BASE_REF_INPUT:-${EVENT_BASE_REF:-}}"

  # A pull_request from a fork cannot be reviewed, and saying so is better than
  # failing. GitHub withholds secrets from such a run (no model credential) and
  # issues a read-only GITHUB_TOKEN (nothing to post with); `id-token: write`
  # is unavailable too, so federating into Bedrock or Vertex does not rescue
  # it. There is no configuration that works, so the previous behaviour — the
  # engine exiting 2 with "requires ANTHROPIC_API_KEY" — put a red X on every
  # external contribution, told the contributor nothing they could act on, and
  # left the maintainer explaining a broken check.
  #
  # Only on the pull_request event: a maintainer running this by hand against a
  # fork PR (workflow_dispatch with pr-number/base-ref) DOES have secrets and a
  # write token, and must not be skipped.
  if [[ "${EVENT_NAME:-}" == "pull_request" && "${IS_FORK_PR:-false}" == "true" ]]; then
    echo "::notice::Skipping review: pull request #${pr:-?} comes from a fork. GitHub withholds secrets and issues a read-only token for fork pull requests, so the review cannot run or post. To review this PR, run the workflow manually with pr-number and base-ref (see docs/github-action.md#forked-pull-requests)."
    echo "skip=true" >>"${GITHUB_OUTPUT}"
    return 0
  fi

  if [[ -z "${pr}" ]]; then
    echo "::notice::No PR context (not a pull_request event and no pr-number given). Skipping review."
    echo "skip=true" >>"${GITHUB_OUTPUT}"
    return 0
  fi
  if [[ -z "${base}" ]]; then
    echo "::error::Could not determine the PR base ref for PR #${pr}. On a pull_request event it comes from the payload; on any other event (workflow_dispatch, schedule, issue_comment) pass it explicitly with the 'base-ref' input alongside 'pr-number' — e.g. base-ref: \${{ github.event.repository.default_branch }}, or resolve it with 'gh pr view ${pr} --json baseRefName -q .baseRefName'."
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
  # Resolved from this library's own location, not from ACTION_PATH: the repo
  # layout is fixed (workflows/_shared/lib -> repo root), and depending on a
  # caller-set variable would make the gate silently unevaluable wherever a
  # step forgot to export it.
  local verdict_py
  verdict_py="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)/engines/_common/harness/gate_verdict.py"

  # No findings file means the engine exited 0 without writing one, which only
  # happens on an empty diff. Nothing to flag, and nothing for the evaluator to
  # read.
  if [[ ! -f "${REVIEW_JSON}" ]]; then
    echo "result=APPROVE" >>"${GITHUB_OUTPUT}"
    echo "[ai-review] no findings file (empty diff); reporting APPROVE."
    return 0
  fi

  # One call does both jobs: validates and reports review_action, and decides
  # whether the review blocks. The decision lives in the engine's shared
  # evaluator so this step, the engine's own --gate and the sandbox wrapper
  # cannot drift apart on what "blocks" means.
  local out rc
  out="$(python3 "${verdict_py}" "${REVIEW_JSON}" 2>&1)"
  rc=$?
  if ((rc != 0)); then
    echo "::error::Could not read a valid verdict from ${REVIEW_JSON}: ${out}. Refusing to assume APPROVE."
    return 1
  fi

  local result
  result="$(grep '^ACTION' <<<"${out}" | cut -f2-)"
  echo "result=${result}" >>"${GITHUB_OUTPUT}"
  echo "[ai-review] result: ${result}"

  local gate
  gate="$(printf '%s' "${GATE:-false}" | tr '[:upper:]' '[:lower:]')"
  case "${gate}" in
    false | off | no | 0 | "") return 0 ;;
    true | on | yes | 1) ;;
    *)
      echo "::error::gate takes true or false (got '${GATE}'). When true the job fails on HIGH or CRITICAL findings."
      return 1
      ;;
  esac

  local unknown_count
  unknown_count="$(grep -c '^UNKNOWN' <<<"${out}" || true)"
  if [[ "${unknown_count}" -gt 0 ]]; then
    echo "::warning::${unknown_count} finding(s) carry an unrecognized severity; counting them as blocking."
  fi

  local reason
  reason="$(grep '^REASON' <<<"${out}" | cut -f2-)"
  if grep -q '^VERDICT	BLOCK' <<<"${out}"; then
    grep '^BLOCK' <<<"${out}" | cut -f2- | sed 's/^/[ai-review]   blocking: /'
    echo "::error::${reason}; failing the job."
    return 1
  fi
  echo "[ai-review] result is ${result}, but ${reason}; not blocking."
}
