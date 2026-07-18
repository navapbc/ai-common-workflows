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
| Review | the AI CLI reads the diff, emits findings | the LLM endpoint | the LLM key |
| Post | `gh` turns findings into a PR review | the SCM API | the SCM token |

The AI CLI is agentic and reads untrusted PR content, so the realistic threat
is prompt injection in a PR steering the CLI to exfiltrate code or
credentials, or to abuse the SCM token. Two things bound that:

1. **Least-privilege credentials** (below) — so even a fully subverted CLI
   can do little.
2. **Egress control on the runner** (below) — so data can't leave to an
   arbitrary destination.

> **On the built-in sandbox.** An earlier design ran the review in a Docker
> container with default-deny egress. It's not in this release — it was
> unverified with real CLIs and broke on common container-in-container CI
> topologies (see `engine/lib/sandbox/README.md`). Egress control is therefore
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

### The LLM credential (Bedrock / Vertex)

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
   readable — [`engine/`](../engine/README.md) is a few hundred lines of bash
   plus `github_payload.py` and `fold_review_json.py`. Read it, the
   [`action.yml`](../action.yml), and (for Jenkins) the plugin, the way you'd
   review any dependency that runs in your pipeline. Re-review on upgrade by
   diffing tags.

2. **Pin to an immutable reference.**
   - **GitHub Action:** pin `uses:` to a full 40-character commit SHA, not a
     tag or branch:
     ```yaml
     - uses: navapbc/ai-reusable-workflows@<40-char-sha> # v1.0.0
     ```
     The `# vX.Y.Z` comment records which release the SHA is.
   - **Jenkins plugin:** install a specific released `.hpi` and **verify its
     SHA-256** against the checksum in the release notes. Upgrades are a
     manual admin action, never automatic.

3. **Skip drafts, and remember the network boundary.** On the public API, PR
   diffs leave your perimeter — point at Bedrock/Vertex/an internal gateway if
   that matters.

## Least-privilege for the Copilot-instructions distributor

If you run the distribution workflow (`.github/workflows/distribute-instructions.yml`),
its token reaches *other* repositories, so it deserves the tightest scope: a
**GitHub App** with only `contents: write` + `pull_requests: write`, installed
on exactly the subscriber repos — or a fine-grained PAT scoped to those repos
with the same two permissions. Never a classic PAT. See
[copilot-instructions.md](copilot-instructions.md).
