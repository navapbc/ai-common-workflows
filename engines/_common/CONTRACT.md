# engines/_common — the shared harness contract

`_common` is the workflow-agnostic runtime every engine in `engines/` builds
on: dispatch, marker + JSON parsing, fan-out, adjudication, LLM endpoint
mapping, and the SCM seam. It is the single most-reusable code in this repo —
workflow engines source it; they never copy it.

This page is the interface. A workflow entrypoint that follows it gets the
whole runtime; changing anything here means checking every `engines/<name>/`.

## Sourcing

An entrypoint at `engines/<workflow>/harness/<name>`:

```bash
ENGINE_HOME="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"   # engines/<workflow>
AI_COMMON_HOME="$(cd "${ENGINE_HOME}/../_common" && pwd)"

SKILL_NAME="<short-id>"          # log prefix
SKILL_HUMAN_NAME="<display name>"
AI_REVIEW_MARKER_VOCAB="A|B|C"   # result-marker vocabulary (regex alternation)
AI_REVIEW_JSON_MARKER="X_JSON"   # <!-- X_JSON_BEGIN/END --> fences
AI_RUN_SUITE="${AI_RUN_SUITE:-0}"  # 1 = agentic posture (runs the repo's suite)

source "${AI_COMMON_HOME}/harness/core.sh"
source "${AI_COMMON_HOME}/endpoints.sh"
source "${AI_COMMON_HOME}/scm/${AI_REVIEW_SCM:-github}.sh"   # if it talks to an SCM
```

Set the parameterization variables BEFORE sourcing `core.sh` (its defaults
preserve the security-compliance-review contract). Relocatability: the
`engines/` tree may be copied anywhere as a unit; `_common` must stay a
sibling of the workflow engines.

## What core.sh provides

| Area | Functions | Notes |
|---|---|---|
| Logging | `ai_review::log/info/ok/warn/err` | All status output → stderr; stdout is reserved for artifacts |
| Args | `ai_review::parse_args` | `--against/--unpushed/--dry-run/--no-block/--jobs/--list-batches/--no-adjudicate/--help/--`; sets `AI_REVIEW_*` globals |
| Tool | `ai_review::resolve_tool`, `ai_review::require_cli` | `AI_REVIEW_TOOL` → `AI_REVIEW_TOOL_RESOLVED` |
| Diff | `ai_review::require_against`, `has_changes`, `changed_files`, `diff_command_description`, `diff_has_iac` | base→HEAD, base→index (`--unpushed`), or staged-only when no base |
| Invocation | `ai_review::invoke_ai` (uses `SKILL_PROMPT`), `ai_review::invoke_tool <prompt> [model]` | Read-only posture by default; `AI_RUN_SUITE=1` switches to the agentic posture (write grants, `AI_SUITE_MAX_TURNS` / `AI_SUITE_TIMEOUT_SECS`, streaming on local TTYs, `CI=true` exported to the suite) |
| Results | `ai_review::parse_result` (→ vocab word or `UNPARSEABLE`), `ai_review::extract_review_json` (last closed block), `ai_review::is_max_turns` | Parameterized by `AI_REVIEW_MARKER_VOCAB` / `AI_REVIEW_JSON_MARKER` |
| Gate | `ai_review::gate_blocks <file\|->` | 0 blocks, 1 does not, **2 could not tell — callers must treat as blocking**. Decision lives in `harness/gate_verdict.py` so every gate surface agrees |
| Adjudication | `ai_review::adjudication_mode`, `self_adjudication_instructions`, `adjudicate` | The independent pass reads `${ENGINE_HOME}/skills/base/finding-adjudication.md` |
| Fan-out | `ai_review::group_files_into_batches` (paths on stdin), `plan_diff_batches`, `pack_batches`, `should_batch`, `context_budget`, `fan_out` | Caller exports `AI_REVIEW_SELF` (its own path) and re-enters with `AI_REVIEW_WORKER_FLAG` (default `--__review-one`); merge with `harness/fold_review_json.py`. Group from any file list — the codebase audit walks the working tree instead of a diff |
| Help | `ai_review::print_help` | A generic fallback — every entrypoint overrides it after sourcing |

## endpoints.sh

`ai_review::configure_endpoint` maps `AI_REVIEW_PROVIDER`
(`api` · `bedrock` · `vertex` · `azure`) onto the env each CLI expects,
validates required configuration (exit 2 on misconfiguration), and prints one
audit line. Call it only when a real AI invocation will happen — after any
`--dry-run` exit, so dry runs need no credentials.

## scm/<name>.sh

Three functions per backend: `scm::pr_base_ref <pr>`, `scm::discover_pr`,
`scm::post_review <pr> <json>`. `github` ships; a new SCM implements these
three and is selected with `AI_REVIEW_SCM`. (Workflows with a different
posting shape — e.g. the classifier's single comment — may post through their
own `gh` calls instead; the seam is for review-style inline posting.)

## Promises

- **Exit codes:** 0 clean/advisory, 1 gate or runtime failure, 2 configuration.
- **Gating never fails open.** `harness/gate_verdict.py` is the one decision on
  whether a review blocks (HIGH or CRITICAL findings, or a REQUEST_CHANGES
  verdict). An unreadable findings file or an unrecognized severity counts as
  blocking, never as a pass.
- **stdout discipline:** artifacts only (reports, JSON); status goes to stderr.
- **No SCM token needed by the AI phase** — nothing in the invocation path
  reads `GITHUB_TOKEN`/`GH_TOKEN`; only posting does.
- **bash ≥ 3.2** (no associative arrays / mapfile) plus git, awk, sed;
  `python3` for JSON folding and SCM payloads.
