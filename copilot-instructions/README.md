# GitHub Copilot review instructions

These files make GitHub Copilot's automatic PR review apply the same security
and compliance checks — and the same comment format — as the AI Security &
Compliance Review action and Jenkins plugin. Copilot review runs natively inside
GitHub with no CI minutes and no LLM keys of your own; running it alongside the
action gives you a second independent reviewer.

## What's here

Instructions are organized by **compliance profile**, mirroring the engine:

```
profiles/cms-ars/instructions/    # CMS ARS 5.1 / NIST 800-53 (default)
profiles/baseline/instructions/   # generic CIS / NIST CSF / OWASP
```

Copilot code review reads any `*.instructions.md` file in a repo's
`.github/instructions/` directory that carries an `applyTo:` frontmatter glob.
Each profile ships the same four files, prefixed `ai-review-` so they never
collide with your own instructions and are trivial to identify and upgrade:

| File | Applies to |
|---|---|
| `ai-review-security.instructions.md` | everything (`**`) — the severity ladder + comment format |
| `ai-review-iac.instructions.md` | Terraform / CloudFormation / Bicep / Pulumi / Helm / K8s / CDK |
| `ai-review-auth.instructions.md` | auth / session / authz / middleware paths |
| `ai-review-scripts.instructions.md` | shell scripts |

They are self-contained — no repository-specific files or tooling required.
Your existing `.github/copilot-instructions.md`, if any, is never touched.

## Adopt via subscription (recommended — no manual copying)

Open a one-line PR to this repository adding your `owner/repo` to
[`subscribers.yml`](./subscribers.yml). That's the whole onboarding step. To use
a non-default profile, add it as an object instead:

```yaml
subscribers:
  - navapbc/cms-service                 # cms-ars (default)
  - repo: navapbc/other-service
    profile: baseline
```

Whenever these instruction files change, a workflow opens a pull request
against each subscriber repo that copies its profile's latest
`ai-review-*.instructions.md` into `.github/instructions/`. You review and merge
it like any other PR — the bot never pushes to your branches. New subscribers
are backfilled on the next change (or immediately, by a maintainer running the
workflow manually).

Setup for maintainers of this repo is in
[`docs/copilot-instructions.md`](../docs/copilot-instructions.md) (the
distributor needs a GitHub App or PAT with write access to subscriber repos).

## Adopt manually (fallback)

For repos outside the subscription's reach (e.g. a different GitHub instance),
copy the files in once:

```bash
mkdir -p .github/instructions
profile="cms-ars"   # or: baseline
base="https://raw.githubusercontent.com/navapbc/ai-common-workflows/v1.0.0/copilot-instructions/profiles/${profile}/instructions"
for f in security iac auth scripts; do
  curl -fsSL "${base}/ai-review-${f}.instructions.md" \
    -o ".github/instructions/ai-review-${f}.instructions.md"
done
```

Pin the tag/SHA in that URL deliberately (see [`docs/security.md`](../docs/security.md)),
and re-run to upgrade — the `ai-review-` prefix means it only ever overwrites
these files.

## Enabling Copilot review

Copilot code review must be enabled for the repository (or organization) in
GitHub settings, and you need a Copilot plan that includes code review.
Copilot reads instruction files from the PR's head branch, so you can validate
a change to these files on the very PR that introduces it.
