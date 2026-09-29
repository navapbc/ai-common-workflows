# GitHub Action reference

`uses: navapbc/ai-common-workflows/workflows/security-compliance-review@<commit-sha>` — a composite action that
reviews a pull request and posts inline comments. Pin to a commit SHA
([why](security.md)).

## Requirements

- Check out the PR head before the action, with the base ref reachable:
  ```yaml
  - uses: actions/checkout@3d3c42e5aac5ba805825da76410c181273ba90b1 # v7.0.1
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

## Scope

This complements SAST, dependency/CVE scanning and secret scanning — it does
not replace any of them. It is diff-scoped and probabilistic; a clean review is
one reviewer's opinion, not evidence that a change is safe. See
[Run it alongside your scanners](security-compliance-review.md#run-it-alongside-your-scanners-not-instead-of-them)
for the division of labor, and note the posted review carries the same caveat
so a PR reader sees it without opening these docs.

## Inputs

There are 34 of them and **31 are optional**. Almost every team needs exactly
three:

```yaml
      - uses: navapbc/ai-common-workflows/workflows/security-compliance-review@<sha>
        with:
          ai-tool: claude
          anthropic-api-key: ${{ secrets.ANTHROPIC_API_KEY }}
          profile: base            # add ,cms-ars if you track CMS ARS
```

**Ignore the rest until you have a reason to reach for one.** The groups below
are ordered by when that tends to happen — most teams never get past the first
two. Endpoint inputs apply per tool: `bedrock` → `claude` or `codex`;
`vertex` → `claude`; `azure` → `codex`; `copilot-provider-*` → `copilot`.

### Getting it running

| Input | Default | Description |
|---|---|---|
| `ai-tool` | `claude` | `claude` \| `codex` \| `copilot` |
| `anthropic-api-key` | — | Anthropic key (claude, provider=api) |
| `openai-api-key` | — | OpenAI key (codex) |
| `profile` | `base` | Ordered rubric sources, first entry `base` or `none`: `base,cms-ars`. Later entries add and win conflicts — see [profiles.md](profiles.md) |
| `github-token` | `${{ github.token }}` | Token to post the review (`pull-requests: write`) |

### Deciding how loud it is

Reach for these once you have seen a few real reviews.

| Input | Default | Description |
|---|---|---|
| `post-when-clean` | `false` | Post a review when there are no findings. Off by default: the job's own check already shows the review ran, so a clean PR gets no comment. Turn it on for visible per-PR evidence. Findings always post, and a `REQUEST_CHANGES` review always posts |
| `max-comments` | `50` | Limit on inline comments per review (`0` = no limit). Over the limit, the highest-severity findings stay inline and the rest are listed in the review body under a heading saying the limit was reached — nothing is dropped, and the gate still accounts for every finding. The body list can include HIGH or CRITICAL findings: the limit is on volume, not severity |
| `gate` | `false` | Fail the job on HIGH or CRITICAL findings. MEDIUM and LOW still post as comments |
| `post-comments` | `true` | Post inline comments to the PR |
| `adjudication` | `off` | False-positive filter: `off` \| `self` \| `independent`. Off by default — see [Adjudication](#adjudication-and-fan-out) for why, and when to turn it on |

### Keeping the model and data in your boundary

Only needed if you cannot use the public API — see
[private-endpoints.md](private-endpoints.md).

| Input | Default | Description |
|---|---|---|
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

### Tuning cost and throughput on large diffs

Defaults are sensible; change them when you have measured a reason to. Each of
these moves your spend — `--dry-run` prints the expected call count.

| Input | Default | Description |
|---|---|---|
| `jobs` | `4` | Fan-out concurrency for large diffs |
| `batch-by` | `dir` | `dir` \| `file` fan-out batching |
| `batch-min-files` | `10` | Minimum changed files before fanning out |
| `context-budget` | `15` | Ceiling on context files the model may load beyond the diff, stated to it directly in the prompt. Fan-out workers narrow it per batch |
| `adjudication-model` | — | Model for the independent pass only. Same provider and endpoint as the first pass — see [Adjudication](#adjudication-and-fan-out) |

### Debugging and plumbing

| Input | Default | Description |
|---|---|---|
| `dry-run` | `false` | Print the plan, the batch routing and the expected call count; no AI call |
| `pr-number` | event PR | Override the PR number. Off a `pull_request` event, set `base-ref` too |
| `base-ref` | event base | Branch to diff against. Required with `pr-number` on a non-`pull_request` event — see [Re-running a review](#re-running-a-review) |
| `install-cli` / `cli-version` | `true` / `latest` | npm-install the AI CLI on the runner |

## Outputs

| Output | Description |
|---|---|
| `result` | `APPROVE` \| `COMMENT` \| `REQUEST_CHANGES`. Always set when the review ran. An empty diff yields `APPROVE` (nothing to flag). A findings file that exists but cannot be parsed fails the step rather than reporting `APPROVE`. |
| `review-json` | Path to the findings JSON on the runner |

## Advisory vs gating

By default the review is **advisory**: findings post as comments and the job
stays green.

```yaml
          gate: true      # fail the job on HIGH or CRITICAL findings
```

That makes the job usable as a required status check. See
[`examples/workflows/ai-security-compliance-review-gating.yml`](../examples/workflows/ai-security-compliance-review-gating.yml).

`gate: true` blocks on **HIGH and CRITICAL only**. MEDIUM and LOW still post as
inline comments — gating changes what fails the build, never what gets
reported. That is deliberate: the review emits a finding-bearing result for a
single LOW observation, so blocking on everything would fail merges on nits.

The HIGH floor is fixed, not configurable. If a team ever needs a different
line, that should arrive as its own clearly named input rather than as a second
kind of value in this one.

Two behaviours to know before relying on it, both chosen so the gate cannot
silently pass:

- A finding whose severity is missing or unrecognized counts as **blocking**,
  with a warning naming how many. An unreadable severity never buys a pass.
- The gate is evaluated against the engine's own findings JSON, so a finding
  that could not be anchored to a diff line still counts. Whether a comment
  could be placed does not change the verdict.

This is also the **only** path in this repo that can gate. Copilot's native
review (see [copilot-review-setup.md](copilot-review-setup.md)) posts comments
but submits no blocking review and emits no status check, so there is nothing
there for a ruleset to require.

## Read-only mode (no repository writes)

To run with **no write permission at all**, set `post-comments: false` and act
on the `result` output (e.g. combine with `gate: true` to fail the check
without commenting). The token then needs only `contents: read`, and the
action never calls the PR-write API. Useful where posting bot comments is
disallowed or the token can't be granted `pull-requests: write`.

## Adjudication and fan-out

- **Adjudication is off by default.** `self` folds a skeptical self-critique
  into the single review call — no extra call, but real output tokens.
  `independent` runs a second fresh-agent pass over the findings before posting
  (optionally on a different `adjudication-model`); it roughly doubles cost on
  finding-bearing PRs and is the strongest filter. `off` reports raw first-pass
  findings.

  **Why off:** a current model verifies its own work without being told to, and
  telling it to costs tokens and causes over-verification. Anthropic's Opus 5
  migration guidance names both modes almost verbatim and says to delete that
  scaffolding — "removing them reduces over-verification with no capability
  regression." Measured against `tests/corpus` before switching, one run each:
  `self` suppressed **nothing**. The negative control produced the same seven
  findings in both modes at the same severities, `self` produced two *more*
  unexpected findings overall, and it took longer. Its only effect anywhere was
  one correct severity downgrade.

  **When to turn it on:** your tool is `codex` or `copilot`, or your model is
  pinned to an older version for ATO reasons — the guidance is
  Anthropic-model-specific and does not cover those. Or you measure a benefit
  on your own code, which is what the corpus is for. Nothing about the modes
  changed; only which one you get by default.
- **What `adjudication-model` can vary.** The second opinion runs on the same
  CLI, the same provider and the same endpoint as the first pass — only the
  model changes. So it picks another Bedrock model ID, another Vertex model,
  another Anthropic or OpenAI model, but not a different provider and not a
  different vendor's CLI. Cross-lab adjudication is not supported; a custom
  gateway that routes by model name is the nearest thing available.
- **`provider: azure` is the exception.** Azure resolves the deployment from
  the request URL, not from a model flag, so the engine rebuilds the URL for
  the adjudication call. That works when it built the URL from
  `azure-openai-endpoint`. If you supply `openai-base-url` yourself, the URL is
  opaque and cannot be rewritten, so pairing it with `adjudication-model`
  **fails at startup** rather than quietly adjudicating on the first-pass
  deployment.
- **Fan-out**: when a PR changes at least `batch-min-files` files, the diff is
  split into batches (`batch-by`) and reviewed by up to `jobs` concurrent AI
  calls, then merged and deduplicated into one review. Small PRs run as a
  single call.

## Clean PRs stay quiet

When the review finds nothing, it posts nothing. The job's own check already
shows that it ran and passed, and a reviewer that acknowledges every green PR
is a notification per PR per push — which is how teams start ignoring it, or
switch it off. The run log says what happened:

```
[security-compliance-review] No findings; not posting a review. The job's own
check is the signal that it ran. Set post-when-clean /
AI_REVIEW_POST_WHEN_CLEAN=true to post an approval anyway.
```

Set `post-when-clean: true` to get the approval posted on the PR instead. The
reason to want it is evidence: a check status is ephemeral in the UI and tied
to a run that can age out, whereas a review comment is part of the PR record —
which is the difference between "we run a security review" and being able to
show it per PR at assessment time.

Two things are never suppressed, whatever the setting:

- **Any finding.** "Clean" means nothing to report at all. A finding that could
  not be anchored to a line is still a finding; it goes in the review body.
- **A review that asks for changes.** `REQUEST_CHANGES` carrying no postable
  finding means something went wrong, not that the diff is fine. Swallowing it
  would leave an author with a blocked PR and no reason given.

## Forked pull requests

A `pull_request` from a fork is **skipped, with a notice**:

```
Skipping review: pull request #42 comes from a fork. GitHub withholds secrets
and issues a read-only token for fork pull requests, so the review cannot run
or post. To review this PR, run the workflow manually with pr-number and
base-ref.
```

You do not need an `if:` guard for this; the action handles it. Nothing about
same-repo pull requests changes.

### Why it cannot simply work

Two independent blockers, and neither has a configuration that gets around it:

- **No secrets.** `secrets.ANTHROPIC_API_KEY` renders empty on a fork run, so
  there is no model credential. `id-token: write` is unavailable too, so
  federating into Bedrock or Vertex does not rescue it.
- **A read-only `GITHUB_TOKEN`.** Even with a credential, posting returns 403.
  The `permissions:` block cannot grant write on a fork pull request.

Previously the run failed with `requires ANTHROPIC_API_KEY` — a red check on
every external contribution, telling the contributor nothing they could act on.

### To review one anyway

Run it by hand, which executes in your repository's context with secrets and a
write token. That also puts a human between an untrusted diff and your
credentials, which is the point:

```bash
gh workflow run ai-security-compliance-review.yml -f pr=42
```

See [Reviewing a PR from a manual trigger](#reviewing-a-pr-from-a-manual-trigger)
for the dispatch workflow, and
[`examples/workflows/ai-security-compliance-review-manual.yml`](../examples/workflows/ai-security-compliance-review-manual.yml).

### Do not reach for `pull_request_target`

It is the usual workaround and it is the wrong one here. It runs with your
secrets and a write token in the base-repo context, and this action then points
an **agentic AI CLI with shell and file-read tools** at the contributor's code.
Prompt injection in a source file, aimed at a token sitting in the same
environment, is a different class of risk from a scanner matching patterns —
and it is the specific threat [security.md](security.md) is built around. A
second `workflow_run` stage can be made safe, because the engine already runs
the model with no SCM token and posts from a separate fixed script, but it is
enough complexity that it should be written once and carefully rather than
copied from a doc. Ask if you need it.

## Re-running a review

### What a second pass does to the comments

Before posting, the action fetches its own prior inline comments and drops any
finding already posted on an unchanged line (keyed by path, line, and
perspective). Editing a commented line outdates the old comment, so the finding
re-posts automatically. A re-run with nothing new posts nothing, and says so:

```
[security-compliance-review] Suppressed 3 finding(s) already posted on unchanged lines.
[security-compliance-review] All findings already posted on unchanged lines; nothing new to comment.
```

The title is deliberately not part of the key, because runs are
non-deterministic and reword the same issue. That is also why a second pass is
worth running at all: anything the first pass missed still posts, and anything
it already said stays said once. To force a full re-post — to compare two
complete passes — delete the existing review comments first; the dedup anchors
on live comments carrying the attribution marker.

### Re-running an existing run

`gh run rerun <run-id>` (or **Re-run all jobs**) replays the original event
payload, so the PR number and base ref are still there and nothing in the
workflow needs to change. This is the path for a second pass on a PR that has
already been reviewed.

### Reviewing a PR from a manual trigger

On any event other than `pull_request` there is no payload to read the context
from, so pass **both** halves — `pr-number` and `base-ref` — and check the PR
head out yourself. One without the other does not work: `pr-number` alone fails
with `Could not determine the PR base ref`, and `base-ref` alone skips the job.

```yaml
on:
  workflow_dispatch:
    inputs:
      pr:
        description: "PR number to review"
        required: true

permissions:
  contents: read
  pull-requests: write

jobs:
  review:
    runs-on: ubuntu-latest
    steps:
      - id: meta
        env:
          GH_TOKEN: ${{ secrets.GITHUB_TOKEN }}
        run: |
          gh pr view "${{ inputs.pr }}" --repo "${{ github.repository }}" \
            --json baseRefName -q '"base=" + .baseRefName' >>"${GITHUB_OUTPUT}"

      - uses: actions/checkout@3d3c42e5aac5ba805825da76410c181273ba90b1 # v7.0.1
        with:
          ref: refs/pull/${{ inputs.pr }}/head
          fetch-depth: 0              # the diff needs the base ref present
          persist-credentials: false

      - uses: navapbc/ai-common-workflows/workflows/security-compliance-review@<sha>
        with:
          ai-tool: claude
          anthropic-api-key: ${{ secrets.ANTHROPIC_API_KEY }}
          pr-number: ${{ inputs.pr }}
          base-ref: ${{ steps.meta.outputs.base }}
```

`fetch-depth: 0` matters here: the action's own base-ref fetch relies on the
credential the workflow token provides, and a manual run against an older PR may
need more history than the default shallow clone has. The same two inputs work
on `schedule` and `issue_comment` triggers.

Copy-paste version:
[`examples/workflows/ai-security-compliance-review-manual.yml`](../examples/workflows/ai-security-compliance-review-manual.yml).

## Troubleshooting

| Symptom | Cause / fix |
|---|---|
| Job skipped with a notice | Not a `pull_request` event and no `pr-number` given. |
| Job skipped on an external contribution | Expected — fork pull requests cannot carry secrets or a write token. See [Forked pull requests](#forked-pull-requests). |
| No comment on a PR with no issues | Expected. See [Clean PRs stay quiet](#clean-prs-stay-quiet); set `post-when-clean: true` to post an approval. |
| `Could not determine the PR base ref` | `pr-number` was set off a `pull_request` event without `base-ref`. Pass both. |
| `HTTP 422` from GitHub | An inline comment landed off the diff. The action already filters these and falls back to a summary-only review; if it persists, the diff fetch likely failed — check token scope. |
| `HTTP 401/403` from GitHub | Token lacks `pull-requests: write`. |
| No marker / empty review | The AI CLI errored. The run fails safe (exit 1) — the action has no override for this. Check the CLI install and endpoint config. |
| Bedrock auth errors | No AWS credentials reached the runner. Use `aws-actions/configure-aws-credentials` (OIDC) before the action. |
