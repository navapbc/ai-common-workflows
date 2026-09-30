# AI security & compliance review

Point your pipeline at it and get inline review comments on every pull
request. It works against the public API or a private LLM endpoint (Amazon
Bedrock, Google Vertex, Azure OpenAI, or a custom gateway) so code and diffs
can stay inside your boundary. The compliance rubric is a selectable
[profile](profiles.md) (`base` by default).

For the full input/output reference, see [github-action.md](github-action.md)
(GitHub Action) or [jenkins-plugin/README.md](../jenkins-plugin/README.md)
(Jenkins).

## Run it alongside your scanners, not instead of them

This reasons about a change; it does not exhaustively analyze a codebase. It
belongs next to the deterministic tools, and a program that adopts it as their
whole answer has a gap they cannot see.

| Job | Best tool | Why |
|---|---|---|
| Taint tracking, reachability, exhaustive sink coverage | **SAST** (CodeQL, Semgrep) | Deterministic, complete over the paths it models, repeatable |
| Known vulnerabilities in dependencies, transitive included | **SCA** (Dependabot, Snyk) | Needs a CVE database and a resolved dependency graph |
| Secrets across full history, validated against providers, push protection | **Secret scanning** (GitHub secret scanning, gitleaks) | Scans every commit, not one diff, and can confirm a credential is live |
| Was a check *forgotten*? Is this config individually valid and collectively wrong? Will this log line carry PHI? Does this change weaken a control elsewhere? | **This review** | Needs to read intent across files, which pattern matchers cannot |

What that means concretely:

- **It is diff-scoped.** A vulnerability in code the PR does not touch is out of
  scope by construction. The [codebase audit](codebase-audit.md) covers an
  existing repo, ad hoc; neither replaces continuous scanning.
- **It is probabilistic.** Two runs on the same diff may differ, and recall is
  not measured. A clean review is *not* evidence that a diff is safe — it is one
  reviewer's opinion, which is why the default is advisory and the posted review
  says so.
- **It has no CVE database, no full history, and no reachability analysis.** It
  will not tell you that a transitive dependency has a known RCE.
- **Control IDs it cites are model-generated.** The rubric forbids inventing
  identifiers, but nothing verifies them. Check any citation against the
  authoritative catalog before it goes into a compliance deliverable — the
  posted review carries that caveat for the same reason.

The useful mental model: SAST and SCA answer *"does this match a known-bad
pattern?"*; this answers *"does a careful reviewer think this change is
wrong?"* — with the reliability that comparison implies in both directions.

If you are changing the rubric, `tests/corpus/` is the fixture set that
measures whether detection got better or worse; the rest of the test suite
only proves the plumbing works.

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

# One review per PR: a new push supersedes an in-flight run instead of racing
# it. Each run is a real model call you pay for, and two would post overlapping
# comments.
concurrency:
  group: ai-security-compliance-review-${{ github.event.pull_request.number }}
  cancel-in-progress: true

jobs:
  review:
    runs-on: ubuntu-latest
    # A large diff runs ~8 minutes. GitHub's default job timeout is six hours,
    # which is a long time for a hung CLI to hold a runner.
    timeout-minutes: 20
    steps:
      - uses: actions/checkout@3d3c42e5aac5ba805825da76410c181273ba90b1 # v7.0.1
        with:
          ref: ${{ github.event.pull_request.head.sha }}
          # Keep the token out of .git/config so the AI phase cannot reach a
          # repo-write credential; the action posts in a separate step that
          # holds one. See security.md.
          persist-credentials: false
      - uses: navapbc/ai-common-workflows/workflows/security-compliance-review@<commit-sha> # v1.0.0
        with:
          anthropic-api-key: ${{ secrets.ANTHROPIC_API_KEY }}
```

That is the whole setup, and the defaults are the ones most teams want:
advisory (nothing blocks), silent on a clean PR, up to 50 inline comments with
the rest in the review body, and no adjudication pass. [Pin `@<commit-sha>`,
not a tag](security.md).

The three lines beyond the bare minimum — `concurrency`, `timeout-minutes` and
`persist-credentials` — are here because every consumer wants them and each is
easier to include than to rediscover. The first two exist because this reviewer
costs money per run and holds a runner while it thinks; the third is the
token-isolation posture the rest of these docs recommend, so the snippet people
copy should model it.

> **Forked pull requests are skipped automatically.** GitHub withholds secrets
> and issues a read-only token for a `pull_request` from a fork, so the review
> has no model credential and nothing to post with. The action detects this and
> skips with a notice rather than failing — you need no `if:` guard. To review
> an external contribution, run the workflow by hand against it. See
> [Forked pull requests](github-action.md#forked-pull-requests).

## Components

| Component | What it is | Docs |
|---|---|---|
| **GitHub Action** | Composite action; `uses:` it in any workflow. | [github-action.md](github-action.md) |
| **Jenkins plugin** | `.hpi` adding an `aiSecurityComplianceReview` pipeline step. | [jenkins-plugin/README.md](../jenkins-plugin/README.md) |
| **Codebase audit** | A second entrypoint on the same engine that audits an existing repo rather than a change. Local, ad-hoc, advisory. | [codebase-audit.md](codebase-audit.md) |
| **Copilot instructions** | Files that make Copilot's built-in review apply the same checks — the alternative to the Action for teams without model credentials. | [copilot-review-setup.md](copilot-review-setup.md) |

The Action and the plugin run the **same review engine**
([`engines/security-compliance-review/`](../engines/security-compliance-review/README.md)) —
one source of truth for the review logic, two front ends.

**Pick one — they are alternatives, not layers.** Both apply the same checks by
the same method, so running both mostly means the same finding reported twice
on the same line, and two bills. Which one you run is decided by what your
program can actually obtain:

- **The Action** (or the plugin, on Jenkins), when you can get model
  credentials — an API key, or Bedrock / Vertex / Azure inside your boundary.
  It is the only path that can block a merge, it caps and anchors what it posts
  so a review cannot bury the diff, it lets you pin the model and keep the diff
  in your boundary, and it emits machine-readable output a pipeline can act on.
- **Copilot's native review**, with these instructions synced, when you cannot.
  Plenty of programs have Copilot already procured and authorized while a
  frontier-model key is months of paperwork away, or never. That is a real
  option rather than a consolation prize: the same checks, no keys, no runner,
  nothing of yours to operate.

Going Copilot-only costs you the gate, control over the model and the data
path, machine-readable output, and profile composition
([side by side](copilot-review-setup.md#what-the-action-does-that-this-does-not)).
Worth knowing before you choose — not a reason to run both.

This is a different question from whether to run a **scanner**. SAST,
dependency and secret scanning detect by a different method, so they genuinely
compose with either choice — [run them alongside, not
instead](#run-it-alongside-your-scanners-not-instead-of-them).

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

## Why there are no language-specific rubrics

There is one security rubric, and it is deliberately language-neutral. There is
no `java.md`, no `python.md`, no per-language skill — and that is a decision,
not a gap.

**A rubric is a poor place to keep framework knowledge.** Spring Security's
defaults change between majors. `yaml.load` becomes unsafe, then deprecated,
then removed. A Rails callback is renamed. Each of those turns a confident line
of rubric into a confidently wrong one — and a wrong citation is worse than
silence, because the finding arrives with the same authority as the parts that
are still right. A markdown file has no way to know it has gone stale, and
nobody re-reads 2,000 lines of pattern catalogue looking for rot.

**The model already knows this, and its knowledge is newer than ours.** The
rubric's job is to say what to prioritise, how to rank severity, what to cite,
and how to report — the parts that are *ours* and that a model has no way to
infer. Enumerating language footguns on top of that spends maintenance to
restate something the model holds more currently than we can. So instead, the
security perspective's **§ 3D** instructs the reviewer to apply the hazards
idiomatic to whatever is in the diff, to name the language or framework in the
finding so a reader can tell a general principle from a framework rule, to take
framework identity from a manifest or an import rather than a file extension,
and not to assert version-specific behaviour it cannot see. That instruction is
stable: it delegates rather than enumerates, so there is nothing in it to go
out of date.

**And language depth is what the deterministic scanners are genuinely better
at.** Semgrep and CodeQL ship maintained Java, Go, Python and Ruby rulesets,
kept current by people whose job that is. This is the division of labour from
[the section above](#run-it-alongside-your-scanners-not-instead-of-them) doing
real work: pairing this review with SAST is *why* we do not need to own a
per-language pattern catalogue.

**If you need it anyway, profiles are the escape hatch.** A program with
genuine framework-specific requirements can add its own rubric additions in its
profile directory — see [profiles.md](profiles.md) — and own the upkeep locally,
where someone is close enough to the framework to notice when the advice ages.
That is the right place for knowledge with a short half-life: near the people
it belongs to, not in a shared floor everyone inherits.

## Compliance profiles

The security perspective is universal. The **compliance** perspective always
includes a framework-neutral floor (CIS / NIST CSF / OWASP); a selectable
`profile` may *add* agency-specific checks and control-ID citations on top —
it never replaces or weakens the floor:

```yaml
        with:
          profile: base       # default — floor only, no agency overlay
        # profile: cms-ars-5.1    # adds CMS ARS 5.1 / NIST SP 800-53 Rev 5 citations + CMS/HIPAA checks
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
