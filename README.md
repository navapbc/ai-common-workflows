# ai-common-workflows

AI-assisted **security and compliance PR review**, packaged as reusable CI
components. Point your pipeline at it and get inline review comments on every
pull request — secrets, PII/PHI, OWASP Top 10, and IaC misconfigurations
against CMS ARS 5.1 / NIST SP 800-53 Rev 5. It works against the public API or
a private LLM endpoint (Amazon Bedrock, Google Vertex, or a custom gateway) so
code and diffs can stay inside your boundary.

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
      - uses: navapbc/ai-common-workflows@<commit-sha> # v1.0.0
        with:
          anthropic-api-key: ${{ secrets.ANTHROPIC_API_KEY }}
```

That's the whole setup. [Pin `@<commit-sha>`, not a tag](docs/security.md).

## Components

| Component | What it is | Docs |
|---|---|---|
| **GitHub Action** | Composite action; `uses:` it in any workflow. | [docs/github-action.md](docs/github-action.md) |
| **Jenkins plugin** | `.hpi` adding an `aiPrReview` pipeline step. | [jenkins-plugin/README.md](jenkins-plugin/README.md) |
| **Copilot instructions** | Files that make Copilot's built-in review match. | [copilot-instructions/README.md](copilot-instructions/README.md) |

The Action and the plugin run the **same review engine** ([`engine/`](engine/README.md)) —
one source of truth for the review logic, two front ends.

## Private & self-hosted LLM endpoints

Bedrock is three extra lines — and the diff never leaves your AWS boundary:

```yaml
      - uses: aws-actions/configure-aws-credentials@v4
        with: { role-to-assume: arn:aws:iam::…:role/ai-pr-review, aws-region: us-east-1 }
      - uses: navapbc/ai-common-workflows@<commit-sha> # v1.0.0
        with:
          provider: bedrock
          model: us.anthropic.claude-sonnet-4-5-20250929-v1:0
```

Vertex and custom gateways (LiteLLM, etc.) are the same shape. If you pick an
in-boundary LLM for isolation, run the review on in-boundary compute too — see
[docs/private-endpoints.md](docs/private-endpoints.md).

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

## Support matrix

| Tool | api | bedrock | vertex | custom base URL |
|---|:-:|:-:|:-:|:-:|
| `claude` | ✅ | ✅ | ✅ | ✅ |
| `codex` | ✅ | — | — | ✅ |
| `copilot` | ✅ | — | — | — |

## Security & supply chain

These components execute code in your CI with your repository and credentials
in scope. Before adopting, three things are imperative:

- **Least privilege.** Scope the SCM token to `contents: read` +
  `pull-requests: write` (Action) or a fine-grained PAT / GitHub App (Jenkins);
  scope Bedrock/Vertex to invoking the one model. Details in
  [docs/security.md](docs/security.md).
- **Review the engine** — it's deliberately small (a few hundred lines of bash
  plus two short Python files) — and **pin to a commit SHA**, not a mutable tag.
- **Control egress** at the runner/infrastructure layer; there is no built-in
  sandbox in this release.

Full trust model and checklist in [docs/security.md](docs/security.md).

## License

[Apache-2.0](LICENSE).
