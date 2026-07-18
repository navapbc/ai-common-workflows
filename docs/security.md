# Security & supply chain

These components run code in your CI with your repository contents and
credentials in scope. Treat them like any other third-party CI dependency.
This page is the trust model and the adoption checklist.

## What executes where

| Phase | Where | Has network? | Has secrets? |
|---|---|---|---|
| Checkout, `git fetch` base ref | runner/agent | yes | your CI token |
| **AI review** | sandbox (default) or runner | **LLM endpoint only** | LLM credentials only |
| Merge / adjudicate | same as review | same | same |
| **Post review** | runner/agent (never sandboxed) | SCM API | SCM token only |

In sandbox mode (the default) the AI review runs in a Docker container on an
`--internal` network with no route out except through an allowlist proxy that
permits only your LLM endpoint. The checkout is mounted **read-only**, and the
**SCM token is not present** during the AI phase — posting happens afterward in
a separate, non-AI process. The one exception: `tool: copilot`, whose model
authentication *is* a GitHub token, so a Copilot-scoped token is present in the
sandbox for that backend only.

Credentials are always passed as environment variables, never on the command
line, and are never written to logs.

## The residual risk

The review reads untrusted PR content through an agentic AI CLI. The sandbox
stops that content from exfiltrating your code or credentials (default-deny
egress, read-only checkout, no SCM token). It does **not** stop injected
content from influencing the *text* of a finding — which is why the output is
always a human-reviewed PR comment, never an automated merge or code change.

If you disable the sandbox (`sandbox: false`), you keep the functionality but
lose the egress boundary: the AI CLI then runs directly on the runner with
normal network access. Only do this on runners where you control egress by
other means (e.g. a locked-down self-hosted runner).

## Adoption checklist

1. **Review the code before adopting.** The engine is deliberately small and
   readable — [`engine/`](../engine/README.md) is a few hundred lines of bash
   plus `github_payload.py` and `allowlist_proxy.py`. Read it, the
   [`action.yml`](../action.yml), and (if you use it) the
   [Jenkins step](../jenkins-plugin/README.md), the way you would review any
   dependency that runs in your pipeline. Re-review on upgrade by diffing tags.

2. **Pin to an immutable reference.**
   - **GitHub Action:** pin `uses:` to a full 40-character commit SHA, not a
     tag or branch — tags are mutable, SHAs are not:
     ```yaml
     - uses: navapbc/ai-reusable-workflows@a1b2c3d…（40 chars） # v1.0.0
     ```
     The `# vX.Y.Z` comment records which release the SHA is, so upgrades stay
     legible and deliberate.
   - **Review image:** pin `review-image` by **sha256 digest**
     (`ghcr.io/…/ai-pr-review@sha256:…`), not a tag. Each release publishes its
     digest.
   - **Jenkins plugin:** install a specific released `.hpi` and **verify its
     SHA-256** against the checksum in the release notes. Upgrades are a manual
     admin action, never automatic.

3. **Least-privilege tokens.** The SCM token needs only `contents: read` +
   `pull-requests: write`. Skip drafts. Remember that, on the public API, PR
   diffs leave your network perimeter — point at Bedrock/Vertex/an internal
   gateway if that matters (see [private-endpoints.md](private-endpoints.md)).

4. **Mind where the review runs.** If you chose an in-boundary LLM precisely so
   code never leaves your boundary, don't run the review on shared
   infrastructure outside it. See the compute-placement note in
   [private-endpoints.md](private-endpoints.md).

## Auditing the sandbox at runtime

The allowlist proxy logs every allowed and denied host; the Action and plugin
surface that log at the end of the run. A `DENY` line for a host you didn't
expect is worth investigating.
