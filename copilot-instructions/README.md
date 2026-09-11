# GitHub Copilot review instructions

These files make GitHub Copilot's automatic PR review apply the same security
and compliance checks — and the same comment format — as the AI Security &
Compliance Review action and Jenkins plugin. Copilot review runs natively inside
GitHub with no CI minutes and no LLM keys of your own; running it alongside the
action gives you a second independent reviewer.

## What's here

A **base** instruction set that everyone gets, plus optional per-profile
**additions** layered on top — mirroring how the engine composes its rubric
(see [docs/profiles.md](../docs/profiles.md)):

```
base/instructions/                # generic OWASP / CIS / NIST CSF — ALWAYS synced
profiles/baseline/                # no additions (the base alone) — the default
profiles/cms-ars/instructions/    # CMS ARS 5.1 / NIST 800-53 additions, layered on the base
```

Copilot code review reads any `*.instructions.md` file in a repo's
`.github/instructions/` directory that carries an `applyTo:` frontmatter glob.
All files are prefixed `ai-review-` so they never collide with your own
instructions and are trivial to identify and upgrade.

**Base (always synced):**

| File | Applies to |
|---|---|
| `ai-review-security.instructions.md` | everything (`**`) — the severity ladder + comment format |
| `ai-review-iac.instructions.md` | Terraform / CloudFormation / Bicep / Pulumi / Helm / K8s / CDK |
| `ai-review-auth.instructions.md` | auth / session / authz / middleware paths |
| `ai-review-scripts.instructions.md` | shell scripts |

**Profile additions (synced only when you select that profile)** — named
`*-additions.instructions.md`, each scoped to the same paths as the base file
it supplements. `cms-ars` ships three: `ai-review-security-additions`,
`ai-review-iac-additions`, and `ai-review-auth-additions`, adding NIST/ARS
control-ID citations, PHI severity items, the FIPS algorithm posture, and
CMS-specific checks. Each states plainly that it supplements — never replaces
— its base file, and which of its points override the base on conflict.

This means a profile can only ever *add* review coverage: selecting `cms-ars`
never drops a generic OWASP/CIS check, and selecting `baseline` (or nothing)
still gets the full framework-neutral floor.

They are self-contained — no repository-specific files or tooling required.
Your existing `.github/copilot-instructions.md`, if any, is never touched.

## Adopt via a sync workflow (recommended — self-serve pull)

Copy [`examples/workflows/copilot-instructions-sync.yml`](../examples/workflows/copilot-instructions-sync.yml)
into your repo's `.github/workflows/`, set two values, and merge:

- `PROFILE` — the compliance profile to track (`baseline` default, `cms-ars`, …).
- `ACW_REF` — pin `ai-common-workflows` to a commit SHA or release tag.

On its schedule (and on demand), the workflow fetches the base
`ai-review-*.instructions.md` files from `ai-common-workflows@<ACW_REF>` — plus
your profile's `*-additions` files, if it has any — and opens a PR in **your**
repo updating `.github/instructions/`. You review and merge it like any other
PR. Changing `PROFILE` later also removes the previous profile's additions, so
you never silently keep an overlay you've switched away from.

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
root="https://raw.githubusercontent.com/navapbc/ai-common-workflows/v1.0.0/copilot-instructions"

# 1. The base set — always, regardless of profile.
for f in security iac auth scripts; do
  curl -fsSL "${root}/base/instructions/ai-review-${f}.instructions.md" \
    -o ".github/instructions/ai-review-${f}.instructions.md"
done

# 2. Profile additions, layered on top. Skip this block for `baseline`
#    (it has none — the base set above is the whole thing).
profile="cms-ars"
for f in security iac auth; do
  curl -fsSL "${root}/profiles/${profile}/instructions/ai-review-${f}-additions.instructions.md" \
    -o ".github/instructions/ai-review-${f}-additions.instructions.md"
done
```

If you later switch profiles, delete the old
`.github/instructions/ai-review-*-additions.instructions.md` files before
copying the new ones in — the sync workflow does this for you automatically.

Pin the tag/SHA in that URL deliberately (see [`docs/security.md`](../docs/security.md)),
and re-run to upgrade — the `ai-review-` prefix means it only ever overwrites
these files.

## Enabling Copilot review

Copilot code review must be enabled for the repository (or organization) in
GitHub settings, and you need a Copilot plan that includes code review.
Copilot reads instruction files from the PR's head branch, so you can validate
a change to these files on the very PR that introduces it.
