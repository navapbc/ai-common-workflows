# Security & supply chain

These components run code in your CI with your repository contents and
credentials in scope. Treat them like any other third-party CI dependency.
This page is the trust model and the adoption checklist.

## What executes where

The review runs the chosen AI CLI natively on your runner/agent, in two
phases:

| Phase | What runs | Network it needs | Credentials in scope |
|---|---|---|---|
| Collect | `git diff` of `base...HEAD` (merge-base, i.e. only what this branch changed) | the SCM, to fetch the base ref | the SCM token (trusted step, no AI) |
| Review | the AI CLI reads the diff, emits findings | the LLM endpoint | the LLM key **only** |
| Post | `gh` turns findings into a PR review | the SCM API | the SCM token |

The AI CLI is agentic and reads untrusted PR content, so the realistic threat
is prompt injection in a PR steering the CLI to exfiltrate code or
credentials, or to abuse the SCM token. Three things bound that:

1. **The SCM token is not in the review phase.** The Action and the plugin run
   the AI CLI as one process whose environment has no `GITHUB_TOKEN`/`GH_TOKEN`,
   then post in a *separate* process that holds the token. An injected agent
   reading the diff therefore has no repo-write token in its process tree
   (nor via `/proc/<ancestor>/environ`). Two caveats:
   - **`copilot`** authenticates its model with a GitHub token, so that backend
     alone carries one during the AI phase — prefer `claude`/`codex` if this
     matters, and scope the token tightly regardless.
   - If `actions/checkout` **persisted credentials** (its default), a token
     sits in `.git/config` and the read-only diff phase can read it. Check out
     with `persist-credentials: false` for full isolation. The action's
     base-ref fetch still works: that fetch is a trusted step with no AI in
     it, so it authenticates with the `github-token` input via a
     per-invocation credential helper (the token stays out of argv and is
     never written to `.git/config`, so the AI phase still sees a
     credential-free repo). Alternatively check out with `fetch-depth: 0`,
     which makes the base ref present up front and needs no fetch at all.
2. **Least-privilege credentials** (below) — so even a fully subverted CLI
   can do little with what it *can* reach.
3. **Egress control on the runner** (below) — so data can't leave to an
   arbitrary destination.

> **On the built-in sandbox.** An earlier design ran the review in a Docker
> container with default-deny egress. It's not in this release — it was
> unverified with real CLIs and broke on common container-in-container CI
> topologies (see `engines/_common/sandbox/README.md`). Egress control is therefore
> **your infrastructure's responsibility** today; a hardened built-in sandbox
> is on the roadmap. This is the honest posture: the tool does not claim an
> egress boundary it hasn't proven.

## Least-privilege credentials — do this

This is the highest-leverage control and it is **imperative**, not optional.

### The SCM token

The action/plugin needs to *read* the code and *post a review*. It never
writes repository contents.

- **GitHub Action** — scope the built-in `GITHUB_TOKEN` with a `permissions:`
  block; do not use a PAT. The maximum it should ever have is:
  ```yaml
  permissions:
    contents: read          # checkout + git diff
    pull-requests: write     # post the review (only if post-comments: true)
  ```
  `contents` never needs `write`. If you set `post-comments: false` and gate
  on the `result` output instead, drop to **`contents: read` only** (or
  `pull-requests: read`) — a fully read-only run.

- **Jenkins** — there is no ambient workflow token, so use a **fine-grained
  GitHub PAT**, scoped to *only the specific repositories* with **Pull
  requests: Read and write** and **Contents: Read**, nothing else. Do **not**
  use a classic PAT — its `repo` scope grants broad access to everything the
  owning account can reach. Better still, use a **GitHub App** installation
  token (short-lived, installed per repo). Store it as a Secret-text
  credential and reference it by ID.

### The LLM credential (Bedrock / Vertex / Azure)

Scope the model credential to *invoking the one model*, not to the service.

- **Bedrock (imperative):** the IAM role should allow only
  `bedrock:InvokeModel` (and `bedrock:InvokeModelWithResponseStream`) on the
  specific model ARN(s) you use — never `bedrock:*` or `*`. Assume it via
  **GitHub OIDC** (no long-lived keys) with a trust policy whose condition
  pins your repo and ref, e.g. `token.actions.githubusercontent.com:sub` =
  `repo:ORG/REPO:ref:refs/heads/main`. Example policy:
  ```json
  {
    "Effect": "Allow",
    "Action": ["bedrock:InvokeModel", "bedrock:InvokeModelWithResponseStream"],
    "Resource": "arn:aws:bedrock:us-east-1::foundation-model/anthropic.claude-*"
  }
  ```
- **Vertex:** grant the workload-identity service account only the
  **Vertex AI User** role (or a custom role with just
  `aiplatform.endpoints.predict`), scoped to the project — not Editor/Owner.
- **Azure OpenAI:** scope the key (or a managed identity via a gateway) to the
  one deployment, and put the resource behind a Private Endpoint / firewall so
  it is not publicly reachable. Rotate the key independently of other secrets.
- **Public API keys:** use a key dedicated to this workload so it can be
  rotated/revoked independently, and store it as a secret, never in the
  workflow file.

## Egress control on the runner

Because there's no built-in sandbox, constrain egress at the infrastructure
layer around the runner/agent:

- **Self-hosted runners / Jenkins agents in a VPC:** restrict the security
  group / network policy / egress proxy to the hosts the job legitimately
  needs — the LLM endpoint, your SCM API, and the runner's own control plane.
- **GitHub-hosted runners:** you can't lock the network, so assume the diff
  reaches the LLM you point at. If that's unacceptable, use an in-boundary LLM
  **and** in-boundary compute (next section).
- Either way, **placement matters**: an in-boundary LLM (e.g. Bedrock in your
  accreditation boundary) only keeps code in-boundary if the review also runs
  in-boundary. See [private-endpoints.md](private-endpoints.md).

## Supply-chain: review and pin

1. **Review the code before adopting.** The engine is deliberately small and
   readable — [`engines/`](../docs/architecture.md) is roughly 2,000 lines of
   bash on the review path plus `github_payload.py` and `fold_review_json.py`,
   and about 1,200 lines of rubric markdown that the engine inlines into the
   prompt (worth reading too: it is what the model is actually told to do).
   Read it, the
   [action](../workflows/security-compliance-review/action.yml), and (for
   Jenkins) the plugin, the way you'd review any dependency that runs in your
   pipeline. Re-review on upgrade by diffing tags.

2. **Pin to an immutable reference — a commit SHA, never a tag.**
   A git tag is a mutable pointer: it can be deleted and re-created against a
   different commit, and nothing in the consuming workflow would notice. A
   release can be edited or replaced the same way. A commit SHA is the only
   reference that names fixed content, so it is the only acceptable pin —
   including for the instruction sync, not just the Action.
   - **GitHub Action:** pin `uses:` to a full 40-character commit SHA, not a
     tag or branch:
     ```yaml
     - uses: navapbc/ai-common-workflows/workflows/security-compliance-review@<40-char-sha> # v1.0.0
     ```
     The `# vX.Y.Z` comment records which release the SHA is.
   - **Finding the SHA for a release** — the release page shows it, or:
     ```bash
     gh api repos/navapbc/ai-common-workflows/git/ref/tags/v1.0.0 --jq .object.sha
     ```
     Paste that, and record the release in the trailing comment. Resolve the
     tag **once, deliberately**, at the moment you choose to upgrade; never let
     a workflow resolve it at run time.
   - **Keeping the pin current without re-typing SHAs** — Dependabot updates
     SHA-pinned `uses:` references and rewrites the `# vX.Y.Z` comment with
     them, so a pinned action still gets upgrade PRs you review like any other:
     ```yaml
     # .github/dependabot.yml
     version: 2
     updates:
       - package-ecosystem: github-actions
         directory: "/"
         schedule: { interval: weekly }
     ```
     It does not apply to the instruction sync's `ACW_REF`, which tracks
     `main` on purpose — see
     [the instruction sync's one exception](#the-instruction-syncs-one-exception).
   - **Jenkins plugin:** install a specific released `.hpi` and **verify its
     build provenance** before uploading (requires `gh` ≥ 2.49):
     ```bash
     gh attestation verify <file>.hpi -R navapbc/ai-common-workflows
     ```
     The release workflow signs an [artifact attestation](https://docs.github.com/actions/security-for-github-actions/using-artifact-attestations)
     (Sigstore, logged in the Rekor transparency log) binding each `.hpi`
     digest to this repo, the release workflow, and the tagged commit — a
     swapped release asset cannot carry valid provenance. The `.sha256`
     sidecars cover download integrity only; because they live in the same
     release as the artifact, they are **not** an authenticity check on their
     own. Jenkins performs no signature verification on manually uploaded
     plugins, so this pre-install check *is* the verification. Upgrades are a
     manual admin action, never automatic.

   **Honest limits:** provenance attests whatever the workflow built — it does
   not defend against a compromised repo or workflow. Upstream of it, release
   tags should be protected (a ruleset on `jenkins-plugin-v*` preventing tag
   moves/deletion) and ideally signed by the releasing maintainer
   (`git tag -s`), so the tag itself has human provenance.

3. **Skip drafts, and remember the network boundary.** On the public API, PR
   diffs leave your perimeter — point at Bedrock/Vertex/Azure OpenAI/an internal
   gateway if that matters.

## This repository contains fake credentials on purpose

The detection corpus and the bats fixtures hold credential-shaped strings —
including AWS's published `AKIAIOSFODNN7EXAMPLE` pair and a synthetic
AWS-shaped key — because that is what you hand a security reviewer to check
that it notices. `tests/corpus/01-hardcoded-aws-key` in particular *must* look
like a live key: when it used AWS's documented example, the reviewer correctly
rated it low and the case measured the wrong thing.

Consequently `.github/secret_scanning.yml` excludes `tests/corpus/**`,
`tests/fixtures/**` and `tests/bats/**` from secret scanning. An alert stream
that is always noise is one people stop reading, and the next alert might be
real.

That reasoning is sound and the exclusion is currently unnecessary, which is
worth stating rather than leaving as an implication. Measured on 2026-09-30
with secret scanning enabled: case 01's full AWS pair, pushed as a new blob
into `engines/**` — deliberately *not* excluded — raised no alert. GitHub's
AWS detector is provider-validated, and a fixture cannot be confirmed live.
Pattern-only detection is `secret_scanning_non_provider_patterns`, a paid
Secret Protection feature that cannot be enabled on this repo today; the API
accepts the request with HTTP 200 and leaves it `disabled`, as it does for
`secret_scanning_validity_checks`.

So the exclusion is insurance against a licensing change, not a response to
noise anyone has seen. It stays for that reason. The same measurement showed
push protection — which `paths-ignore` does **not** govern — does not reject
these fixtures either; see [tests/corpus/README.md](../tests/corpus/README.md)
for what to do if that ever changes.

The exclusion is a blind spot, so it has a compensating control.
`tests/python/test_secret_fixtures.py` fails when:

- a credential-shaped literal appears **outside** those paths — notably in
  `engines/` or `workflows/`, which ship to consumers and where a reviewer
  might otherwise assume any key in this repo is a fixture;
- an excluded path no longer holds such a fixture, so the exclusion cannot
  quietly widen past what it is for. Prose mentions in Markdown do not count as
  justification, or the rubric's own discussion of the example key would bless
  an exemption for the whole engine tree;
- an Anthropic key, GitHub PAT, OpenAI key or private-key block appears
  **anywhere at all**, excluded paths included. Nothing here needs one, so a
  match is a leak rather than a fixture — and the exemption must not become the
  place one hides.

If you add a fixture that needs to look like a secret, put it under one of
those paths. If you are tempted to add one elsewhere, that is the control
working.

## Copilot-instructions sync (pull model)

Copilot instruction files are distributed by a **pull** workflow that each
consumer runs in its own repo ([`examples/workflows/copilot-instructions-sync.yml`](../examples/workflows/copilot-instructions-sync.yml)),
with credentials scoped to `contents: write` + `pull-requests: write` on
**its own repo only**. There is no cross-repo credential and
`ai-common-workflows` keeps no list of consumers. By default the built-in
`GITHUB_TOKEN` pushes the branch and a human opens the PR (GitHub blocks PR
creation by workflows unless a repo toggle is enabled); an optional
`COPILOT_SYNC_TOKEN` automates PR creation without granting any workflow
approve rights. Scope that PAT to **`Pull requests: Read and write` only** — it
is read solely by `gh pr list` / `gh pr create`, while the branch push
authenticates as the built-in `GITHUB_TOKEN` that `actions/checkout` persisted,
so granting it `Contents` would let it write to any branch for no gain. Issue
it from a dedicated **machine user** rather than a person's account: it keeps the credential's reach to the repos the sync touches
instead of everything one human can read, and the automation does not break
when that human's access changes. `ACW_REF` is the one ref in this project that is **not** pinned — see
[the instruction sync's one exception](#the-instruction-syncs-one-exception).
See also [copilot-instructions.md](copilot-instructions.md).

### Releases exist to help you find a SHA

`navapbc/ai-common-workflows` publishes GitHub Releases on `vX.Y.Z` tags, and
the notes carry the exact `uses:` line with the 40-character SHA to paste.

There is **no moving `vX` alias**, on purpose. A `@v1` that follows the newest
release is convenient and is exactly the mutable pointer this section warns
about: whoever can push that tag can change the code every `@v1` consumer runs.
Pin the SHA from the release notes; the trailing `# v1.0.0` comment keeps the
upgrade a reviewable one-line diff. See [releasing.md](releasing.md).

### The AI CLI is pinned too

Pinning the action is not the whole supply chain. The job also `npm install -g`s
the AI CLI on the runner, and that CLI is the **agentic** part: it reads the
untrusted diff with shell and file-read tools. For a while it was installed at
`latest`, which made it simultaneously the least-pinned and highest-privilege
component in the run — a SHA-pinned action fetching a floating agent.

`cli-version` now defaults to a version pinned inside the action
(`workflows/_shared/lib/ci.sh`, the `_AI_CLI_VER_*` values), per tool.

Exact versions, not ranges — and the reasoning differs from the rule above.
An npm version is immutable because npm **forbids republishing one**, so
`@scope/pkg@1.2.3` gives the guarantee a git tag cannot. `^1.2.3` does not: it
resolves at install time, which is `latest` with extra steps.

Two consequences worth planning for:

- **Nothing bumps these for you.** They are strings in bash, so Dependabot
  cannot see them, and a pin that is never bumped is a CLI that never gets a
  security fix. Put a recurring review against it.
  `tests/python/test_cli_pin_hygiene.py` catches a pin going *floating*; it
  cannot catch one going *stale*.
- **`cli-version: latest` still works** if you want it, and logs a warning
  saying so. It is a choice now rather than a default.

### The instruction sync's one exception

Everything this project tells you to pin, you pin to a full commit SHA. The
Copilot **instruction sync** is the single exception: its `ACW_REF` defaults to
`main`.

The pinning rule exists because `uses: org/repo@ref` runs that repository's
code inside your job, with your token in scope — so a mutable ref is a mutable
execution path. The instruction sync does none of that. It copies
`ai-review-*.instructions.md` into a branch and opens a pull request. The only
`uses:` in it is `actions/checkout`, which is SHA-pinned like everything else
that runs.

**The PR is the gate, and it is a stronger one.** The sync never pushes to your
default branch. Every change arrives as a reviewable PR whose diff is plain
English your team reads before merging. A SHA gates a forty-character value
nobody inspects; the PR gates the content itself. Requiring both would put a
weak unread gate in front of a strong read one — and pinning also makes the
sync's schedule inert, because a fixed ref never produces a diff, so updates
would only ever arrive when someone remembered to edit the line.

The residual risk is a compromised upstream plus a reviewer who merges without
reading. That is real, and it is why the files are prose rather than anything
executable: a malicious instruction has to survive a human reading English.
Worst case it degrades Copilot's review comments — advisory text — rather than
running code or reaching a credential.

**If your program requires a pin anyway**, set `ACW_REF` to a 40-character
commit SHA. Updates then arrive only when someone edits that line, so put a
calendar reminder against it or the instructions will quietly rot.
