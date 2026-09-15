# GitHub Action reference

`uses: navapbc/ai-common-workflows/workflows/security-compliance-review@<commit-sha>` — a composite action that
reviews a pull request and posts inline comments. Pin to a commit SHA
([why](security.md)).

## Requirements

- Check out the PR head before the action, with the base ref reachable:
  ```yaml
  - uses: actions/checkout@v7
    with: { ref: "${{ github.event.pull_request.head.sha }}" }
  ```
  The action runs `git fetch` for the base ref itself, then deepens history
  as needed to locate the branch point — the review diffs `base...HEAD` (only
  what this branch changed), which needs the merge base present.
  `fetch-depth: 0` skips that and is a belt-and-suspenders option for very
  large or long-lived branches; without a reachable merge base the action
  warns and falls back to a direct `base`→`HEAD` diff. For the strongest token
  isolation, add `persist-credentials: false` to the checkout so no token is
  left in `.git/config` during the AI phase (see [security.md](security.md)) —
  the base-ref fetch is a separate, AI-free step that authenticates with the
  `github-token` input, so private repositories keep working.
- Least-privilege permissions — `contents: read` (never write) plus
  `pull-requests: write` **only** if posting comments:
  ```yaml
  permissions: { contents: read, pull-requests: write }
  ```
  For a fully read-only run, set `post-comments: false` and gate on the
  `result` output; then `contents: read` alone suffices. See
  [security.md](security.md).
- Runner tooling: **Node.js** (for the AI CLI), and — when `post-comments` is
  true — **`gh`** and **`python3`** to post the review. All three are present
  on GitHub-hosted runners; on self-hosted runners, install them (or bake them
  into the runner image). The review runs natively; there is no bundled image
  providing these.

## Inputs

All inputs are active. Endpoint inputs apply per tool: `bedrock` → `claude` or
`codex`; `vertex` → `claude`; `azure` → `codex`; `copilot-provider-*` → `copilot`.

| Input | Default | Description |
|---|---|---|
| `ai-tool` | `claude` | `claude` \| `codex` \| `copilot` |
| `anthropic-api-key` | — | Anthropic key (claude, provider=api) |
| `openai-api-key` | — | OpenAI key (codex) |
| `github-token` | `${{ github.token }}` | Token to post the review (`pull-requests: write`) |
| `post-comments` | `true` | Post inline comments to the PR |
| `gate` | `false` | Fail the job on any non-APPROVE result |
| `dry-run` | `false` | Print the plan; no AI call |
| `pr-number` | event PR | Override the PR number |
| `profile` | `baseline` | Compliance profile: `baseline` \| `cms-ars`, a `skills/profiles/` name, or a custom profile directory path. The floor always applies; a profile only adds to it |
| `provider` | `api` | `api` \| `bedrock` \| `vertex` \| `azure` (bedrock→claude or codex; vertex→claude; azure→codex) |
| `model` | — | Model override; Bedrock model ID (bedrock; required for codex) or Azure deployment name (azure) |
| `aws-region` | — | Region for provider=bedrock (claude or codex) |
| `vertex-project-id` / `vertex-region` | — | provider=vertex |
| `azure-openai-endpoint` | — | Azure resource endpoint for provider=azure (e.g. `https://res.openai.azure.com`) |
| `azure-openai-api-key` | — | Azure OpenAI key for provider=azure |
| `azure-openai-api-version` | `2024-10-21` | Azure REST API version for provider=azure |
| `anthropic-base-url` / `openai-base-url` | — | Custom gateway endpoint |
| `copilot-provider-base-url` | — | ai-tool=copilot BYOK endpoint (`COPILOT_PROVIDER_BASE_URL`) |
| `copilot-provider-type` | — | ai-tool=copilot BYOK type: `openai` \| `azure` \| `anthropic` |
| `copilot-provider-api-key` | — | ai-tool=copilot BYOK model key (`COPILOT_PROVIDER_API_KEY`) |
| `copilot-model` | — | ai-tool=copilot BYOK model id (`COPILOT_MODEL`) |
| `adjudication` | `self` | `self` \| `independent` \| `off` |
| `adjudication-model` | — | Model for the independent pass only |
| `jobs` | `4` | Fan-out concurrency for large diffs |
| `batch-by` | `dir` | `dir` \| `file` fan-out batching |
| `batch-min-files` | `10` | Minimum changed files before fanning out |
| `context-budget` | `15` | Ceiling on context files the model may load beyond the diff, stated to it directly in the prompt. Fan-out workers narrow it per batch. |
| `install-cli` / `cli-version` | `true` / `latest` | npm-install the AI CLI on the runner |

## Outputs

| Output | Description |
|---|---|
| `result` | `APPROVE` \| `COMMENT` \| `REQUEST_CHANGES`. Always set when the review ran. An empty diff yields `APPROVE` (nothing to flag). A findings file that exists but cannot be parsed fails the step rather than reporting `APPROVE`. |
| `review-json` | Path to the findings JSON on the runner |

## Advisory vs gating

By default the review is **advisory**: findings post as comments and the job
stays green. Set `gate: true` to fail the job on any non-APPROVE result — then
the job can be a required check. See
[`examples/workflows/ai-security-compliance-review-gating.yml`](../examples/workflows/ai-security-compliance-review-gating.yml).

## Read-only mode (no repository writes)

To run with **no write permission at all**, set `post-comments: false` and act
on the `result` output (e.g. combine with `gate: true` to fail the check
without commenting). The token then needs only `contents: read`, and the
action never calls the PR-write API. Useful where posting bot comments is
disallowed or the token can't be granted `pull-requests: write`.

## Adjudication and fan-out

- **Adjudication** cuts false positives. `self` (default) folds a skeptical
  self-critique into the single review call. `independent` runs a second
  fresh-agent pass over the findings before posting (optionally on a different
  `adjudication-model`); it roughly doubles cost on finding-bearing PRs but is
  the strongest filter. `off` reports raw first-pass findings.
- **Fan-out**: when a PR changes at least `batch-min-files` files, the diff is
  split into batches (`batch-by`) and reviewed by up to `jobs` concurrent AI
  calls, then merged and deduplicated into one review. Small PRs run as a
  single call.

## Idempotent re-runs

Before posting, the action fetches its own prior inline comments and drops any
finding already posted on an unchanged line (keyed by path, line, and
perspective). Editing a commented line outdates the old comment, so the finding
re-posts automatically. A re-run with nothing new posts nothing.

## Troubleshooting

| Symptom | Cause / fix |
|---|---|
| Job skipped with a notice | Not a `pull_request` event and no `pr-number` given. |
| `HTTP 422` from GitHub | An inline comment landed off the diff. The action already filters these and falls back to a summary-only review; if it persists, the diff fetch likely failed — check token scope. |
| `HTTP 401/403` from GitHub | Token lacks `pull-requests: write`. |
| No marker / empty review | The AI CLI errored. The run fails safe (exit 1) — the action has no override for this. Check the CLI install and endpoint config. |
| Bedrock auth errors | No AWS credentials reached the runner. Use `aws-actions/configure-aws-credentials` (OIDC) before the action. |
