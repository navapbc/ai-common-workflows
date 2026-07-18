# Copilot instructions — model & distribution

How the Copilot instruction files are structured and how consumer repos keep
them in sync. For the consumer-facing quickstart, see
[`copilot-instructions/README.md`](../copilot-instructions/README.md).

## The model

The `ai-review-*.instructions.md` files under
`copilot-instructions/profiles/<profile>/instructions/` are the source of truth
(one set per compliance profile; `cms-ars` is the default, `baseline` is the
framework-neutral set). Consumer repos receive their chosen profile's files in
`.github/instructions/`, where GitHub Copilot's code review reads any
`*.instructions.md` that carries an `applyTo:` frontmatter glob.

The `ai-review-` prefix keeps them collision-free with a consumer's own files
and makes upgrades a whole-file replacement. Org-level Copilot instructions are
deliberately **not** used — programs don't control org settings.

## Distribution: a pull model

`ai-common-workflows` **does not push** to any consumer and keeps **no list of
consumers** — it holds zero knowledge of who uses it. Instead, each consumer
runs a small sync workflow in its own repo that *pulls* the files:

[`examples/workflows/copilot-instructions-sync.yml`](../examples/workflows/copilot-instructions-sync.yml)
— copied into a consumer's `.github/workflows/`, it checks out this repo at a
pinned `ACW_REF`, copies the chosen `PROFILE`'s `ai-review-*.instructions.md`
into `.github/instructions/`, and opens (or updates) a PR on the branch
`ai-review/instructions-sync`. It never pushes to the default branch — every
change is a reviewable PR. It is idempotent: no diff → no PR.

### Auth

None to configure here. The sync workflow runs entirely inside the consumer's
repo using that repo's built-in `GITHUB_TOKEN`, scoped to `contents: write` +
`pull-requests: write` on **that repo only**. There is no distributor account,
no cross-repo token, and nothing for a maintainer of `ai-common-workflows` to
set up. A leaked token affects one repo, not many.

### Maintainer responsibilities

Just keep the source files correct: edit the profile's
`ai-review-*.instructions.md`, and consumers pick the change up the next time
their sync workflow runs against a ref they've pinned to. Cut a tag/release so
consumers have a stable `ACW_REF` to move to.

## Validating a change

Because Copilot reads instructions from the PR **head** branch, you can verify
a wording change on the very PR that introduces it: open the PR, let Copilot
review it, and confirm the comment format/severity behavior is what you expect
before merging.
