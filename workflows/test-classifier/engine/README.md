# Test-classifier engine — embedding contract

This directory is the single source of truth for the AI test classifier. The
composite GitHub Action references it in place; any future front end (Jenkins
step, local shell alias) consumes it through the contract on this page and
nothing else.

## Relocatability guarantee

The `engine/` directory may be copied anywhere **as a unit**. Every script
resolves internal paths from its own location (`ENGINE_HOME`), never from the
working directory. At runtime the working directory is the repository being
classified. The engine writes nothing outside stdout, stderr, explicitly
requested output files (`--json-out`), and its own temporary directories —
**except** that in OBSERVED mode (the default) the AI agent installs the
repository's dependencies and runs its test suite, which writes whatever the
repository's own tooling writes.

## What it does

For each failing test of the change under test, the classifier emits one of
four verdicts — `APPLICATION_BUG`, `TEST_BUG`, `FLAKY_FAILURE`,
`ENVIRONMENT_ISSUE` — with a category, a confidence, and a one-line rationale,
then posts ONE PR comment with the verdict table and a 👍/👎 reaction ask (the
tuning signal). It is diagnostic only: it never edits code or tests. Two
signal modes:

- **OBSERVED** (default): the agent locates, installs, and runs the repo's
  test suite, then classifies the failures it actually observed.
- **INFERRED** (`--no-run-suite` / `AI_RUN_SUITE=0`): the agent predicts
  failures statically from the diff — for triaging an untrusted diff without
  executing it, or when the suite can't run.

## Entrypoint

```
bash <engine>/bin/ai-test-classifier [flags]    # run from the classified repo's root
```

| Flag | Meaning |
|---|---|
| `--pr <n>` | Explicit PR number (otherwise discovered via `gh pr view`) |
| `--against <ref>` | Base ref for the diff (skips PR discovery) |
| `--unpushed` | Local backstop: classify committed + staged work, no PR (report-only) |
| `--post-comment` | Post the one PR comment (omit for a report-only run) |
| `--gate` | Exit 1 on CLASSIFIED (advisory by default) |
| `--json-only` | Print only the machine-readable JSON block |
| `--json-out <file>` | Also write the JSON block to a file |
| `--post-only --pr <n> --json-in <file>` | Post a previously produced JSON; no AI call |
| `--no-run-suite` | INFERRED mode: predict from the diff; never execute the change |
| `--dry-run` / `-n` | Print the plan; no AI call |
| `--no-block` | Always exit 0 (neutralizes `--gate` and runtime failures) |
| `--simulate` | Skip the AI and feed a synthetic result through the posting path |
| `--submit` | Local runs: force the terminal "helpful?" prompt + metrics row |

The `--json-out` / `--post-only` pair splits a run into a separable AI phase
(no SCM token) and a trusted post phase (no AI). The composite action runs the
two phases as separate steps so the agent that executes untrusted PR content
never has a repo-write token in its process tree. Pass the same `--against`
to the post phase so the comment can anchor to a changed file.

## Environment

| Variable | Required | Meaning |
|---|---|---|
| `AI_REVIEW_TOOL` | yes | `claude` \| `codex` \| `copilot` |
| `AI_REVIEW_PROVIDER` | no | `api` (default) \| `bedrock` (claude or codex) \| `vertex` (claude) \| `azure` (codex) |
| `AI_REVIEW_MODEL` | no | Model override (`--model`); Bedrock model ID (bedrock; required for codex) or Azure deployment name (azure) |
| `ANTHROPIC_API_KEY` | claude+api | Public Anthropic API key |
| `OPENAI_API_KEY` | codex | Public OpenAI API key |
| `ANTHROPIC_BASE_URL` / `OPENAI_BASE_URL` | no | Custom/gateway endpoints, passed through |
| `AWS_REGION` | bedrock | Plus an ambient AWS credential source |
| `ANTHROPIC_VERTEX_PROJECT_ID`, `CLOUD_ML_REGION` | vertex | Plus ambient GCP ADC |
| `AZURE_OPENAI_ENDPOINT`, `AZURE_OPENAI_API_KEY`, `AZURE_OPENAI_API_VERSION` | azure | Azure resource endpoint, key, REST API version |
| `COPILOT_PROVIDER_BASE_URL`, `COPILOT_PROVIDER_TYPE`, `COPILOT_PROVIDER_API_KEY`, `COPILOT_MODEL` | copilot BYOK | Passed through to the copilot CLI |
| `AI_RUN_SUITE` | no | `1` (default, OBSERVED) \| `0` (INFERRED; same as `--no-run-suite`) |
| `AI_SUITE_MAX_TURNS` | no | Agentic turn budget for the suite run (default 80) |
| `AI_SUITE_TIMEOUT_SECS` | no | Hard wall-clock ceiling on the AI call (default 1500) |
| `AI_REVIEW_REPO` | no | `owner/name` override when the PR lives off the `origin` remote |
| `GITHUB_TOKEN` / `GH_TOKEN` | posting | Auth for `gh`; only the post phase needs it |
| `METRICSAI_WEBHOOK_URL`, `METRICSAI_WEBHOOK_KEY`, `METRICSAI_WEBHOOK_TAB` | no | Optional local metrics sink (interactive runs only) |
| `CI`, `NO_COLOR` | no | Output plumbing |

## Runtime dependencies

- Always: `bash` ≥ 3.2, `git`, standard POSIX tools (`awk`, `sed`)
- The selected AI CLI on `PATH`: `claude`, `codex`, or `copilot`
- Rendering/posting the PR comment and the local summary: `python3`
- Posting to GitHub (`--post-comment` / `--post-only`): `gh`
- OBSERVED mode additionally uses whatever toolchain the classified repo's own
  test suite needs — the agent bootstraps it best-effort from the repo's
  lockfiles/CI config on the runner

## Exit codes

| Code | Meaning |
|---|---|
| 0 | CLASSIFIED or NO_ACTION (advisory), turn-budget overflow (soft), `--dry-run`, `--no-block` |
| 1 | `--gate` with CLASSIFIED, or unrecoverable runtime error (missing marker/JSON, CLI failure) |
| 2 | Configuration error (bad flags; `AI_REVIEW_TOOL`/provider invalid) |

## Layout

```
bin/ai-test-classifier      entrypoint (arg parsing, PR discovery, prompt, posting, metrics)
lib/core.sh                 tool invocation (claude/codex/copilot), markers, streaming, args
lib/endpoints.sh            provider → CLI env mapping + validation + audit line
                            (verbatim copy of the security-review engine's — keep in sync)
skills/test-classifier.md   the classification skill: taxonomy, decision procedure, output contract
```
