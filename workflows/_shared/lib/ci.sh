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
# have the base. Reads: BASE.
ci::ensure_base_ref() {
  # BASE is an env var set by the calling step; the lowercase `base` in
  # resolve_pr_context is unrelated (SC2153 misfires on the pair).
  # shellcheck disable=SC2153
  git fetch --no-tags --depth=200 origin "${BASE}:refs/remotes/origin/${BASE}" 2>/dev/null || true
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
ci::gate_result() {
  [[ -f "${REVIEW_JSON}" ]] || return 0
  local result
  result="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["review_action"])' "${REVIEW_JSON}")"
  echo "result=${result}" >>"${GITHUB_OUTPUT}"
  echo "[ai-review] result: ${result}"
  if [[ "${GATE}" == "true" && "${result}" != "APPROVE" ]]; then
    echo "::error::AI review result is ${result} and gate is enabled."
    return 1
  fi
}
