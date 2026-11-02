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
  none; `cms-ars-5.1` has three, adding NIST/ARS control-ID citations, PHI
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
— copied into a consumer's `.github/workflows/`, it checks out this repo at
`ACW_REF` (`main` by default), copies the base `ai-review-*.instructions.md` plus the chosen
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
  user** — never from a person's account, so sync PRs are not attributed to a
  colleague, the token's reach is limited to the repos the sync touches, and
  the automation outlives any individual's access. (A GitHub App is the
  stronger option for an org rolling this out widely — see
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
Consumers pick the change up on their next scheduled sync, as a PR their team
reviews — `ACW_REF` tracks `main`, so a correction to the base rubric reaches
every consumer without anyone bumping a ref.

**The PR is the gate.** The sync never pushes to a consumer's default branch,
so nothing you write here lands anywhere without a human reading the diff and
merging it. That is why this is the one place the project does not require a
commit SHA: the job copies Markdown and executes nothing, a SHA would add a
second gate on a value nobody reads in front of a gate on content they do, and
a fixed ref would make the schedule pointless because it never produces a diff.
A consumer whose program requires pinning still can — see
[copilot-review-setup.md](copilot-review-setup.md) — and then updates arrive
only when they edit that line.

Practically: assume a base-rubric change is in front of every consumer within a
week of merging, subject to their review. Write it accordingly.

### The engine rubric is a parallel, not a source

`copilot-instructions/` and `engines/security-compliance-review/skills/` are
**two hand-maintained trees with no shared source**. Nothing generates one from
the other, and they cannot be diffed for equality even in principle: the
decomposition differs (five engine files — `pr-review`, `code-security`,
`iac-compliance`, `codebase-audit`, `finding-adjudication` — against four
Copilot ones), and the Copilot set is roughly a third the length, because it is
a condensation for a runtime that gives you no control over the prompt.

So a rule changed on one side does not reach the other, and the only thing that
carries it across is whoever remembers. #62 had to fix the same framework leak
in both trees by hand; the docs are now careful to promise the same *checks*,
severity ladder and comment format rather than "the same rubric", because
equality of the files was never the relationship.

One invariant is enforced across both:
`tests/python/test_floor_is_framework_neutral.py` holds that neither floor
names a framework revision and that each tree's profiles still do. It was
scoped to `engines/` until the identical leak appended to the Copilot floor
passed the whole suite in silence. It is one rule, not parity — treat it as a
floor under the drift, not a fix for it.

**The drift also reaches consumers, by design.** `ACW_REF` tracks `main` while
the engine is SHA-pinned, so a consumer running both is running instructions
synced last week against an engine pinned in March. That is the intended
behaviour of two subsystems with deliberately different freshness models, and
it is the strongest reason the docs tell a consumer to pick one.

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
