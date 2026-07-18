# Copilot instructions — distribution setup

This page is for maintainers of `ai-common-workflows`. For how a consumer
adopts the instruction files, see
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

## Subscription distribution

`.github/workflows/distribute-instructions.yml` opens (or updates) a pull
request in every repo listed in `copilot-instructions/subscribers.yml` whenever
the instruction files change on `main` (or on manual `workflow_dispatch`, to
backfill a new subscriber). It clones each subscriber, copies **its profile's**
`ai-review-*.instructions.md` files (from
`copilot-instructions/profiles/<profile>/instructions/`) into
`.github/instructions/`, and opens a PR on the branch
`ai-review/instructions-update`. It never pushes to a subscriber's default
branch — every change is a reviewable PR.

Idempotent: if a subscriber is already up to date, no PR is opened; if a PR is
already open, it's updated in place.

## Auth for the distributor

The workflow needs write access (contents + pull-requests) to every subscriber
repo, via the `AI_REVIEW_DISTRIBUTOR_TOKEN` secret. Two options:

- **GitHub App (recommended).** Create an App with `contents: write` and
  `pull_requests: write`, install it on the subscriber repos (or the org), and
  mint an installation token in the workflow. Scopes are least-privilege and
  installation is auditable per repo.
- **Fine-grained PAT (simpler).** A PAT owned by a bot account, scoped to the
  subscriber repos with the same two permissions. Easier to set up; rotate it
  on a schedule.

Set the resulting token as the `AI_REVIEW_DISTRIBUTOR_TOKEN` repository secret.

## Validating a change

Because Copilot reads instructions from the PR **head** branch, you can verify
a wording change on the very PR that introduces it: open the PR, let Copilot
review it, and confirm the comment format/severity behavior is what you expect
before merging and distributing.
