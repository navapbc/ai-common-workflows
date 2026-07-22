# AI test classifier

`uses: navapbc/ai-common-workflows/workflows/test-classifier@<commit-sha>` — a
composite action that triages the failing tests on a pull request and posts
one advisory PR comment. Pin to a commit SHA ([why](security.md)).

## The problem it solves

When CI goes red, the expensive failure mode is not the red build — it is
fixing the wrong side of the failure: relaxing a test that correctly caught a
regression (shipping the bug with a green checkmark), "fixing" application
code to satisfy a stale assertion, or burning an afternoon chasing a timeout
that was never a code problem. The classifier answers one question for every
failing test — *is the test wrong, or is the code wrong?* — before anyone
writes a patch:

| Verdict | Meaning | What a human should do |
|---|---|---|
| `APPLICATION_BUG` | The app regressed; the test caught a real defect. | Fix the CODE — don't relax the test. |
| `TEST_BUG` | The app is correct; the test is stale. | Fix the TEST. |
| `FLAKY_FAILURE` | Non-deterministic; would pass on re-run. | Re-run to confirm, then deflake. |
| `ENVIRONMENT_ISSUE` | Infrastructure: timeout, missing service, runner OOM. | Fix the env / re-run. |

Each verdict carries a category (visual drift / behavioral drift / E2E
form-flow drift), a confidence, and a one-line rationale. The classifier is
**diagnostic only** — it never edits code or tests — and **advisory** by
default: the comment posts and the job stays green.

## Quickstart

```yaml
# .github/workflows/ai-test-classifier.yml
name: AI test classifier
on:
  pull_request:
    types: [opened, synchronize, reopened]
permissions:
  contents: read
  pull-requests: write
jobs:
  classify:
    runs-on: ubuntu-latest
    timeout-minutes: 30
    steps:
      - uses: actions/checkout@v4
        with: { ref: "${{ github.event.pull_request.head.sha }}" }
      - uses: navapbc/ai-common-workflows/workflows/test-classifier@<commit-sha> # v1.x.x
        with:
          anthropic-api-key: ${{ secrets.ANTHROPIC_API_KEY }}
```

Bedrock, Vertex, Azure OpenAI, and custom gateways use the same endpoint
inputs as the security review — see [private-endpoints.md](private-endpoints.md).

## OBSERVED vs INFERRED — and why it matters for security

By default (`run-suite: true`) the AI agent locates, installs, and **runs the
repository's test suite** on the runner, then classifies the failures it
actually observed (`OBSERVED`). That is executing the PR's code. Two
consequences:

- **The AI phase holds no SCM token** (same phase split as the review engine),
  so the executed code and the prompt-exposed diff can't reach a repo-write
  credential. See [architecture.md](architecture.md).
- **Do not run OBSERVED mode on PRs from untrusted forks.** Trigger on
  `pull_request` (never `pull_request_target`), and for public repos either
  rely on GitHub's first-time-contributor approval gate or set
  `run-suite: false` for a read-only `INFERRED` pass that predicts failures
  from the diff without executing anything.

The posted comment is labeled **Observed** or **Inferred** so a prediction is
never mistaken for a real run. The agent falls back to INFERRED on its own
when the suite can't run (no test command, missing toolchain) — and never
applies IaC test suites without a guaranteed teardown (see the skill's IaC
ladder in `workflows/test-classifier/engine/skills/test-classifier.md`).

## The feedback loop

The comment ends with a **React 👍 if right / 👎 if wrong** ask (on a 👎,
reply with a one-line reason). Reactions and replies are harvestable off the
GitHub API, which is how a team measures classifier precision over time and
decides whether to trust it with more (e.g. gating). Nothing in this repo
depends on any particular metrics backend.

## Inputs

Endpoint inputs are shared with the security review and apply per tool:
`bedrock` → `claude` or `codex`; `vertex` → `claude`; `azure` → `codex`;
`copilot-provider-*` → `copilot`.

| Input | Default | Description |
|---|---|---|
| `ai-tool` | `claude` | `claude` \| `codex` \| `copilot` |
| `anthropic-api-key` | — | Anthropic key (claude, provider=api) |
| `openai-api-key` | — | OpenAI key (codex) |
| `github-token` | `${{ github.token }}` | Token to post the comment (`pull-requests: write`) |
| `post-comment` | `true` | Post the one classification comment |
| `gate` | `false` | Fail the job when failing tests were classified |
| `dry-run` | `false` | Print the plan; no AI call |
| `pr-number` | event PR | Override the PR number |
| `run-suite` | `true` | OBSERVED (run the suite) vs `false` = INFERRED (diff-only, never executes) |
| `max-turns` | `80` | Agentic turn budget for the suite run |
| `suite-timeout-seconds` | `1500` | Hard wall-clock ceiling on the AI call |
| `provider` | `api` | `api` \| `bedrock` \| `vertex` \| `azure` |
| `model` | — | Model override; Bedrock model ID (bedrock; required for codex) or Azure deployment name (azure) |
| `aws-region` | — | Region for provider=bedrock |
| `vertex-project-id` / `vertex-region` | — | provider=vertex |
| `azure-openai-endpoint` / `azure-openai-api-key` / `azure-openai-api-version` | — / — / `2024-10-21` | provider=azure |
| `anthropic-base-url` / `openai-base-url` | — | Custom gateway endpoint |
| `copilot-provider-base-url` / `-type` / `-api-key`, `copilot-model` | — | ai-tool=copilot BYOK |
| `install-cli` / `cli-version` | `true` / `latest` | npm-install the AI CLI on the runner |

## Outputs

| Output | Description |
|---|---|
| `result` | `CLASSIFIED` \| `NO_ACTION` |
| `classification-json` | Path to the classifications JSON on the runner |

## Requirements

- Check out the PR head before the action (see quickstart). Add
  `persist-credentials: false` for the strongest token isolation
  ([security.md](security.md)).
- `permissions: { contents: read, pull-requests: write }`; drop
  `pull-requests: write` when `post-comment: false`.
- Runner tooling: Node.js (AI CLI), `python3`, and `gh` when posting — all
  present on GitHub-hosted runners. OBSERVED mode additionally bootstraps
  whatever the classified repo's own suite needs, best-effort from its
  lockfiles/CI config.
- Set a job `timeout-minutes` (the quickstart uses 30): installing deps and
  running a suite is slower than a diff-only review.

## Keep it decoupled

Run the classifier as its own workflow, in parallel with your build. Don't
`needs:` it from the build pipeline and don't make it a required check until
its 👍-rate has earned that — advisory first is the design.

## Local use

The engine runs standalone from a checkout of the repo being classified:

```bash
export AI_REVIEW_TOOL=claude
bash <path-to>/workflows/test-classifier/engine/bin/ai-test-classifier            # unpushed work, report-only
bash <path-to>/workflows/test-classifier/engine/bin/ai-test-classifier --pr 41 --post-comment
```

Flags and environment are documented in the
[engine README](../workflows/test-classifier/engine/README.md).
