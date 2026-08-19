# Adding a workflow

This repo is a **collection** of reusable, AI-assisted CI/CD workflows. The AI
security & compliance review is the first one; it is not meant to be the only
one. This guide describes the conventions a new workflow should follow so the
repo stays coherent as it grows, and so consumers can trust every workflow the
same way.

Nothing here is load-bearing framework — there is no plugin system to register
with. A "workflow" is a self-contained unit (a composite action, a reusable
workflow, or a plugin step) plus its engine, docs, and tests. Keep it
independent: a team should be able to adopt your workflow without pulling in an
unrelated one.

## Repository layout

The tree separates the shared cores from the thin per-workflow front ends:

```
engines/
  _common/                           # shared, workflow-agnostic runtime — never copied
    harness/core.sh                  #   dispatch · markers + JSON · fan-out · adjudication
    endpoints.sh                     #   provider → CLI mapping (api · bedrock · vertex · azure)
    scm/<name>.sh                    #   SCM seam — github ships; others implement 3 fns
    CONTRACT.md                      #   the interface every entrypoint targets
  security-compliance-review/        # workflow 1
    harness/ai-pr-review             #   THIN entrypoint → sources _common
    skills/base/*.md                 #   framework-neutral rubric base
    skills/profiles/<name>/          #   per-compliance-framework rubric overrides
  test-classifier/                   # workflow 2 — same shape, zero overlap
    harness/ai-test-classifier
    skills/base/*.md
workflows/
  _shared/lib/ci.sh                  # shared GH Actions plumbing, sourced by actions
  <name>/action.yml                  # one composite action per workflow
jenkins-plugin/                      # Maven reactor (Jenkins front ends)
  core/                              #   ai-common-core: shared library plugin
  security-compliance-review/        #   the workflow's thin plugin (depends on core)
copilot-instructions/profiles/<name>/instructions/   # Copilot-native variant, per profile
docs/  tests/  examples/workflows/
```

A **second, unrelated workflow** gets its own `engines/<name>/` +
`workflows/<name>/` (and, if it needs a Jenkins front end, its own reactor
module) so it can be pinned, documented, and reasoned about on its own — it
should not entangle an existing workflow's engine or front end. Adopting one
workflow pulls in `_common` (the shared dependency) but never another
workflow. Copying `_common` into an engine is the one thing NOT to do — that
duplicates the most-reusable code; source it instead, per
[engines/_common/CONTRACT.md](../engines/_common/CONTRACT.md).

## Where a new workflow goes

Pick the front end that fits how consumers will call it:

- **Composite action** (most common) — `workflows/<name>/action.yml`, referenced
  as `uses: navapbc/ai-common-workflows/workflows/<name>@v1`. Keep the action
  thin: locate shared code via `${{ github.action_path }}` and delegate to the
  engine.
- **Reusable workflow** — `.github/workflows/<name>.yml` with `on: workflow_call`
  when the workflow owns a whole job (matrix, permissions), not one step.
- **Jenkins / other CI** — add a reactor module under `jenkins-plugin/<name>/`
  that depends on the `ai-common-core` library plugin (engine extraction,
  endpoint mapping, PR-context resolution live there — reuse them).

**Sharing between composite actions — read this.** A composite action **cannot**
`uses: ./workflows/_shared` to reach a sibling composite: GitHub resolves `./`
against the *consumer's* checkout, not this repo, so it breaks cross-repo. Share
plumbing as **bash** instead — put it in `workflows/_shared/lib/` and `source` it
by an absolute path derived from `${{ github.action_path }}` (see
`workflows/security-compliance-review/action.yml`). Keep security-critical
token-gating in the `action.yml` step `env:` blocks, not in shared bash, so it
stays auditable in one place.

Whatever the front end, the engine underneath should be small enough to read in
one sitting and runnable outside CI for local testing.

## Conventions every workflow follows

These are the promises this repo makes to the teams who adopt it. A new
workflow inherits them:

1. **Pin to a commit SHA, never a mutable tag.** Document it in the quickstart,
   the same way the PR-review docs do. See [security.md](security.md).
2. **Least privilege.** Request the narrowest token scopes and cloud
   permissions the job needs, and say so explicitly in the docs. Never ask for
   more "just in case."
3. **Keep untrusted input away from write credentials.** If the workflow reads
   PR/issue content and also writes somewhere, split the phases so the writing
   token is absent while untrusted content is processed — as the review engine
   does (the AI phase runs with no SCM token in scope).
4. **Secrets via env, never argv or logs.** No secret should appear in a process
   command line or in build output.
5. **Egress is the consumer's boundary.** There is no built-in network sandbox;
   state that plainly and point at [security.md](security.md).
6. **Support a dry run.** A `--dry-run` / `dry-run: true` path that prints the
   plan without calling the model or writing anything makes the workflow safe to
   trial and easy to test.
7. **Be idempotent.** Re-running on the same input should not duplicate side
   effects (comments, commits, issues).

## LLM endpoints

If your workflow calls a model, source the shared endpoint layer
[`engines/_common/endpoints.sh`](../engines/_common/endpoints.sh) rather than
inventing new environment variables:

- `AI_REVIEW_PROVIDER` (or an analogous `*_PROVIDER`) selects
  `api | bedrock | vertex | azure`.
- Bedrock and Vertex host Claude (`claude`); Azure OpenAI hosts OpenAI models
  (`codex`). A custom gateway is just a base-URL override on the `api` path.

Matching these keeps a single mental model for operators configuring several
workflows in the same org. See [private-endpoints.md](private-endpoints.md) for
the per-provider setup.

## Compliance profiles

If your workflow judges code against a control framework, make the framework a
**profile** rather than hardcoding it — the same pattern the review uses
(`AI_REVIEW_PROFILE`, resolved from the engine's `skills/profiles/<name>/` with
fallback to `skills/base/`, or a bring-your-own directory path). This lets one workflow
serve several agencies without forks. See [profiles.md](profiles.md).

## Checklist before you open the PR

- [ ] New workflow lives in its own directory; it does not entangle an existing
      engine.
- [ ] Quickstart shows SHA pinning and the minimum permissions.
- [ ] A `dry-run` path exists and is covered by a test.
- [ ] Tests added under `tests/` (bats for bash, pytest for python) and wired
      into CI (`.github/workflows/`).
- [ ] Docs added under `docs/` and linked from the **Workflows in this repo**
      table in the top-level [README](../README.md).
- [ ] A copy-paste example under `examples/` if consumers will call it directly.
- [ ] `CHANGELOG.md` updated.
