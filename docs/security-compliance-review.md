# AI security & compliance review

Point your pipeline at it and get inline review comments on every pull
request. It works against the public API or a private LLM endpoint (Amazon
Bedrock, Google Vertex, Azure OpenAI, or a custom gateway) so code and diffs
can stay inside your boundary. The compliance rubric is a selectable
[profile](profiles.md) (CMS ARS by default).

For the full input/output reference, see [github-action.md](github-action.md)
(GitHub Action) or [jenkins-plugin/README.md](../jenkins-plugin/README.md)
(Jenkins).

## Quickstart (GitHub Actions)

```yaml
# .github/workflows/ai-security-compliance-review.yml
name: AI security & compliance review
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
      - uses: actions/checkout@3d3c42e5aac5ba805825da76410c181273ba90b1 # v7.0.1
        with: { ref: "${{ github.event.pull_request.head.sha }}" }
      - uses: navapbc/ai-common-workflows/workflows/security-compliance-review@<commit-sha> # v1.0.0
        with:
          anthropic-api-key: ${{ secrets.ANTHROPIC_API_KEY }}
```

That's the whole setup. [Pin `@<commit-sha>`, not a tag](security.md).

## Components

| Component | What it is | Docs |
|---|---|---|
| **GitHub Action** | Composite action; `uses:` it in any workflow. | [github-action.md](github-action.md) |
| **Jenkins plugin** | `.hpi` adding an `aiSecurityComplianceReview` pipeline step. | [jenkins-plugin/README.md](../jenkins-plugin/README.md) |
| **Copilot instructions** | Files that make Copilot's built-in review match. | [copilot-instructions/README.md](../copilot-instructions/README.md) |

The Action and the plugin run the **same review engine**
([`engines/security-compliance-review/`](../engines/security-compliance-review/README.md)) —
one source of truth for the review logic, two front ends.

## Private & self-hosted LLM endpoints

Bedrock is three extra lines — and the diff never leaves your AWS boundary:

```yaml
      - uses: aws-actions/configure-aws-credentials@v4
        with: { role-to-assume: arn:aws:iam::…:role/ai-security-compliance-review, aws-region: us-east-1 }
      - uses: navapbc/ai-common-workflows/workflows/security-compliance-review@<commit-sha> # v1.0.0
        with:
          provider: bedrock
          model: us.anthropic.claude-sonnet-4-5-20250929-v1:0
```

Vertex, **Azure OpenAI**, and custom gateways (LiteLLM, etc.) are the same
shape. Azure serves OpenAI models, so it drives the `codex` tool rather than
`claude`. If you pick an in-boundary LLM for isolation, run the review on
in-boundary compute too — see [private-endpoints.md](private-endpoints.md).

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
[security.md](security.md).

## Compliance profiles

The security perspective is universal. The **compliance** perspective always
includes a framework-neutral floor (CIS / NIST CSF / OWASP); a selectable
`profile` may *add* agency-specific checks and control-ID citations on top —
it never replaces or weakens the floor:

```yaml
        with:
          profile: baseline   # default — floor only, no agency overlay
        # profile: cms-ars    # adds CMS ARS 5.1 / NIST SP 800-53 Rev 5 citations + CMS/HIPAA checks
        # profile: ./my-org-profile   # bring your own — additions only, layered the same way
```

Same knob on the Jenkins step (`profile:`) and per-subscriber for the Copilot
instructions. Add an agency/state variant under the engine's `skills/profiles/` — see
[profiles.md](profiles.md).

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
[private-endpoints.md](private-endpoints.md).
