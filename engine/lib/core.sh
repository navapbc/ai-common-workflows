#!/usr/bin/env bash
# engine/lib/core.sh
#
# Core dispatch library for the AI PR-review engine. Sourced by
# engine/bin/ai-pr-review; never executed directly.
#
# Responsibilities:
#   - CLI flag parsing shared with the entrypoint
#   - AI_REVIEW_TOOL resolution (claude | codex | copilot) and invocation
#   - Diff collection against a base ref (AI_REVIEW_AGAINST)
#   - Result-marker parsing (APPROVE | COMMENT | REQUEST_CHANGES)
#   - Adjudication (self-critique prompt block; independent second pass)
#   - Parallel fan-out for large diffs (batch planning, packing, folding)
#
# The library expects the sourcing script to have set ENGINE_HOME (the
# engine's own root directory) and SKILL_NAME before calling any function.
# All paths are resolved from ENGINE_HOME, never from the repository being
# reviewed — the engine may be copied anywhere as a unit (composite action
# checkout, Jenkins plugin extraction, container image) and must not assume
# it lives inside the reviewed repo.
#
# Exit codes (uniform across the engine):
#   0  — review completed; APPROVE, or findings in advisory (non-gate) mode
#   1  — gate failure (--gate with non-APPROVE) or unrecoverable runtime error
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
#   AI_REVIEW_REMAINING     (array)      — any unparsed args
ai_review::parse_args() {
  AI_REVIEW_DRY_RUN=0
  AI_REVIEW_NO_BLOCK=0
  AI_REVIEW_NO_ADJUDICATE=0
  AI_REVIEW_AGAINST="${AI_REVIEW_AGAINST:-}"
  AI_REVIEW_LIST_BATCHES=0
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
}

ai_review::print_help() {
  cat <<EOF
AI-assisted PR review (security + compliance)

Usage:
  ai-pr-review [options]

Options:
  --pr <number>        Explicit PR number (overrides auto-discovery).
  --against <ref>      Base ref to diff against (e.g. origin/main). When set,
                       PR discovery is skipped; required unless a PR can be
                       discovered via the SCM CLI.
  --post-comments      Post the review with inline comments to the SCM
                       (default SCM: GitHub via the gh CLI).
  --gate               Exit 1 on any non-APPROVE result (CI-blocking mode).
                       Default is advisory: findings never fail the build.
  --json-only          Print only the machine-readable JSON block.
  --json-out <file>    Also write the JSON block to <file> (lets a caller run
                       the AI phase and the post phase as separate processes).
  --post-only          Skip the AI entirely: post a previously produced JSON
                       block (requires --pr and --json-in). The trusted post
                       phase of a split run.
  --json-in <file>     JSON block to post in --post-only mode.
  -n, --dry-run        Print the resolved tool, plan, and prompt; no AI call.
  --no-block           Always exit 0 regardless of findings or gate mode.
  --no-adjudicate      Disable adjudication (same as AI_ADJUDICATION=off).
  --jobs <N>           Concurrent workers when the diff is large enough to
                       fan out (default 4; also AI_REVIEW_JOBS). 1 = serial.
  --list-batches       Print how the diff would be batched; no AI call.
  -h, --help           Show this help and exit.

Environment variables:
  AI_REVIEW_TOOL           Required. One of: claude | codex | copilot.
  AI_REVIEW_PROVIDER       LLM endpoint: api (default) | bedrock | vertex | azure.
                           bedrock: claude or codex; vertex: claude only;
                           azure: codex only. (copilot uses BYOK env vars —
                           COPILOT_PROVIDER_BASE_URL etc. — on the api path.)
  AI_REVIEW_MODEL          Model override passed to the CLI's --model flag.
                           For bedrock this is the Bedrock model ID (required
                           for codex); for azure it is the Azure deployment name.
  ANTHROPIC_API_KEY        Claude on the public API (provider=api).
  OPENAI_API_KEY           Codex on the public API.
  ANTHROPIC_BASE_URL       Custom Anthropic-compatible endpoint (gateways).
  OPENAI_BASE_URL          Custom OpenAI-compatible endpoint (gateways).
  AWS_REGION               Required for provider=bedrock.
  ANTHROPIC_VERTEX_PROJECT_ID, CLOUD_ML_REGION
                           Required for provider=vertex.
  AZURE_OPENAI_ENDPOINT    Required for provider=azure (resource endpoint).
  AZURE_OPENAI_API_KEY, AZURE_OPENAI_API_VERSION
                           Key and REST API version for provider=azure.
  AI_ADJUDICATION          self (default) | independent | off.
  AI_ADJUDICATION_MODEL    Model for the independent adjudication pass only.
  AI_REVIEW_JOBS           Concurrent fan-out workers (default 4).
  AI_REVIEW_BATCH_BY       dir (default) | file — fan-out batching key.
  AI_REVIEW_BATCH_MIN_FILES
                           Minimum changed files before fanning out (default 10).
  AI_REVIEW_CONTEXT_BUDGET Ceiling on context files per AI call (default 15).
  AI_REVIEW_SCM            SCM backend for discovery/posting (default github).
  GITHUB_TOKEN / GH_TOKEN  Auth for the gh CLI when posting.
  CI                       "true" suppresses color output.
  NO_COLOR                 Suppress ANSI color codes.

Exit codes:
  0   APPROVE, or findings in advisory mode (or --dry-run / --no-block)
  1   --gate with non-APPROVE result, or unrecoverable runtime error
  2   Configuration error (AI_REVIEW_TOOL unset/invalid; bad flags)
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

ai_review::has_changes() {
  ai_review::require_against
  ! git diff --quiet "${AI_REVIEW_AGAINST}" HEAD --
}

ai_review::changed_files() {
  git diff --name-only "${AI_REVIEW_AGAINST}" HEAD --
}

ai_review::diff_command_description() {
  echo "git diff ${AI_REVIEW_AGAINST} HEAD"
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

# ── Tool-specific invocation ────────────────────────────────────────────────
# ai_review::invoke_tool <prompt> [model]
# Invokes the resolved AI CLI in non-interactive mode with the given prompt,
# printing the raw response to stdout. When [model] is non-empty it is passed
# to the CLI's model-selection flag — this is how AI_REVIEW_MODEL selects a
# Bedrock model ID and how the adjudication pass can run on a different model
# of the same CLI. Any non-zero exit from the underlying CLI propagates.
#
# Consumer repos have no per-repo CLI permission settings, so each CLI gets
# explicit non-interactive permission flags scoped to read-only review work.
ai_review::invoke_tool() {
  local prompt="$1"
  local model="${2:-}"

  case "${AI_REVIEW_TOOL_RESOLVED}" in
    claude)
      ai_review::require_cli "claude" \
        "Install Claude Code:  npm install -g @anthropic-ai/claude-code"
      # -p = non-interactive (print) mode. --allowed-tools grants read-only
      # inspection plus the git commands the skill instructions rely on;
      # nothing else (no writes, no network tools, no gh).
      claude -p "${prompt}" \
        ${model:+--model "${model}"} \
        --allowed-tools "Read Grep Glob Bash(git diff:*) Bash(git log:*) Bash(git show:*)" \
        2>&1
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
      # --sandbox read-only = filesystem read access (git diff / file reads)
      # with no write/network side effects.
      codex exec --sandbox read-only --skip-git-repo-check \
        "${codex_cfg[@]+"${codex_cfg[@]}"}" \
        ${model:+--model "${model}"} \
        "${prompt}" 2>&1
      ;;
    copilot)
      ai_review::require_cli "copilot" \
        "Install GitHub Copilot CLI:  npm install -g @github/copilot"
      # copilot -p = non-interactive single-prompt mode. Tool-permission
      # flags vary across copilot CLI releases; the skill instructions only
      # require read access and git diff, which the default posture allows.
      copilot -p "${prompt}" \
        ${model:+--model "${model}"} \
        2>&1
      ;;
    *)
      ai_review::err "Internal error: unknown resolved tool '${AI_REVIEW_TOOL_RESOLVED}'"
      exit 1
      ;;
  esac
}

# First-pass invocation: the configured tool, the AI_REVIEW_MODEL override (if
# any), the dispatcher's SKILL_PROMPT.
ai_review::invoke_ai() {
  ai_review::invoke_tool "${SKILL_PROMPT}" "${AI_REVIEW_MODEL:-}"
}

# ── Result marker parsing ───────────────────────────────────────────────────
# The canonical marker is:  <<<AI_REVIEW_RESULT:APPROVE|COMMENT|REQUEST_CHANGES>>>
# The AI emits its verdict as the LAST marker in its response. We must take the
# last occurrence, not the first match, because the captured output can contain
# earlier *echoes* of the marker list: the prompt itself shows the markers, and
# CLIs that stream the full agent transcript (e.g. `codex exec`) replay them.
# A naive first-match grep would read the instructions, not the verdict.
ai_review::parse_result() {
  local output="$1"
  local marker
  marker="$(grep -oE '<<<AI_REVIEW_RESULT:(APPROVE|COMMENT|REQUEST_CHANGES)>>>' <<<"${output}" | tail -n 1)"

  case "${marker}" in
    *REQUEST_CHANGES*) echo "REQUEST_CHANGES" ;;
    *COMMENT*) echo "COMMENT" ;;
    *APPROVE*) echo "APPROVE" ;;
    *) echo "UNPARSEABLE" ;;
  esac
}

# Pull the JSON block between AI_REVIEW_JSON_BEGIN/END markers out of the
# given text.
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
  echo "${input}" | awk '
    /<!-- AI_REVIEW_JSON_BEGIN -->/ { capturing=1; block=""; next }
    /<!-- AI_REVIEW_JSON_END -->/   { if (capturing) { last=block; have=1 } capturing=0; next }
    capturing                       { block = block $0 "\n" }
    END                             { if (have) printf "%s", last }
  '
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
$(cat "${ENGINE_HOME}/skills/finding-adjudication.md")
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
  ai_review::invoke_tool "${prompt}" "${AI_ADJUDICATION_MODEL:-}"
}

# ── Parallel fan-out for large diffs ─────────────────────────────────────────
# When a PR touches enough files across enough batches, split the diff into
# independent batches and review them concurrently, then merge the per-batch
# JSON findings into one review. Each worker runs the same first-pass prompt
# the single-call path runs, scoped to its files; adjudication (independent
# mode) runs once on the merged findings, not per batch.

# ai_review::plan_diff_batches
# Emits one record per batch:  <key>\t<file>|<file>|...
# key = directory (default) or the file itself when AI_REVIEW_BATCH_BY=file.
# bash 3.2 safe: no associative arrays / mapfile — we emit <key>\t<file> pairs,
# sort (a tab-led sort groups a key's files together), then coalesce with awk.
ai_review::plan_diff_batches() {
  local by="${AI_REVIEW_BATCH_BY:-dir}"
  ai_review::changed_files | while IFS= read -r f; do
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
# Re-invokes this engine's entrypoint (AI_REVIEW_SELF) once per batch via
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
    xargs -0 -P "${AI_REVIEW_JOBS}" -n1 bash "${AI_REVIEW_SELF}" --__review-one)" || fan_rc=$?

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
