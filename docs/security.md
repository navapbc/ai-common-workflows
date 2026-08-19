# Security & supply chain

These components run code in your CI with your repository contents and
credentials in scope. Treat them like any other third-party CI dependency.
This page is the trust model and the adoption checklist.

## What executes where

The review runs the chosen AI CLI natively on your runner/agent, in two
phases:

| Phase | What runs | Network it needs | Credentials in scope |
|---|---|---|---|
| Collect | `git diff` against the base ref | none (base ref fetched at checkout) | none |
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
     with `persist-credentials: false` for full isolation; the action fetches
     the base ref itself, so this generally just works.
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
   readable — [`engines/`](../docs/architecture.md) is a few hundred lines of bash
   plus `github_payload.py` and `fold_review_json.py`. Read it, the
   [action](../workflows/security-compliance-review/action.yml), and (for
   Jenkins) the plugin, the way you'd review any dependency that runs in your
   pipeline. Re-review on upgrade by diffing tags.

2. **Pin to an immutable reference.**
   - **GitHub Action:** pin `uses:` to a full 40-character commit SHA, or to a
     `vX.Y.Z` release tag. This repository does not move these references:
     ```yaml
     - uses: navapbc/ai-common-workflows/workflows/security-compliance-review@<40-char-sha> # v1.0.0
     ```
     The `# vX.Y.Z` comment records which release the SHA is.

     The `@vX` alias, for example `@v1`, moves. This is intentional. The alias
     points to the newest stable `X.Y.Z` release. Therefore a new release
     changes the code that your job runs, and you do not make a pull request.
     This is correct for a pilot repository that wants new releases
     automatically. It is not correct for a repository with high security
     requirements, because a person who can move the tag can change the code
     that you run. If you use `@vX`, first make sure that the `v*` ruleset is
     in place. Refer to
     [releasing.md](releasing.md#necessary-tag-protection). If you cannot use a
     reference that moves, pin a SHA or a `vX.Y.Z` tag. Never pin a branch.
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

## Copilot-instructions sync (pull model)

Copilot instruction files are distributed by a **pull** workflow that each
consumer runs in its own repo ([`examples/workflows/copilot-instructions-sync.yml`](../examples/workflows/copilot-instructions-sync.yml)),
with credentials scoped to `contents: write` + `pull-requests: write` on
**its own repo only**. There is no cross-repo credential and
`ai-common-workflows` keeps no list of consumers. By default the built-in
`GITHUB_TOKEN` pushes the branch and a human opens the PR (GitHub blocks PR
creation by workflows unless a repo toggle is enabled); an optional
`COPILOT_SYNC_TOKEN` (fine-grained PAT / App token) automates PR creation
without granting any workflow approve rights. Pin `ACW_REF` to a commit SHA
(or release tag) so upgrades are deliberate. See
[copilot-instructions.md](copilot-instructions.md).
