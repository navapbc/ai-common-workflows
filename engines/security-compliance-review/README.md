# Review engine — embedding contract

This directory is the single source of truth for the AI PR review. The
composite GitHub Action references it in place, and the Jenkins plugin bundles
a zip of it at build time and extracts it onto the agent. Both consume it
through the contract on this page and nothing else. (The experimental sandbox
image under `../_common/sandbox/` also copies it in, but is not shipped — see
its README.)

## Relocatability guarantee

This engine may be copied anywhere as long as the copy keeps `_common/` a
sibling of `security-compliance-review/` (copy the `engines/` tree as a
unit). Every script
resolves internal paths from its own location (`ENGINE_HOME`), never from
the working directory or `git rev-parse`. At runtime the working directory
is the repository being reviewed. The engine writes nothing outside stdout,
stderr, explicitly requested output files (`--json-out`), and its own
temporary directories.

## Entrypoint

```
bash <engines>/security-compliance-review/harness/ai-pr-review [flags]   # run from the reviewed repo's root
```

| Flag | Meaning |
|---|---|
| `--pr <n>` | Explicit PR number (otherwise discovered via the SCM CLI) |
| `--against <ref>` | Base ref for the diff (skips PR discovery) |
| `--unpushed` | Diff committed + staged work against the last push (local use; skips PR discovery) |
| `--post-comments` | Post the review with inline comments to the SCM |
| `--gate` | Exit 1 on any non-APPROVE result |
| `--json-only` | Print only the machine-readable findings JSON |
| `--json-out <file>` | Also write the findings JSON to a file |
| `--post-only --pr <n> --json-in <file>` | Post a previously produced JSON; no AI call |
| `--dry-run` / `-n` | Print the plan; no AI call |
| `--no-block` | Always exit 0 (neutralizes `--gate` and runtime failures) |
| `--no-adjudicate` | Force adjudication off |
| `--jobs <n>` | Fan-out concurrency (default 4) |
| `--list-batches` | Print the batch plan; no AI call |

The `--json-out` / `--post-only` pair can split a run into a separable AI
phase (no SCM access, no SCM token) and a trusted post phase (no AI). The
shipped front ends run a single invocation; this seam is used by the
experimental sandbox and reserved for a future token-stripped AI phase.

## Environment

| Variable | Required | Meaning |
|---|---|---|
| `AI_REVIEW_TOOL` | yes | `claude` \| `codex` \| `copilot` |
| `AI_REVIEW_PROVIDER` | no | `api` (default) \| `bedrock` (claude or codex) \| `vertex` (claude) \| `azure` (codex) |
| `AI_REVIEW_PROFILE` | no | Compliance profile: `baseline` (default) \| `cms-ars` \| a `skills/profiles/` name or a directory path. The `skills/base/iac-compliance.md` floor always applies; the profile's `iac-compliance.md` (if any) is an addition layered on top, not a replacement — see [docs/profiles.md](../../docs/profiles.md) |
| `AI_REVIEW_MODEL` | no | Model override (`--model`); Bedrock model ID (bedrock; required for codex) or Azure deployment name (azure) |
| `ANTHROPIC_API_KEY` | claude+api | Public Anthropic API key |
| `OPENAI_API_KEY` | codex | Public OpenAI API key |
| `ANTHROPIC_BASE_URL` / `OPENAI_BASE_URL` | no | Custom/gateway endpoints, passed through |
| `AWS_REGION` | bedrock | Plus an ambient AWS credential source |
| `ANTHROPIC_VERTEX_PROJECT_ID`, `CLOUD_ML_REGION` | vertex | Plus ambient GCP ADC |
| `AZURE_OPENAI_ENDPOINT` | azure | Azure resource endpoint; `OPENAI_BASE_URL` is derived from it + the deployment |
| `AZURE_OPENAI_API_KEY`, `AZURE_OPENAI_API_VERSION` | azure | Key (→`OPENAI_API_KEY`) and REST API version (default `2024-10-21`) |
| `COPILOT_PROVIDER_BASE_URL`, `COPILOT_PROVIDER_TYPE`, `COPILOT_PROVIDER_API_KEY`, `COPILOT_MODEL` | copilot BYOK | Passed through to the copilot CLI (talks directly to your endpoint) |
| `AI_ADJUDICATION` | no | `self` (default) \| `independent` \| `off` |
| `AI_ADJUDICATION_MODEL` | no | Model for the independent pass only |
| `AI_REVIEW_JOBS` | no | Fan-out concurrency (default 4) |
| `AI_REVIEW_BATCH_BY` | no | `dir` (default) \| `file` |
| `AI_REVIEW_BATCH_MIN_FILES` | no | Fan-out threshold (default 10) |
| `AI_REVIEW_CONTEXT_BUDGET` | no | Ceiling on context files the model may load beyond the diff (default 15). Stated to the model in a CONTEXT BUDGET prompt block; fan-out workers narrow it per batch |
| `AI_REVIEW_SCM` | no | SCM backend under `../_common/scm/` (default `github`) |
| `GITHUB_TOKEN` / `GH_TOKEN` | posting | Auth for `gh`; `GH_HOST` for GitHub Enterprise |
| `CI`, `NO_COLOR` | no | Output plumbing |

## Runtime dependencies

- Always: `bash` ≥ 3.2, `git`, standard POSIX tools (`awk`, `sed`, `xargs`)
- The selected AI CLI on `PATH`: `claude`, `codex`, or `copilot`
- When posting to GitHub (`--post-comments` / `--post-only`): `gh`, `python3`
- Fan-out JSON merging: `python3`

## Exit codes

| Code | Meaning |
|---|---|
| 0 | APPROVE, or findings in advisory (non-gate) mode; also `--dry-run`, `--no-block` |
| 1 | `--gate` with non-APPROVE, or unrecoverable runtime error (fail-safe) |
| 2 | Configuration error (bad flags; `AI_REVIEW_TOOL`/provider invalid) |

## Layout

```
harness/ai-pr-review        thin entrypoint (prompt, profiles, posting; also the
                            fan-out worker entry) — sources ../_common
skills/base/*.md            framework-neutral review rubric base, inlined at dispatch time
skills/profiles/<name>/     per-compliance-framework rubric additions/overrides (AI_REVIEW_PROFILE)

../_common/                 the shared runtime (see ../_common/CONTRACT.md):
  harness/core.sh           flags, tool invocation, markers, adjudication, fan-out
  harness/fold_review_json.py  merges per-batch findings JSON (fan-out)
  endpoints.sh              provider → CLI env mapping + validation + audit line
  scm/github.sh + github_payload.py  PR discovery + review posting (SCM seam)
  sandbox/                  EXPERIMENTAL Docker sandbox — not shipped
```
