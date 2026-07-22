# ai-common-workflows

> **Status:** Under active development. Interfaces and behavior may change without notice.

Reusable, AI-assisted CI/CD workflows you can drop into any pipeline. This repo
is a **collection** of independent workflows that share a small set of
conventions — pin to a commit SHA, run least-privilege, keep each concern in
its own self-contained engine — so teams can adopt them one at a time.

## Workflows in this repo

| Workflow | What it does | Docs |
|---|---|---|
| **AI security & compliance review** | Security & compliance review of a pull request: inline comments for secrets, PII/PHI, OWASP Top 10, and IaC misconfigurations. The compliance framework is a selectable [profile](docs/profiles.md) — CMS ARS 5.1 / NIST SP 800-53 by default, a generic `baseline`, or bring your own. | [docs/github-action.md](docs/github-action.md) |
| **AI test classifier** | Triage of failing tests on a pull request: classifies each failure as `APPLICATION_BUG` / `TEST_BUG` / `FLAKY_FAILURE` / `ENVIRONMENT_ISSUE` — is the test wrong or the code wrong? — and posts one advisory comment with a 👍/👎 feedback ask. Diagnostic only; never edits code or tests. | [docs/test-classifier.md](docs/test-classifier.md) |

More workflows will land here over time. Each one is meant to stand alone — you
adopt only the ones you need. **Adding a workflow?** See the conventions in
[docs/adding-workflows.md](docs/adding-workflows.md).

---

# Workflow: AI security & compliance review

Point your pipeline at it and get inline review comments on every pull request.
It works against the public API or a private LLM endpoint (Amazon Bedrock,
Google Vertex, Azure OpenAI, or a custom gateway) so code and diffs can stay
inside your boundary. The compliance rubric is a selectable
[profile](docs/profiles.md) (CMS ARS by default).

## Quickstart (GitHub Actions)

```yaml
# .github/workflows/ai-pr-review.yml
name: AI PR review
on:
  pull_request:
    types: [opened, synchronize, reopened]
permissions:
  contents: read
  pull-requests: write
jobs:
  review:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
        with: { ref: "${{ github.event.pull_request.head.sha }}" }
      - uses: navapbc/ai-common-workflows/workflows/security-compliance-review@<commit-sha> # v1.0.0
        with:
          anthropic-api-key: ${{ secrets.ANTHROPIC_API_KEY }}
```

That's the whole setup. [Pin `@<commit-sha>`, not a tag](docs/security.md).

## Components

| Component | What it is | Docs |
|---|---|---|
| **GitHub Action** | Composite action; `uses:` it in any workflow. | [docs/github-action.md](docs/github-action.md) |
| **Jenkins plugin** | `.hpi` adding an `aiSecurityComplianceReview` pipeline step. | [jenkins-plugin/README.md](jenkins-plugin/README.md) |
| **Copilot instructions** | Files that make Copilot's built-in review match. | [copilot-instructions/README.md](copilot-instructions/README.md) |

The Action and the plugin run the **same review engine** ([`engine/`](engine/README.md)) —
one source of truth for the review logic, two front ends.

## Private & self-hosted LLM endpoints

Bedrock is three extra lines — and the diff never leaves your AWS boundary:

```yaml
      - uses: aws-actions/configure-aws-credentials@v4
        with: { role-to-assume: arn:aws:iam::…:role/ai-pr-review, aws-region: us-east-1 }
      - uses: navapbc/ai-common-workflows/workflows/security-compliance-review@<commit-sha> # v1.0.0
        with:
          provider: bedrock
          model: us.anthropic.claude-sonnet-4-5-20250929-v1:0
```

Vertex, **Azure OpenAI**, and custom gateways (LiteLLM, etc.) are the same
shape. Azure serves OpenAI models, so it drives the `codex` tool rather than
`claude`. If you pick an in-boundary LLM for isolation, run the review on
in-boundary compute too — see [docs/private-endpoints.md](docs/private-endpoints.md).

## How it works

1. Collect the PR diff against its base branch.
2. Build a prompt from the diff plus the security & compliance rubrics.
3. Run an AI CLI (Claude / Codex / Copilot) against the configured LLM
   endpoint.
4. Merge, optionally adjudicate (a skeptical second pass), and produce a
   findings JSON.
5. Post one PR review with inline suggestions — idempotently, so re-runs don't
   pile up duplicate comments.

The review runs natively on your runner; there is no built-in network sandbox
yet, so egress control is your infrastructure's responsibility — see
[docs/security.md](docs/security.md).

## Compliance profiles

The security perspective is universal; the **compliance** perspective is a
selectable `profile`:

```yaml
        with:
          profile: cms-ars   # default — CMS ARS 5.1 / NIST SP 800-53 Rev 5
        # profile: baseline  # generic CIS / NIST CSF / OWASP, no agency controls
        # profile: ./my-org-profile   # bring your own rubric directory
```

Same knob on the Jenkins step (`profile:`) and per-subscriber for the Copilot
instructions. Add an agency/state variant under `engine/profiles/` — see
[docs/profiles.md](docs/profiles.md).

## Support matrix

| Tool | api | bedrock | vertex | azure | custom base URL |
|---|:-:|:-:|:-:|:-:|:-:|
| `claude` | ✅ | ✅ | ✅ | — | ✅ |
| `codex` | ✅ | ✅ | — | ✅ | ✅ |
| `copilot` | ✅ | —¹ | — | —¹ | ✅ (BYOK) |

Bedrock hosts Claude (`claude`) and, via the Codex CLI's built-in
`amazon-bedrock` provider, OpenAI-compatible use (`codex`). Vertex is
Claude-only; Azure OpenAI hosts OpenAI models, so it pairs with `codex`.

¹ **copilot** reaches non-GitHub models through **BYOK** env vars
(`COPILOT_PROVIDER_BASE_URL` + `_TYPE` `openai|azure|anthropic` + `_API_KEY`),
sent directly to your endpoint. It has no native Bedrock type, so for Bedrock
you front it with an in-boundary Anthropic/OpenAI-compatible gateway. The
`bedrock`/`vertex`/`azure` *provider inputs* apply to `claude`/`codex`; copilot
uses the BYOK inputs on the `api` path. See
[docs/private-endpoints.md](docs/private-endpoints.md).

## Security & supply chain

These components execute code in your CI with your repository and credentials
in scope. Before adopting, three things are imperative:

- **Least privilege.** Scope the SCM token to `contents: read` +
  `pull-requests: write` (Action) or a fine-grained PAT / GitHub App (Jenkins);
  scope Bedrock/Vertex/Azure to invoking the one model or deployment. Details in
  [docs/security.md](docs/security.md).
- **Review the engine** — it's deliberately small (a few hundred lines of bash
  plus two short Python files) — and **pin to a commit SHA**, not a mutable tag.
- **Control egress** at the runner/infrastructure layer; there is no built-in
  sandbox in this release.

Full trust model and checklist in [docs/security.md](docs/security.md).

## License

[Apache-2.0](LICENSE).
