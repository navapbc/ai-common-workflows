#!/usr/bin/env bash
# engines/_common/harness/core.sh
#
# Shared, workflow-agnostic harness runtime. Sourced by each workflow's thin
# entrypoint (engines/<workflow>/harness/*); never executed directly.
#
# Responsibilities:
#   - CLI flag parsing shared with the entrypoints
#   - AI_REVIEW_TOOL resolution (claude | codex | copilot) and invocation,
#     in two postures: read-only (the default) and suite-running
#     (AI_RUN_SUITE=1 — agentic; executes the repo's own test suite)
#   - Diff collection against a base ref (AI_REVIEW_AGAINST)
#   - Result-marker parsing (vocabulary set per workflow via
#     AI_REVIEW_MARKER_VOCAB) and JSON-block extraction (AI_REVIEW_JSON_MARKER)
#   - Adjudication (self-critique prompt block; independent second pass)
#   - Parallel fan-out for large diffs (batch planning, packing, folding)
#
# The library expects the sourcing entrypoint to have set ENGINE_HOME (the
# WORKFLOW engine's root, engines/<workflow>) and SKILL_NAME before calling
# any function. All paths resolve from ENGINE_HOME or this file's own
# location, never from the repository being reviewed — engines/ may be copied
# anywhere as a unit (action checkout, Jenkins plugin extraction, container
# image) as long as _common stays a sibling of the workflow engines.
#
# Exit codes (uniform across every workflow):
#   0  — completed; clean result, or findings in advisory (non-gate) mode
#   1  — gate failure or unrecoverable runtime error
#   2  — configuration error (bad flags; AI_REVIEW_TOOL unset/invalid)
#
# shellcheck disable=SC2034  # AI_REVIEW_* globals are this library's public
# interface, consumed by the sourcing entrypoint rather than in this file.

set -euo pipefail

# ── Library guard ───────────────────────────────────────────────────────────
if [[ "${_AI_REVIEW_CORE_LOADED:-0}" == "1" ]]; then
  return 0
fi
_AI_REVIEW_CORE_LOADED=1

# ── Per-workflow parameterization ───────────────────────────────────────────
# Each entrypoint sets these before (or instead of) relying on the defaults,
# which preserve the security-compliance-review contract.
#   AI_REVIEW_MARKER_VOCAB  result-marker vocabulary (regex alternation)
#   AI_REVIEW_JSON_MARKER   HTML-comment marker prefix around the JSON block
#   AI_RUN_SUITE            0 (default) read-only posture; 1 = agentic posture
#                           that installs deps and RUNS the repo's test suite
AI_REVIEW_MARKER_VOCAB="${AI_REVIEW_MARKER_VOCAB:-APPROVE|COMMENT|REQUEST_CHANGES}"
AI_REVIEW_JSON_MARKER="${AI_REVIEW_JSON_MARKER:-AI_REVIEW_JSON}"
AI_RUN_SUITE="${AI_RUN_SUITE:-0}"

# Bounds for the agent loop in suite mode (AI_RUN_SUITE=1). The timeout wraps
# the whole CLI call; --max-turns caps agentic iterations. Overflow is a soft
# outcome (see ai_review::is_max_turns), not a hard failure.
AI_SUITE_TIMEOUT_SECS="${AI_SUITE_TIMEOUT_SECS:-1500}" # 25 min hard ceiling
AI_SUITE_MAX_TURNS="${AI_SUITE_MAX_TURNS:-80}"

# ── Color helpers (suppressed in CI / non-TTY) ──────────────────────────────
if [[ -t 2 ]] && [[ "${CI:-}" != "true" ]] && [[ "${NO_COLOR:-}" == "" ]]; then
  AI_C_RED=$'\033[0;31m'
  AI_C_YELLOW=$'\033[1;33m'
  AI_C_GREEN=$'\033[0;32m'
  AI_C_BLUE=$'\033[0;34m'
  AI_C_BOLD=$'\033[1m'
  AI_C_RESET=$'\033[0m'
else
  AI_C_RED=""
  AI_C_YELLOW=""
  AI_C_GREEN=""
  AI_C_BLUE=""
  AI_C_BOLD=""
  AI_C_RESET=""
fi

# ── Logging helpers ─────────────────────────────────────────────────────────
# All status/progress output goes to stderr: stdout is reserved for the
# review artifacts themselves (the human report and the findings JSON), so
# `--json-only` output and shell pipelines stay clean.
ai_review::log() { printf '%s\n' "$*" >&2; }
ai_review::info() { printf '%s[%s]%s %s\n' "${AI_C_BOLD}" "${SKILL_NAME}" "${AI_C_RESET}" "$*" >&2; }
ai_review::ok() { printf '%s[%s] %s%s\n' "${AI_C_GREEN}" "${SKILL_NAME}" "$*" "${AI_C_RESET}" >&2; }
ai_review::warn() { printf '%s[%s] %s%s\n' "${AI_C_YELLOW}" "${SKILL_NAME}" "$*" "${AI_C_RESET}" >&2; }
ai_review::err() { printf '%s[%s] ERROR: %s%s\n' "${AI_C_RED}" "${SKILL_NAME}" "$*" "${AI_C_RESET}" >&2; }

# ── CLI flag parsing ────────────────────────────────────────────────────────
# Sets:
#   AI_REVIEW_DRY_RUN       ("1" or "0") — print what would happen, do not call AI
#   AI_REVIEW_NO_BLOCK      ("1" or "0") — run review but always exit 0 (also
#                                          neutralizes --gate)
#   AI_REVIEW_NO_ADJUDICATE ("1" or "0") — force adjudication off
#   AI_REVIEW_AGAINST       (string)     — git base ref to diff against (required)
#   AI_REVIEW_JOBS          (int)        — concurrent workers (1 = serial; default 4)
#   AI_REVIEW_LIST_BATCHES  ("1" or "0") — print the batch plan and exit
#   AI_REVIEW_INCLUDE_STAGED ("1"/"0")   — diff base→index (committed + staged)
#                                          instead of base→HEAD; set by --unpushed
#   AI_REVIEW_REMAINING     (array)      — any unparsed args

# ── Base resolution for --unpushed ──────────────────────────────────────────
# Resolves the "last pushed" point so --unpushed can cover everything not yet
# pushed (committed + staged). Order: the branch's upstream; else the merge-base
# with the remote default branch. Prints the base ref; non-zero if none found.
ai_review::resolve_unpushed_base() {
  local base def
  base="$(git rev-parse --abbrev-ref --symbolic-full-name '@{upstream}' 2>/dev/null || true)"
  if [[ -z "${base}" ]]; then
    # `git rev-parse --abbrev-ref origin/HEAD` echoes the literal "origin/HEAD"
    # when the symref is unset — use symbolic-ref, which fails cleanly.
    def="$(git symbolic-ref --short -q refs/remotes/origin/HEAD 2>/dev/null || true)"
    if [[ -z "${def}" ]] && git rev-parse --verify --quiet origin/main >/dev/null 2>&1; then
      def="origin/main"
    fi
    if [[ -z "${def}" ]] && git rev-parse --verify --quiet origin/master >/dev/null 2>&1; then
      def="origin/master"
    fi
    [[ -n "${def}" ]] && base="$(git merge-base HEAD "${def}" 2>/dev/null || true)"
  fi
  [[ -n "${base}" ]] || return 1
  printf '%s' "${base}"
}

ai_review::parse_args() {
  AI_REVIEW_DRY_RUN=0
  AI_REVIEW_NO_BLOCK=0
  AI_REVIEW_NO_ADJUDICATE=0
  AI_REVIEW_AGAINST="${AI_REVIEW_AGAINST:-}"
  AI_REVIEW_LIST_BATCHES=0
  AI_REVIEW_INCLUDE_STAGED=0
  # Concurrency: env default (validated below), overridable by --jobs.
  AI_REVIEW_JOBS="${AI_REVIEW_JOBS:-4}"
  AI_REVIEW_REMAINING=()

  while [[ $# -gt 0 ]]; do
    case "$1" in
      -n | --dry-run)
        AI_REVIEW_DRY_RUN=1
        shift
        ;;
      --no-block)
        AI_REVIEW_NO_BLOCK=1
        shift
        ;;
      --no-adjudicate)
        AI_REVIEW_NO_ADJUDICATE=1
        shift
        ;;
      --against)
        if [[ -z "${2:-}" ]]; then
          ai_review::err "--against requires a git ref argument"
          exit 2
        fi
        AI_REVIEW_AGAINST="$2"
        shift 2
        ;;
      --against=*)
        AI_REVIEW_AGAINST="${1#*=}"
        shift
        ;;
      --unpushed)
        # Cover everything not yet pushed: committed + staged (base→index).
        if ! AI_REVIEW_AGAINST="$(ai_review::resolve_unpushed_base)"; then
          ai_review::err "--unpushed: couldn't determine what's been pushed (no upstream and no remote default branch)."
          ai_review::log "  Re-run with an explicit base, e.g.  --against main"
          exit 2
        fi
        AI_REVIEW_INCLUDE_STAGED=1
        shift
        ;;
      --jobs)
        AI_REVIEW_JOBS="${2:-}"
        shift 2
        ;;
      --jobs=*)
        AI_REVIEW_JOBS="${1#*=}"
        shift
        ;;
      --list-batches)
        AI_REVIEW_LIST_BATCHES=1
        shift
        ;;
      -h | --help)
        ai_review::print_help
        exit 0
        ;;
      --)
        shift
        AI_REVIEW_REMAINING+=("$@")
        break
        ;;
      *)
        AI_REVIEW_REMAINING+=("$1")
        shift
        ;;
    esac
  done

  # Validate JOBS now that flag/env are resolved.
  if ! [[ "${AI_REVIEW_JOBS}" =~ ^[0-9]+$ ]] || ((AI_REVIEW_JOBS < 1)); then
    ai_review::err "--jobs / AI_REVIEW_JOBS must be a positive integer (got '${AI_REVIEW_JOBS}')."
    exit 2
  fi

  ai_review::resolve_diff_base
}

# ── Diff base resolution (three-dot / merge-base semantics) ─────────────────
# A pull request's diff is BASE...HEAD — what this branch changed since it
# diverged — not BASE..HEAD. The two-dot form additionally reports, INVERTED,
# every commit landed on BASE since the branch forked. On a branch whose base
# has moved (the common case) that means other people's work is attributed to
# this change: files the PR never touched show up as deletions, they get
# batched and reviewed at full token cost, findings on them flip review_action
# to COMMENT, and --gate fails the build on somebody else's commit.
#
# Resolving BASE to its merge base with HEAD and keeping the two-dot form makes
# `git diff <merge-base> HEAD` exactly equivalent to `git diff BASE...HEAD`. We
# rewrite AI_REVIEW_AGAINST in place so every consumer is corrected at once —
# these helpers, the classifier's own AI_REVIEW_DIFF_RANGE, the fan-out
# workers that inherit it, and the literal `git diff "$AI_REVIEW_AGAINST" HEAD`
# the skill instructions tell the model to run. The original ref is kept in
# AI_REVIEW_AGAINST_REF for human-readable output.
#
# A shallow clone may not contain the common ancestor; then we warn and keep
# the two-dot behavior rather than failing the review.
ai_review::resolve_diff_base() {
  [[ -n "${AI_REVIEW_AGAINST:-}" ]] || return 0
  AI_REVIEW_AGAINST_REF="${AI_REVIEW_AGAINST_REF:-${AI_REVIEW_AGAINST}}"
  # A nonexistent ref is not diagnosed here — require_against reports it with
  # better guidance, and warning about a merge base first would mislead.
  git rev-parse --verify --quiet "${AI_REVIEW_AGAINST}^{commit}" >/dev/null || return 0
  local mb
  if mb="$(git merge-base "${AI_REVIEW_AGAINST}" HEAD 2>/dev/null)" && [[ -n "${mb}" ]]; then
    AI_REVIEW_AGAINST="${mb}"
  else
    ai_review::warn "No merge base found with '${AI_REVIEW_AGAINST_REF}' (shallow clone?). Falling back to a direct ${AI_REVIEW_AGAINST_REF}→HEAD diff, which can attribute commits made on ${AI_REVIEW_AGAINST_REF} since this branch diverged to this change. Check out with 'fetch-depth: 0' for an exact PR diff."
  fi
  export AI_REVIEW_AGAINST AI_REVIEW_AGAINST_REF
}

# Generic fallback help. Each workflow entrypoint overrides this function
# (defined after sourcing, so the override wins) with its full reference text.
ai_review::print_help() {
  cat <<EOF
${SKILL_HUMAN_NAME:-AI workflow}

Shared options (see the workflow's engine README for the full reference):
  --against <ref>      Base ref to diff against (e.g. origin/main).
  --unpushed           Diff committed + staged work against the last push.
  -n, --dry-run        Print the resolved tool and plan; no AI call.
  --no-block           Always exit 0 regardless of findings or gate mode.
  --jobs <N>           Concurrent fan-out workers (default 4). 1 = serial.
  --list-batches       Print how the diff would be batched; no AI call.
  --no-adjudicate      Disable adjudication (same as AI_ADJUDICATION=off).
  -h, --help           Show this help and exit.

Environment: AI_REVIEW_TOOL (claude | codex | copilot) is required;
AI_REVIEW_PROVIDER selects api (default) | bedrock | vertex | azure.
EOF
}

# ── AI_REVIEW_TOOL validation ───────────────────────────────────────────────
# Resolves the tool name into AI_REVIEW_TOOL_RESOLVED (lower-cased, validated).
ai_review::resolve_tool() {
  if [[ -z "${AI_REVIEW_TOOL:-}" ]]; then
    ai_review::err "AI_REVIEW_TOOL environment variable is not set."
    ai_review::log ""
    ai_review::log "  This variable selects which AI coding assistant runs the review."
    ai_review::log "  It must be set to exactly one of:  claude  |  codex  |  copilot"
    ai_review::log ""
    ai_review::log "  GitHub Actions: set the 'ai-tool' input on the action."
    ai_review::log "  Jenkins:        set the 'tool' step parameter or the global default."
    exit 2
  fi

  local raw="${AI_REVIEW_TOOL}"
  local lower
  lower="$(printf '%s' "${raw}" | tr '[:upper:]' '[:lower:]')"

  case "${lower}" in
    claude | codex | copilot)
      AI_REVIEW_TOOL_RESOLVED="${lower}"
      ;;
    *)
      ai_review::err "AI_REVIEW_TOOL='${raw}' is not a recognized value."
      ai_review::log "  Valid values: claude | codex | copilot"
      exit 2
      ;;
  esac

  ai_review::info "AI tool resolved: ${AI_C_BLUE}${AI_REVIEW_TOOL_RESOLVED}${AI_C_RESET}"
}

# ── CLI presence checks ─────────────────────────────────────────────────────
ai_review::require_cli() {
  local tool="$1"
  local install_hint="$2"

  if ! command -v "${tool}" &>/dev/null; then
    ai_review::err "'${tool}' CLI not found on PATH."
    ai_review::log "  ${install_hint}"
    exit 1
  fi
}

# ── Diff collection ─────────────────────────────────────────────────────────
# The PR engine always diffs a base ref against HEAD. AI_REVIEW_AGAINST must
# be set (by --against, PR discovery, or the environment) before these run.
ai_review::require_against() {
  if [[ -z "${AI_REVIEW_AGAINST:-}" ]]; then
    ai_review::err "No base ref to diff against."
    ai_review::log "  Provide one with --against <ref> (e.g. --against origin/main)"
    ai_review::log "  or a PR number with --pr <number> so the base can be looked up."
    exit 2
  fi
  if ! git rev-parse --verify --quiet "${AI_REVIEW_AGAINST}^{commit}" >/dev/null; then
    ai_review::err "Git ref not found: ${AI_REVIEW_AGAINST}"
    ai_review::log "  Fetch it first, e.g.:  git fetch origin '<branch>:refs/remotes/origin/<branch>'"
    exit 1
  fi
}

# has_changes/changed_files support three postures: base→HEAD (the default),
# base→index under --unpushed (AI_REVIEW_INCLUDE_STAGED=1), and the staged
# diff when no base is set at all (local, no-PR use). Entrypoints that require
# a base (the PR review) call ai_review::require_against first.
ai_review::has_changes() {
  # The negated `git diff --quiet` IS the function's return value.
  # shellcheck disable=SC2251
  if [[ -n "${AI_REVIEW_AGAINST:-}" ]]; then
    if ! git rev-parse --verify --quiet "${AI_REVIEW_AGAINST}^{commit}" >/dev/null; then
      ai_review::err "Git ref not found: ${AI_REVIEW_AGAINST}"
      exit 1
    fi
    if [[ "${AI_REVIEW_INCLUDE_STAGED:-0}" == "1" ]]; then
      ! git diff --cached --quiet "${AI_REVIEW_AGAINST}" --
    else
      ! git diff --quiet "${AI_REVIEW_AGAINST}" HEAD --
    fi
  else
    ! git diff --cached --quiet
  fi
}

ai_review::changed_files() {
  if [[ -n "${AI_REVIEW_AGAINST:-}" ]]; then
    if [[ "${AI_REVIEW_INCLUDE_STAGED:-0}" == "1" ]]; then
      git diff --cached --name-only "${AI_REVIEW_AGAINST}" --
    else
      git diff --name-only "${AI_REVIEW_AGAINST}" HEAD --
    fi
  else
    git diff --cached --name-only
  fi
}

ai_review::diff_command_description() {
  if [[ -n "${AI_REVIEW_AGAINST:-}" ]]; then
    # Name the ref the user asked for; note the merge base it resolved to so
    # the three-dot equivalence is visible in the log.
    local ref="${AI_REVIEW_AGAINST_REF:-${AI_REVIEW_AGAINST}}" via=""
    [[ "${AI_REVIEW_AGAINST}" != "${ref}" ]] &&
      via=" [merge-base ${AI_REVIEW_AGAINST:0:12}, i.e. ${ref}...HEAD]"
    if [[ "${AI_REVIEW_INCLUDE_STAGED:-0}" == "1" ]]; then
      echo "git diff --cached ${ref}${via} (committed + staged, unpushed)"
    else
      echo "git diff ${ref} HEAD${via}"
    fi
  else
    echo "git diff --cached"
  fi
}

# ai_review::diff_has_iac
# Returns 0 when the diff (or the batch scope, when AI_REVIEW_SCOPE_PATHS is
# set) contains at least one IaC file. Drives whether the iac-compliance
# perspective is inlined into the prompt. The filename patterns mirror the
# "Recognised IaC file patterns" list in the skill instructions; YAML files
# additionally count when their content carries Kubernetes apiVersion+kind.
ai_review::diff_has_iac() {
  local files f
  if [[ -n "${AI_REVIEW_SCOPE_PATHS:-}" ]]; then
    files="${AI_REVIEW_SCOPE_PATHS}"
  else
    files="$(ai_review::changed_files)"
  fi
  while IFS= read -r f; do
    [[ -z "${f}" ]] && continue
    case "${f}" in
      *.tf | *.tfvars | *.tf.json | *.bicep | *.bicepparam | *.hcl | \
        *.template.json | *.template.yaml | *.template.yml | \
        */Pulumi.yaml | Pulumi.yaml | */Chart.yaml | Chart.yaml | \
        */values.yaml | values.yaml | */cdk.json | cdk.json | \
        */kustomization.yaml | kustomization.yaml)
        return 0
        ;;
      *.yaml | *.yml)
        # Kubernetes manifests: YAML with both apiVersion: and kind:.
        if [[ -f "${f}" ]] && grep -q '^apiVersion:' "${f}" 2>/dev/null &&
          grep -q '^kind:' "${f}" 2>/dev/null; then
          return 0
        fi
        ;;
    esac
  done <<<"${files}"
  return 1
}

# ── Suite-mode plumbing (AI_RUN_SUITE=1 only) ───────────────────────────────
# Prefix the CLI call with `timeout` only in suite mode AND when a timeout
# binary is present (GNU coreutils, or gtimeout on macOS). In read-only mode
# we add no wrapper — there is no long-running shell loop to bound.
ai_review::timeout_prefix() {
  if ((AI_RUN_SUITE != 1)); then
    return 0
  fi
  if command -v timeout &>/dev/null; then
    printf 'timeout %s' "${AI_SUITE_TIMEOUT_SECS}"
  elif command -v gtimeout &>/dev/null; then
    printf 'gtimeout %s' "${AI_SUITE_TIMEOUT_SECS}"
  fi
}

# Live progress streaming (local interactive suite runs only). We test STDERR
# (-t 2), not stdout: invoke_ai's stdout is captured via $(...), so inside
# ai_review::in_ci — is this an automated pipeline rather than someone's machine?
#
# Deliberately broad: any of these being set means "not a laptop", and the one
# caller that matters uses it to REFUSE something, so a false positive costs a
# clearer error message while a false negative costs a boundary violation.
# GitHub Actions sets CI and GITHUB_ACTIONS; Jenkins does not reliably set CI,
# but always sets JENKINS_URL and BUILD_ID.
ai_review::in_ci() {
  [[ -n "${CI:-}" ]] && return 0
  [[ -n "${GITHUB_ACTIONS:-}" ]] && return 0
  [[ -n "${JENKINS_URL:-}" ]] && return 0
  [[ -n "${BUILD_ID:-}" ]] && return 0
  return 1
}

# these functions stdout is always a pipe; stderr flowing to a terminal is the
# "a human is watching" signal, and stderr is where the narration goes.
ai_review::should_stream() {
  [[ "${AI_REVIEW_STREAM:-1}" != "0" ]] || return 1
  [[ -t 2 ]] || return 1
  [[ "${CI:-}" != "true" ]] || return 1
  command -v python3 &>/dev/null || return 1
  return 0
}

# Reads claude stream-json (NDJSON) on stdin. Narrates assistant text + tool
# calls to STDERR; prints ONLY the final result text to STDOUT so the captured
# output (markers + JSON) is byte-identical to the non-streaming path.
ai_review::stream_split() {
  python3 -c '
import sys, json
def w(s):  # progress → stderr, flushed so it appears live
    sys.stderr.write(s + "\n"); sys.stderr.flush()
final = ""
for line in sys.stdin:
    line = line.strip()
    if not line:
        continue
    try:
        e = json.loads(line)
    except Exception:
        continue
    t = e.get("type")
    if t == "assistant":
        for blk in e.get("message", {}).get("content", []):
            bt = blk.get("type")
            if bt == "text":
                txt = (blk.get("text") or "").strip()
                if txt:
                    w("  ⏺ " + txt)
            elif bt == "tool_use":
                inp = blk.get("input", {}) or {}
                arg = inp.get("command") or inp.get("file_path") or inp.get("pattern") or inp.get("description") or ""
                arg = str(arg).replace("\n", " ")
                if len(arg) > 80:
                    arg = arg[:77] + "..."
                w("  ⏎ " + str(blk.get("name")) + ("  " + arg if arg else ""))
    elif t == "result":
        final = e.get("result") or ""
sys.stdout.write(final)
'
}

# Reads `codex exec --json` JSONL events on stdin. Same contract as
# stream_split: narrate to STDERR, emit ONLY the final agent message to STDOUT.
ai_review::codex_stream_split() {
  python3 -c '
import sys, json
def w(s):
    sys.stderr.write(s + "\n"); sys.stderr.flush()
final = ""
for line in sys.stdin:
    line = line.strip()
    if not line:
        continue
    try:
        e = json.loads(line)
    except Exception:
        continue
    item = e.get("item") or e
    it = item.get("item_type") or item.get("type") or e.get("type") or ""
    if it in ("agent_message", "assistant_message", "message"):
        txt = (item.get("text") or item.get("message") or "").strip()
        if txt:
            w("  ⏺ " + (txt if len(txt) <= 200 else txt[:197] + "..."))
            final = txt
    elif it == "reasoning":
        txt = (item.get("text") or "").strip()
        if txt:
            w("  ⏺ " + (txt if len(txt) <= 200 else txt[:197] + "..."))
    elif it in ("command_execution", "command", "exec"):
        cmd = (item.get("command") or item.get("cmd") or "").replace("\n", " ")
        if len(cmd) > 80:
            cmd = cmd[:77] + "..."
        if cmd:
            w("  ⏎ command  " + cmd)
    elif it == "file_change":
        path = item.get("path") or item.get("file") or ""
        if path:
            w("  ⏎ file_change  " + str(path))
sys.stdout.write(final)
'
}

# Turn-budget overflow detection (suite mode). When the agent exhausts
# --max-turns it exits non-zero with a recognizable banner instead of a
# marker; callers degrade that to a non-blocking soft outcome.
ai_review::is_max_turns() {
  local output="$1"
  grep -qiE 'reached max turns|max[ _-]?turns|turn limit' <<<"${output}"
}

# ── Tool-specific invocation ────────────────────────────────────────────────
# ai_review::invoke_tool <prompt> [model]
# Invokes the resolved AI CLI in non-interactive mode with the given prompt,
# printing the raw response to stdout. When [model] is non-empty it is passed
# to the CLI's model-selection flag. Any non-zero CLI exit propagates.
#
# Two postures, selected by AI_RUN_SUITE:
#   0 (default)  read-only: explicit permission flags scoped to inspection +
#                git diff/log/show. The PR-review posture.
#   1            suite mode: the agent may install dependencies and RUN the
#                repo's test suite — write grants, a turn budget, a hard
#                timeout, and (on local interactive runs) live streaming.
ai_review::invoke_tool() {
  local prompt="$1"
  local model="${2:-}"
  local stream="${AI_REVIEW_DO_STREAM:-0}"

  case "${AI_REVIEW_TOOL_RESOLVED}" in
    claude)
      ai_review::require_cli "claude" \
        "Install Claude Code:  npm install -g @anthropic-ai/claude-code"
      if ((AI_RUN_SUITE == 1)); then
        # Headless `claude -p` HANGS on any Bash call without a permission
        # grant, so suite mode requires these flags. --allowedTools scopes the
        # grant; --max-turns bounds the loop. No 2>&1: stderr diagnostics must
        # not corrupt the parsed stdout.
        if ((stream == 1)); then
          # < /dev/null: `-p` otherwise waits on stdin (the pipe keeps it open).
          $(ai_review::timeout_prefix) claude -p "${prompt}" \
            ${model:+--model "${model}"} \
            --permission-mode bypassPermissions \
            --allowedTools "Bash,Read,Edit,Grep,Glob,Task,Agent" \
            --max-turns "${AI_SUITE_MAX_TURNS}" \
            --output-format stream-json --verbose </dev/null |
            ai_review::stream_split
        else
          $(ai_review::timeout_prefix) claude -p "${prompt}" \
            ${model:+--model "${model}"} \
            --permission-mode bypassPermissions \
            --allowedTools "Bash,Read,Edit,Grep,Glob,Task,Agent" \
            --max-turns "${AI_SUITE_MAX_TURNS}"
        fi
      else
        # -p = non-interactive (print) mode. --allowed-tools grants read-only
        # inspection plus the git commands the skill instructions rely on;
        # nothing else (no writes, no network tools, no gh).
        claude -p "${prompt}" \
          ${model:+--model "${model}"} \
          --allowed-tools "Read Grep Glob Bash(git diff:*) Bash(git log:*) Bash(git show:*)" \
          2>&1
      fi
      ;;
    codex)
      ai_review::require_cli "codex" \
        "Install OpenAI Codex CLI:  npm install -g @openai/codex"
      # provider=bedrock selects codex's built-in amazon-bedrock provider via
      # -c config overrides (AWS-cred auth, direct to Bedrock, no gateway).
      local codex_cfg=()
      if [[ "${AI_REVIEW_CODEX_MODEL_PROVIDER:-}" == "amazon-bedrock" ]]; then
        codex_cfg+=(-c 'model_provider=amazon-bedrock')
        [[ -n "${AWS_REGION:-}" ]] &&
          codex_cfg+=(-c "model_providers.amazon-bedrock.aws.region=${AWS_REGION}")
      fi
      if ((AI_RUN_SUITE == 1)); then
        # workspace-write allows file writes but not network by default, so
        # dep installs fail without the explicit network grant.
        codex_cfg+=(-c sandbox_workspace_write.network_access=true)
        if ((stream == 1)); then
          $(ai_review::timeout_prefix) codex exec --json --sandbox workspace-write \
            "${codex_cfg[@]+"${codex_cfg[@]}"}" \
            ${model:+--model "${model}"} \
            --skip-git-repo-check "${prompt}" |
            ai_review::codex_stream_split
        else
          $(ai_review::timeout_prefix) codex exec --sandbox workspace-write \
            "${codex_cfg[@]+"${codex_cfg[@]}"}" \
            ${model:+--model "${model}"} \
            --skip-git-repo-check "${prompt}" 2>&1
        fi
      else
        # --sandbox read-only = filesystem read access (git diff / file reads)
        # with no write/network side effects.
        codex exec --sandbox read-only --skip-git-repo-check \
          "${codex_cfg[@]+"${codex_cfg[@]}"}" \
          ${model:+--model "${model}"} \
          "${prompt}" 2>&1
      fi
      ;;
    copilot)
      ai_review::require_cli "copilot" \
        "Install GitHub Copilot CLI:  npm install -g @github/copilot"
      if ((AI_RUN_SUITE == 1)); then
        # --allow-all-tools lets it run install/test commands headlessly; -s
        # suppresses stats for clean scriptable output. Copilot has no
        # turn/timeout cap of its own, so the timeout wrapper is the bound.
        # No structured event output exists for -p mode, so streaming uses the
        # supported preToolUse hook under a throwaway COPILOT_HOME.
        if ((stream == 1)); then
          local cphome
          cphome="$(mktemp -d "${TMPDIR:-/tmp}/ai-copilot-home.XXXXXX")"
          mkdir -p "${cphome}/hooks"
          cat >"${cphome}/hooks/stream.sh" <<'HOOK'
#!/usr/bin/env bash
# preToolUse hook: narrate the call payload to stderr; return {} unchanged.
payload="$(cat)"
python3 -c '
import sys, json
try:
    e = json.loads(sys.argv[1] or "{}")
    name = e.get("toolName") or "tool"
    args = e.get("toolArgs") or ""
    if not isinstance(args, str):
        args = json.dumps(args)
    args = args.replace("\n", " ")
    if len(args) > 80:
        args = args[:77] + "..."
    sys.stderr.write("  ⏎ " + str(name) + (("  " + args) if args else "") + "\n")
    sys.stderr.flush()
except Exception:
    pass
' "$payload" || true
printf '{}'
HOOK
          chmod +x "${cphome}/hooks/stream.sh"
          cat >"${cphome}/hooks/hooks.json" <<HOOKCFG
{
  "preToolUse": [
    { "type": "command", "bash": "${cphome}/hooks/stream.sh", "timeoutSec": 10 }
  ]
}
HOOKCFG
          local rc=0
          COPILOT_HOME="${cphome}" $(ai_review::timeout_prefix) \
            copilot -p "${prompt}" --allow-all-tools \
            ${model:+--model "${model}"} -s || rc=$?
          rm -rf "${cphome}"
          return $rc
        else
          $(ai_review::timeout_prefix) copilot -p "${prompt}" --allow-all-tools \
            ${model:+--model "${model}"} -s 2>&1
        fi
      else
        # copilot -p = non-interactive single-prompt mode. Tool-permission
        # flags vary across copilot CLI releases; the skill instructions only
        # require read access and git diff, which the default posture allows.
        copilot -p "${prompt}" \
          ${model:+--model "${model}"} \
          2>&1
      fi
      ;;
    *)
      ai_review::err "Internal error: unknown resolved tool '${AI_REVIEW_TOOL_RESOLVED}'"
      exit 1
      ;;
  esac
}

# First-pass invocation: the configured tool, the AI_REVIEW_MODEL override (if
# any), the dispatcher's SKILL_PROMPT. In suite mode this also decides
# streaming (BEFORE exporting CI, which should_stream gates on) and exports
# CI=true so the repo's own test runners do a single headless non-watch run.
# Safe: callers capture via $(...), a subshell, so the export never escapes.
ai_review::invoke_ai() {
  if ((AI_RUN_SUITE == 1)); then
    if ai_review::should_stream; then
      AI_REVIEW_DO_STREAM=1
      ai_review::info "Streaming the agent's steps below (set AI_REVIEW_STREAM=0 to silence)…"
    else
      AI_REVIEW_DO_STREAM=0
    fi
    export CI=true
  fi
  ai_review::invoke_tool "${SKILL_PROMPT}" "${AI_REVIEW_MODEL:-}"
}

# ── Result marker parsing ───────────────────────────────────────────────────
# The canonical marker is:  <<<AI_REVIEW_RESULT:<word>>>>  where <word> is one
# of the workflow's AI_REVIEW_MARKER_VOCAB alternation. The AI emits its
# verdict as the LAST marker in its response. We must take the last
# occurrence, not the first match, because the captured output can contain
# earlier *echoes* of the marker list: the prompt itself shows the markers, and
# CLIs that stream the full agent transcript (e.g. `codex exec`) replay them.
# A naive first-match grep would read the instructions, not the verdict.
ai_review::parse_result() {
  local output="$1"
  local marker
  marker="$(grep -oE "<<<AI_REVIEW_RESULT:(${AI_REVIEW_MARKER_VOCAB})>>>" <<<"${output}" | tail -n 1)"

  if [[ -n "${marker}" ]]; then
    marker="${marker#<<<AI_REVIEW_RESULT:}"
    printf '%s\n' "${marker%>>>}"
  else
    echo "UNPARSEABLE"
  fi
}

# Pull the JSON block between <!-- ${AI_REVIEW_JSON_MARKER}_BEGIN/END -->
# markers out of the given text.
#
# We deliberately return only the LAST closed marker pair. Some CLIs (notably
# `codex exec`, whose stdout we capture via 2>&1) echo the dispatcher's own
# instructions back in their output — and those instructions contain a literal
# example of the markers wrapping a placeholder line. A naive "print every
# captured line" would concatenate that placeholder with the real JSON, and
# the placeholder lands first, so the JSON parser dies on it. The real JSON is
# always emitted last (after the human report), so the last fully-closed block
# is the authoritative one.
ai_review::extract_review_json() {
  local input="$1"
  echo "${input}" | awk -v m="${AI_REVIEW_JSON_MARKER}" '
    index($0, "<!-- " m "_BEGIN -->") { capturing=1; block=""; next }
    index($0, "<!-- " m "_END -->")   { if (capturing) { last=block; have=1 } capturing=0; next }
    capturing                         { block = block $0 "\n" }
    END                               { if (have) printf "%s", last }
  '
}

# ── Rubric composition (profiles) ───────────────────────────────────────────
# AI_REVIEW_PROFILE is an ordered, comma-separated list of rubric sources. The
# shared base is an explicit member of that list, not an implicit extra:
#
#   base                       the framework-neutral floor, alone
#   base,cms-ars               floor + CMS additions
#   base,cms-ars,pci-dss       floor + CMS + PCI; PCI wins a conflict
#   none,my-agency-everything  NO floor — the program supplies the whole rubric
#
# Sources layer in list order and each is told it outranks everything above it,
# so the LAST entry wins a genuine conflict.
#
# Why base is listed rather than always-on: a program that needs full control
# used to reach for a per-file override, which was invisible and forced it to
# copy ~20KB of rubric it then maintained forever. Declaring `none` is the same
# capability, visible in the config.
#
# Why `none` is required rather than inferred from base's absence: omitting the
# floor by accident is a silent, severe failure — the review still runs, still
# posts, still reports a verdict, and checked almost nothing. `profile: cms-ars`
# is a natural thing to type, so it must be an error rather than a quiet
# downgrade. The first entry has to be `base` or `none`; there is no way to
# type your way into dropping the floor.
#
# finding-adjudication.md is deliberately OUTSIDE this mechanism: it governs how
# findings are judged, not what is looked for, so `none` must not cost a program
# its false-positive filter. ai_review::build_adjudication_prompt reads it from
# skills/base/ directly.

# ai_review::resolve_profiles
# Publishes AI_REVIEW_RUBRIC_DIRS (newline-separated, in order) — the resolved
# sources, with the base directory included when `base` was listed. Exits 2 on
# a malformed list.
ai_review::resolve_profiles() {
  local raw="${AI_REVIEW_PROFILE:-base}"
  local dirs="" name resolved first=1 saw_base=0 saw_none=0
  local oldifs="${IFS}"
  IFS=','
  # shellcheck disable=SC2086  # deliberate split on the comma list
  set -- ${raw}
  IFS="${oldifs}"

  for name in "$@"; do
    name="${name#"${name%%[![:space:]]*}"}"
    name="${name%"${name##*[![:space:]]}"}"
    [[ -z "${name}" ]] && continue

    case "${name}" in
      base)
        if ((first == 0)); then
          ai_review::err "'base' must be the FIRST entry in AI_REVIEW_PROFILE (got '${raw}')."
          ai_review::err "  Listed later, the floor would outrank the overlays layered before it,"
          ai_review::err "  which is never what is meant. Use: base,<profile>[,<profile>...]"
          exit 2
        fi
        saw_base=1
        dirs="${dirs}${ENGINE_HOME}/skills/base"$'\n'
        first=0
        continue
        ;;
      none)
        if ((first == 0)); then
          ai_review::err "'none' must be the FIRST entry in AI_REVIEW_PROFILE (got '${raw}')."
          exit 2
        fi
        saw_none=1
        first=0
        continue
        ;;
    esac

    if [[ -d "${name}" ]]; then
      resolved="$(cd "${name}" && pwd)"
    elif [[ -d "${ENGINE_HOME}/skills/profiles/${name}" ]]; then
      resolved="${ENGINE_HOME}/skills/profiles/${name}"
    else
      ai_review::err "profile '${name}' is not a known profile or an existing directory."
      ai_review::log "  Bundled profiles: $(find "${ENGINE_HOME}/skills/profiles" -mindepth 1 -maxdepth 1 -type d -exec basename {} \; | sort | tr '\n' ' ')"
      ai_review::log "  Or pass a path to a custom profile directory."
      exit 2
    fi
    dirs="${dirs}${resolved}"$'\n'
    first=0
  done

  if ((saw_base == 0 && saw_none == 0)); then
    ai_review::err "AI_REVIEW_PROFILE must start with 'base' or 'none' (got '${raw}')."
    ai_review::err "  base,<profile>...  the shared rubric floor plus your additions (what you want)"
    ai_review::err "  none,<profile>...  NO floor; your profile supplies the entire rubric"
    ai_review::err "  Requiring the choice keeps the floor from being dropped by accident."
    exit 2
  fi
  if [[ -z "${dirs}" ]]; then
    ai_review::err "AI_REVIEW_PROFILE='${raw}' resolved to no rubric sources at all."
    ai_review::err "  'none' alone supplies nothing to review against; list a profile after it."
    exit 2
  fi

  AI_REVIEW_RUBRIC_DIRS="${dirs}"
  export AI_REVIEW_RUBRIC_DIRS
}

# ai_review::rubric_block <rubric_filename> <section_label>
# Emits the composed body for one rubric section: the first source that
# supplies the file verbatim, then each later source as an addition that
# outranks everything above it. Prints nothing when no source supplies it —
# ai_review::require_rubric is how a caller turns that into an error for a file
# it cannot run without.
ai_review::rubric_block() {
  local file="$1" label="$2"
  local dir name emitted=0
  while IFS= read -r dir; do
    [[ -z "${dir}" ]] && continue
    [[ -f "${dir}/${file}" ]] || continue
    if ((emitted == 0)); then
      cat "${dir}/${file}"
      emitted=1
      continue
    fi
    name="$(basename "${dir}")"
    cat <<ADDITION

──────────── ${label} — ${name} ADDITIONS ────────────
The following supplements the ${label} above for the '${name}' profile. It
ADDS to everything above it and never replaces it. On any conflict with
anything above — severity, citation, guidance — this section takes precedence.

$(cat "${dir}/${file}")
ADDITION
  done <<<"${AI_REVIEW_RUBRIC_DIRS:-}"
}

# ai_review::require_rubric <rubric_filename>
# Fails when no resolved source supplies <rubric_filename>. Use it for the
# files that carry the OUTPUT CONTRACT (pr-review.md, codebase-audit.md): they
# define the result marker and the findings JSON, so without one the run
# produces unparseable output and dies later with a confusing error. Failing
# here names the real cause.
ai_review::require_rubric() {
  local file="$1"
  local dir
  while IFS= read -r dir; do
    [[ -n "${dir}" && -f "${dir}/${file}" ]] && return 0
  done <<<"${AI_REVIEW_RUBRIC_DIRS:-}"
  ai_review::err "No rubric source supplies ${file}."
  ai_review::err "  AI_REVIEW_PROFILE='${AI_REVIEW_PROFILE:-}' resolved to:"
  printf '%s' "${AI_REVIEW_RUBRIC_DIRS:-}" | while IFS= read -r dir; do
    [[ -n "${dir}" ]] && ai_review::err "    ${dir}"
  done
  ai_review::err "  That file carries the result marker and findings-JSON contract, so the"
  ai_review::err "  run cannot produce parseable output without it. Add 'base' to the list,"
  ai_review::err "  or supply ${file} in your own profile."
  exit 2
}

# ── Gate verdict ────────────────────────────────────────────────────────────
# ai_review::gate_blocks <findings_json_file|->
# Pass a file path, or "-" with the JSON on stdin. Returns 0 when the review
# should fail the build, 1 when it should not, and 2 when the verdict could not
# be determined — which a caller MUST treat as blocking, never as a pass. Logs
# the reason and the blocking findings.
#
# The decision itself lives in harness/gate_verdict.py so the composite action,
# this engine and the sandbox wrapper cannot drift apart on what "blocks" means.
ai_review::gate_blocks() {
  local json="$1"
  local out rc
  out="$(python3 "${AI_COMMON_HOME:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}/harness/gate_verdict.py" "${json}" 2>&1)"
  rc=$?
  if ((rc != 0)); then
    ai_review::err "could not determine a gate verdict from ${json}: ${out}"
    return 2
  fi

  local unknown_count
  unknown_count="$(grep -c '^UNKNOWN' <<<"${out}" || true)"
  if [[ "${unknown_count}" -gt 0 ]]; then
    ai_review::warn "${unknown_count} finding(s) carry an unrecognized severity; counting them as blocking."
  fi

  local reason
  reason="$(grep '^REASON' <<<"${out}" | cut -f2-)"
  if grep -q '^VERDICT	BLOCK' <<<"${out}"; then
    grep '^BLOCK' <<<"${out}" | cut -f2- | while IFS= read -r t; do
      ai_review::log "  blocking: ${t}"
    done
    ai_review::log "gate verdict: BLOCK (${reason})"
    return 0
  fi
  ai_review::log "gate verdict: PASS (${reason})"
  return 1
}

# ── Adjudication: false-positive reduction ──────────────────────────────────
# Three modes, selected by AI_ADJUDICATION (default "self"):
#
#   self        Single-pass self-adjudication (DEFAULT). The review prompt
#               instructs the model to re-examine its own candidate findings
#               as a skeptic before reporting — one AI call. Fast and cheap.
#   independent An additional fresh-agent second pass re-inspects a
#               finding-bearing (COMMENT) result before posting. Honors
#               AI_ADJUDICATION_MODEL so the second opinion can run on a
#               different model of the same CLI. Strongest, but ~doubles
#               time/cost on finding-bearing reviews. If the pass fails or
#               returns no parseable JSON, the first-pass result stands.
#   off         No adjudication (raw first-pass findings; --no-adjudicate
#               forces this).
#
# Skipping adjudication never lowers detection — it can only confirm, dismiss,
# or downgrade — so "off" is the stricter (report-more) direction.

# ai_review::adjudication_mode  → prints one of: self | independent | off
ai_review::adjudication_mode() {
  if [[ "${AI_REVIEW_NO_ADJUDICATE:-0}" == "1" ]]; then
    echo "off"
    return 0
  fi
  local v
  v="$(printf '%s' "${AI_ADJUDICATION:-self}" | tr '[:upper:]' '[:lower:]')"
  case "${v}" in
    self | inline) echo "self" ;;
    independent | fresh | 1) echo "independent" ;;
    off | 0 | no | none | false) echo "off" ;;
    *) echo "self" ;;
  esac
}

# ai_review::self_adjudication_instructions
# Appended to the first-pass review prompt only when the resolved mode is
# "self" (the entrypoint decides; there is no env-var conditional in the
# prompt itself).
ai_review::self_adjudication_instructions() {
  cat <<'BLOCK'
SELF-ADJUDICATION

Before finalizing, re-examine your own candidate findings as a skeptical,
second reviewer. Inspect the actual cited code for each one and classify it:
  • CONFIRMED      — genuinely real at the stated severity; keep it.
  • OVERSTATED     — real but the severity is too high; keep it at the
                     corrected lower severity.
  • FALSE_POSITIVE — not a genuine issue; drop it.
The only legitimate grounds to dismiss or downgrade (do not invent others):
  • Synthetic / placeholder / obvious test data (example.com, 555 phone numbers,
    000-00-0000, AKIA…EXAMPLE keys, fixtures that are clearly not real secrets).
  • Already mitigated in the cited code (parameterized query, escaping/sanitizer,
    an authn/authz check that already guards the path).
  • Misclassification (a public identifier mistaken for a secret, and the like).
Keep any finding you cannot positively show to be benign — when in doubt, keep
it. Do NOT introduce new findings in this step.

Then report ONLY the confirmed findings, each at its final severity, add a
short "Dismissed / downgraded (self-adjudication)" section listing what you
removed or lowered and why, and compute BOTH the JSON block and the
end-of-response result marker from the CONFIRMED findings only.
BLOCK
}

# ai_review::build_adjudication_prompt <first_pass_json>
# Builds the independent-adjudication prompt for the PR path. The adjudicator
# receives the first-pass findings as the machine-readable JSON block (every
# finding carries path/line/severity/description) and must re-emit the same
# artifacts the first pass emits: a human report, a revised JSON block, and a
# result marker — all computed from the confirmed findings only.
ai_review::build_adjudication_prompt() {
  local first_pass_json="$1"

  cat <<PROMPT
You are an INDEPENDENT second reviewer adjudicating the findings produced by a
first-pass automated PR review. You did not perform the first pass and must
not assume it was correct. Your full instructions:

──────────────────── ADJUDICATION INSTRUCTIONS ────────────────────
$(cat "${ENGINE_HOME}/skills/base/finding-adjudication.md")
────────────────────────────────────────────────────────────────────

The code under review is the PR diff:

  git diff "${AI_REVIEW_AGAINST}" HEAD --unified=5

Inspect the actual code yourself before judging each finding — do not rely on
the report's prose.

The first-pass findings are the "comments" array in this JSON block:

<!-- AI_REVIEW_JSON_BEGIN -->
${first_pass_json}
<!-- AI_REVIEW_JSON_END -->

Classify every finding as CONFIRMED, FALSE_POSITIVE, or OVERSTATED (with a
corrected lower severity), each with a one-line rationale. Do NOT introduce
new findings. Then emit:

  1. A short human-readable adjudication report, including a
     "Dismissed / Downgraded by adjudication" section listing every change
     with its reason, so nothing is silently removed.
  2. ONE machine-readable JSON block with the SAME schema as the input,
     delimited by these exact markers on their own lines:
       <!-- AI_REVIEW_JSON_BEGIN -->
       { ...JSON object... }
       <!-- AI_REVIEW_JSON_END -->
     Its "comments" array must contain only the CONFIRMED and OVERSTATED
     findings at their final severities. Set "review_action" to "COMMENT" if
     any findings remain, or "APPROVE" if none do, and update "summary" to
     reflect the adjudicated counts.
  3. EXACTLY ONE result marker on its own final line, matching the JSON:
       <<<AI_REVIEW_RESULT:APPROVE>>>     (no confirmed findings remain)
       <<<AI_REVIEW_RESULT:COMMENT>>>     (confirmed findings remain)
PROMPT
}

# ai_review::adjudicate <first_pass_json>
# Runs the independent adjudication pass on the configured tool using
# AI_ADJUDICATION_MODEL (if set). Prints the adjudicator's raw response to
# stdout; status logs go to stderr so callers can safely capture stdout.
ai_review::adjudicate() {
  local first_pass_json="$1"
  local prompt
  prompt="$(ai_review::build_adjudication_prompt "${first_pass_json}")"

  # Every provider but Azure selects the model from the CLI's model flag, so
  # passing AI_ADJUDICATION_MODEL is enough. Azure resolves the deployment from
  # the URL path, so the second opinion also needs its own URL — otherwise the
  # flag changes and the request still lands on the first-pass deployment.
  # endpoints.sh records the template when it built the URL, and refuses the
  # combination up front when a caller-supplied URL makes the swap impossible.
  if [[ -n "${AI_ADJUDICATION_MODEL:-}" && -n "${AI_REVIEW_AZURE_URL_TEMPLATE:-}" ]]; then
    local adj_url="${AI_REVIEW_AZURE_URL_TEMPLATE/\{MODEL\}/${AI_ADJUDICATION_MODEL}}"
    ai_review::log "  adjudication endpoint: ${adj_url}"
    OPENAI_BASE_URL="${adj_url}" ai_review::invoke_tool "${prompt}" "${AI_ADJUDICATION_MODEL}"
    return $?
  fi

  ai_review::invoke_tool "${prompt}" "${AI_ADJUDICATION_MODEL:-}"
}

# ── Parallel fan-out for large diffs ─────────────────────────────────────────
# When a PR touches enough files across enough batches, split the diff into
# independent batches and review them concurrently, then merge the per-batch
# JSON findings into one review. Each worker runs the same first-pass prompt
# the single-call path runs, scoped to its files; adjudication (independent
# mode) runs once on the merged findings, not per batch.

# ai_review::group_files_into_batches   (reads file paths, one per line, on stdin)
# Emits one record per batch:  <key>\t<file>|<file>|...
# key = directory (default) or the file itself when AI_REVIEW_BATCH_BY=file.
# bash 3.2 safe: no associative arrays / mapfile — we emit <key>\t<file> pairs,
# sort (a tab-led sort groups a key's files together), then coalesce with awk.
#
# Takes its input on stdin rather than calling changed_files itself, so a
# workflow whose scope is not a diff (the codebase audit walks the working
# tree) reuses the same grouping, packing and budgeting instead of growing a
# parallel planner that would drift from this one.
ai_review::group_files_into_batches() {
  local by="${AI_REVIEW_BATCH_BY:-dir}"
  while IFS= read -r f; do
    [[ -z "${f}" ]] && continue
    local key
    if [[ "${by}" == "file" ]]; then
      key="${f}"
    else
      key="$(dirname "${f}")"
      [[ "${key}" == "." ]] && key="(root)"
    fi
    printf '%s\t%s\n' "${key}" "${f}"
  done | LC_ALL=C sort | awk -F'\t' '
    {
      if ($1 != cur) {
        if (cur != "") { print cur "\t" files }
        cur = $1; files = $2
      } else {
        files = files "|" $2
      }
    }
    END { if (cur != "") print cur "\t" files }
  '
}

# ai_review::plan_diff_batches
# The diff-scoped planner: group the files the diff touches.
ai_review::plan_diff_batches() {
  ai_review::changed_files | ai_review::group_files_into_batches
}

# ai_review::pack_batches <max_bins>   (reads <key>\t<files> records on stdin)
# Coalesces per-directory records into at most <max_bins> batches via greedy
# bin-packing (assign the largest remaining record to the least-loaded bin),
# balancing file counts. This is the cap that keeps fan-out to a SINGLE wave:
# without it, N directories become N batches that serialize into ceil(N/jobs)
# waves, each paying the full model cold-start + rubric read — which made a
# many-directory diff *slower* than a single call. With batches ≤ jobs, every
# batch runs concurrently and wall-clock can't exceed a single full-diff call.
ai_review::pack_batches() {
  local max_bins="$1"
  awk -F'\t' -v N="${max_bins}" '
    {
      files=$2
      c=gsub(/\|/,"|",files)+1   # file count = (#pipes)+1; records are non-empty
      rkey[NR]=$1; rfiles[NR]=$2; rcnt[NR]=c; nrec=NR
    }
    END {
      if (N < 1) N=1
      if (nrec <= N) {           # already within the cap — pass through unchanged
        for (i=1;i<=nrec;i++) printf "%s\t%s\n", rkey[i], rfiles[i]
      } else {
        for (i=1;i<=N;i++) { load[i]=0; bin[i]="" }
        for (a=1;a<=nrec;a++) order[a]=a
        # selection sort by count desc (record counts are tiny)
        for (a=1;a<=nrec;a++) for (b=a+1;b<=nrec;b++)
          if (rcnt[order[b]]>rcnt[order[a]]) { t=order[a];order[a]=order[b];order[b]=t }
        for (a=1;a<=nrec;a++) {
          r=order[a]; m=1
          for (i=2;i<=N;i++) if (load[i]<load[m]) m=i
          bin[m] = (bin[m]=="") ? rfiles[r] : bin[m] "|" rfiles[r]
          load[m]+=rcnt[r]
        }
        b=0
        for (i=1;i<=N;i++) if (bin[i]!="") { b++; printf "batch %d (%d file(s))\t%s\n", b, load[i], bin[i] }
      }
    }
  '
}

# ai_review::should_batch <nfiles> <nbatches>
# Fan out only when it actually helps: more than one worker allowed, more than
# one batch to spread, and the diff is large enough to be worth the per-batch
# overhead. A single-directory change stays a single full-context call.
ai_review::should_batch() {
  local nfiles="$1" nbatches="$2"
  local min_files="${AI_REVIEW_BATCH_MIN_FILES:-10}"
  ((AI_REVIEW_JOBS > 1)) && ((nbatches > 1)) && ((nfiles >= min_files))
}

# ai_review::context_budget <files_in_batch>
# A worker reviewing few files needs few context files. clamp(3 × n, 4, cap)
# where cap is the configured AI_REVIEW_CONTEXT_BUDGET (default 15).
ai_review::context_budget() {
  local n="$1" b cap
  cap="${AI_REVIEW_CONTEXT_BUDGET:-15}"
  b=$((3 * n))
  ((b < 4)) && b=4
  ((b > cap)) && b="${cap}"
  printf '%s' "${b}"
}

# ai_review::fan_out <record>...
# Re-invokes this engine's entrypoint (AI_REVIEW_SELF) with its worker flag
# (AI_REVIEW_WORKER_FLAG, default --__review-one) once per batch via
# `xargs -0 -P AI_REVIEW_JOBS`. Each worker prints its human report to stderr
# (so it streams live) and exactly one sentinel line to stdout (captured here):
#   AI_REVIEW_BATCH_RESULT\t<key>\t<marker>\t<json_file>
# where <json_file> is "-" if the worker produced no parseable findings JSON.
#
# The verdict is derived downstream by merging the per-batch JSON files
# (fold_review_json.py) — the single source of truth. This function's only job
# is to run the workers and report *completeness*: it publishes
#   AI_REVIEW_FAN_COMPLETE   "1" iff every batch returned a usable JSON file
#   AI_REVIEW_BATCH_SENTINELS raw sentinel lines (for JSON-file collection)
# so the caller can fail safe when a batch was not reviewed rather than post a
# partial review as if it were complete.
ai_review::fan_out() {
  local -a records=("$@")
  local expected=${#records[@]}

  if [[ -z "${AI_REVIEW_SELF:-}" ]]; then
    ai_review::err "Internal error: AI_REVIEW_SELF not set; the entrypoint must export it for fan-out."
    AI_REVIEW_FAN_COMPLETE=0
    AI_REVIEW_BATCH_SENTINELS=""
    return 0
  fi

  # Propagate config to the worker processes (they re-source this library).
  export AI_REVIEW_TOOL
  export AI_REVIEW_AGAINST
  export AI_REVIEW_BATCH_BY="${AI_REVIEW_BATCH_BY:-dir}"
  export AI_REVIEW_BATCH_DIR
  [[ -n "${AI_REVIEW_MODEL:-}" ]] && export AI_REVIEW_MODEL
  [[ "${AI_REVIEW_NO_ADJUDICATE:-0}" == "1" ]] && export AI_REVIEW_NO_ADJUDICATE
  [[ -n "${AI_ADJUDICATION:-}" ]] && export AI_ADJUDICATION
  [[ -n "${AI_ADJUDICATION_MODEL:-}" ]] && export AI_ADJUDICATION_MODEL

  ai_review::info "Fanning out ${expected} batch(es) across ${AI_REVIEW_JOBS} workers (batch-by=${AI_REVIEW_BATCH_BY})..."

  local sentinels fan_rc=0
  # NUL-delimited records so embedded tabs/spaces in paths survive.
  sentinels="$(printf '%s\0' "${records[@]}" |
    xargs -0 -P "${AI_REVIEW_JOBS}" -n1 bash "${AI_REVIEW_SELF}" \
      "${AI_REVIEW_WORKER_FLAG:---__review-one}")" || fan_rc=$?

  # A batch counts as reviewed only if it emitted a sentinel with a real JSON
  # file (field 4 != "-"). A crashed worker (xargs rc != 0), a missing
  # sentinel, or a worker that produced no JSON all leave us short.
  local produced
  produced="$(printf '%s\n' "${sentinels}" |
    awk -F'\t' '$1=="AI_REVIEW_BATCH_RESULT" && $4!="-" && $4!="" {n++} END {print n+0}')"

  if ((fan_rc != 0)) || ((produced < expected)); then
    ai_review::warn "Some batches did not return findings (xargs rc=${fan_rc}; ${produced}/${expected} produced JSON). Failing safe."
    AI_REVIEW_FAN_COMPLETE=0
  else
    AI_REVIEW_FAN_COMPLETE=1
  fi
  AI_REVIEW_BATCH_SENTINELS="${sentinels}"
}
