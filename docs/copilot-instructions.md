# Copilot instructions — model & distribution

How the Copilot instruction files are structured and how consumer repos keep
them in sync — the maintainer's view. To *set this up* in a repo, see
[copilot-review-setup.md](copilot-review-setup.md); for what the files contain,
[`copilot-instructions/README.md`](../copilot-instructions/README.md).

## The model

The source of truth is split the same way the engine's rubric is (see
[profiles.md](profiles.md)) — a base that always applies, plus optional
per-profile additions:

- `copilot-instructions/base/instructions/ai-review-*.instructions.md` — the
  framework-neutral floor (OWASP / CIS / NIST CSF). **Every** consumer gets
  these, whatever profile they track.
- `copilot-instructions/profiles/<profile>/instructions/ai-review-*-additions.instructions.md`
  — that profile's *additions*, layered on top. `baseline` (the default) has
  none; `cms-ars` has three, adding NIST/ARS control-ID citations, PHI
  severity items, the FIPS algorithm posture, and CMS-specific checks.

Consumer repos receive the base files plus their profile's additions (if any)
in `.github/instructions/ai-review/`, where GitHub Copilot's code review reads
any `*.instructions.md` that carries an `applyTo:` frontmatter glob — it reads
subdirectories of `.github/instructions/` as well as the directory itself, so
the whole integration lives in one directory the sync owns, alongside (never
mixed into) a consumer's own instruction files. Each additions file is scoped
to the same `applyTo` paths as the base file it supplements, and says so in its
own text — including which of its points override the base on conflict — since
Copilot has no notion of precedence between instruction files.

The `ai-review-` prefix keeps them collision-free with a consumer's own files
and makes upgrades a whole-file replacement; the `-additions` suffix is what
lets the sync workflow tell an overlay apart from a base file (and clean up a
stale overlay when a consumer switches profiles). Org-level Copilot
instructions are deliberately **not** used — programs don't control org
settings.

**Why additive:** a profile can then only ever *add* review coverage. Before
this split, each profile shipped a full standalone set, so the same generic
checks were maintained twice and were free to drift apart — and selecting an
agency profile silently replaced, rather than extended, the generic floor.

## Distribution: a pull model

`ai-common-workflows` **does not push** to any consumer and keeps **no list of
consumers** — it holds zero knowledge of who uses it. Instead, each consumer
runs a small sync workflow in its own repo that *pulls* the files:

[`examples/workflows/copilot-instructions-sync.yml`](../examples/workflows/copilot-instructions-sync.yml)
— copied into a consumer's `.github/workflows/`, it checks out this repo at a
pinned `ACW_REF`, copies the base `ai-review-*.instructions.md` plus the chosen
`PROFILE`'s `*-additions` files (if it has any) into
`.github/instructions/ai-review/`, removes any `*-additions` left over from a
profile the repo no longer tracks, and opens (or updates) a PR on the branch
`ai-review/instructions-sync`. It
never pushes to the default branch — every change is a reviewable PR. It is
idempotent: no diff → no PR.

### Auth

Nothing to configure in `ai-common-workflows`. The sync workflow runs entirely
inside the consumer's repo, scoped to `contents: write` + `pull-requests: write`
on **that repo only**. There is no distributor account and no cross-repo token;
a leaked credential affects one repo, not many.

On the consumer side, how the PR gets opened is a choice (detailed in the
workflow's header comment):

- **Default (zero config):** the branch is pushed and, because GitHub's
  "Allow GitHub Actions to create and approve pull requests" toggle is off by
  default, PR creation is refused — the run still succeeds and prints a
  compare URL for a human to open the PR. Create-only, human-in-the-loop.
- **`COPILOT_SYNC_TOKEN` secret (recommended for full automation):** a
  fine-grained PAT scoped to that repo, issued from a dedicated **machine
  user** rather than a person's account, so sync PRs are not attributed to a
  colleague and the automation outlives any individual's access. (A GitHub App
  is the stronger option for an org rolling this out widely — see
  [copilot-review-setup.md](copilot-review-setup.md).) PRs auto-create with
  the create-and-approve toggle still **off** (it only governs the built-in
  `GITHUB_TOKEN`), no workflow gains approve rights, and `pull_request` CI runs
  normally on the sync PR.
- **Enable the toggle:** works, but grants create *and* approve to every
  workflow's `GITHUB_TOKEN` in that repo, and CI on `GITHUB_TOKEN`-created PRs
  is still suppressed/held by GitHub.

### Maintainer responsibilities

Just keep the source files correct: edit the base
`ai-review-*.instructions.md` for a change everyone should get, or a profile's
`ai-review-*-additions.instructions.md` for one only that profile should get.
Consumers pick the change up the next time their sync workflow runs against a
ref they've pinned to. Cut a tag/release so consumers have a stable `ACW_REF`
to move to.

When adding a profile, write only the deltas — don't restate base checks in an
additions file, or the two copies will drift the way the old per-profile
standalone sets did. Give an additions file the same `applyTo` glob as the
base file it supplements, and state in its body that it supplements rather
than replaces (Copilot applies no precedence between instruction files).

## Validating a change

Because Copilot reads instructions from the PR **head** branch, you can verify
a wording change on the very PR that introduces it: open the PR, let Copilot
review it, and confirm the comment format/severity behavior is what you expect
before merging.
