# GitHub Copilot review instructions

These files make GitHub Copilot's automatic PR review apply the same security
and compliance checks — and the same comment format — as the AI Security &
Compliance Review action and Jenkins plugin. Copilot review runs natively inside
GitHub with no CI minutes and no LLM keys of your own; running it alongside the
action gives you a second independent reviewer.

## What's here

Instructions are organized by **compliance profile**, mirroring the engine:

```
profiles/baseline/instructions/   # generic CIS / NIST CSF / OWASP (default)
profiles/cms-ars/instructions/    # CMS ARS 5.1 / NIST 800-53
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

## Adopt via a sync workflow (recommended — self-serve pull)

Copy [`examples/workflows/copilot-instructions-sync.yml`](../examples/workflows/copilot-instructions-sync.yml)
into your repo's `.github/workflows/`, set two values, and merge:

- `PROFILE` — the compliance profile to track (`baseline` default, `cms-ars`, …).
- `ACW_REF` — pin `ai-common-workflows` to a commit SHA or release tag.

On its schedule (and on demand), the workflow fetches that profile's
`ai-review-*.instructions.md` from `ai-common-workflows@<ACW_REF>` and opens a PR
in **your** repo updating `.github/instructions/`. You review and merge it like
any other PR.

This is a **pull** model: it runs entirely in your repo with your own
credentials (`contents: write` + `pull-requests: write` on your repo only).
`ai-common-workflows` needs **no** knowledge of your repo, no subscriber list,
and no cross-repo credentials. To change profiles or upgrade, edit `PROFILE` /
`ACW_REF` in your copy of the workflow.

**How the PR gets opened** (the workflow header documents all three): with zero
config the branch is pushed and a compare URL is printed for a human to open
the PR (GitHub blocks PR creation by the built-in `GITHUB_TOKEN` by default);
add a `COPILOT_SYNC_TOKEN` secret (fine-grained PAT / App token) for fully
automatic PRs with normal CI — without granting any workflow approve rights;
or enable "Allow GitHub Actions to create and approve pull requests".

## Adopt manually (fallback)

For repos outside the subscription's reach (e.g. a different GitHub instance),
copy the files in once:

```bash
mkdir -p .github/instructions
profile="baseline"   # or: cms-ars
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
