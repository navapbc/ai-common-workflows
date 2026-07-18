# GitHub Action reference

`uses: navapbc/ai-reusable-workflows@<commit-sha>` — a composite action that
reviews a pull request and posts inline comments. Pin to a commit SHA
([why](security.md)).

## Requirements

- Check out the PR head before the action, with the base ref reachable:
  ```yaml
  - uses: actions/checkout@v4
    with: { ref: "${{ github.event.pull_request.head.sha }}" }
  ```
  The action runs `git fetch` for the base ref itself; `fetch-depth: 0` is a
  belt-and-suspenders option for very large PRs.
- Least-privilege permissions — `contents: read` (never write) plus
  `pull-requests: write` **only** if posting comments:
  ```yaml
  permissions: { contents: read, pull-requests: write }
  ```
  For a fully read-only run, set `post-comments: false` and gate on the
  `result` output; then `contents: read` alone suffices. See
  [security.md](security.md).
- Node.js on the runner (for the AI CLI) — present on GitHub-hosted runners.

## Inputs

All inputs are active. Endpoint inputs beyond `api` apply to `claude` only.

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
| `provider` | `api` | `api` \| `bedrock` \| `vertex` |
| `model` | — | Model override; Bedrock model ID for provider=bedrock |
| `aws-region` | — | Region for provider=bedrock |
| `vertex-project-id` / `vertex-region` | — | provider=vertex |
| `anthropic-base-url` / `openai-base-url` | — | Custom gateway endpoint |
| `adjudication` | `self` | `self` \| `independent` \| `off` |
| `adjudication-model` | — | Model for the independent pass only |
| `jobs` | `4` | Fan-out concurrency for large diffs |
| `batch-by` | `dir` | `dir` \| `file` fan-out batching |
| `batch-min-files` | `10` | Minimum changed files before fanning out |
| `context-budget` | `15` | Context files loaded per AI call |
| `install-cli` / `cli-version` | `true` / `latest` | npm-install the AI CLI on the runner |

## Outputs

| Output | Description |
|---|---|
| `result` | `APPROVE` \| `COMMENT` \| `REQUEST_CHANGES` |
| `review-json` | Path to the findings JSON on the runner |

## Advisory vs gating

By default the review is **advisory**: findings post as comments and the job
stays green. Set `gate: true` to fail the job on any non-APPROVE result — then
the job can be a required check. See
[`examples/workflows/ai-pr-review-gating.yml`](../examples/workflows/ai-pr-review-gating.yml).

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
| No marker / empty review | The AI CLI errored. The run fails safe (exit 1) unless `--no-block`. Check the CLI install and endpoint config. |
| Bedrock auth errors | No AWS credentials reached the runner. Use `aws-actions/configure-aws-credentials` (OIDC) before the action. |
