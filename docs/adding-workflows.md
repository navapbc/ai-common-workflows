# Adding a workflow

This repo is a **collection** of reusable, AI-assisted CI/CD workflows. The AI
PR review is the first one; it is not meant to be the only one. This guide
describes the conventions a new workflow should follow so the repo stays
coherent as it grows, and so consumers can trust every workflow the same way.

Nothing here is load-bearing framework — there is no plugin system to register
with. A "workflow" is just a self-contained unit (a composite action, a
reusable workflow, or a plugin step) plus its engine, docs, and tests. Keep it
independent: a team should be able to adopt your workflow without pulling in the
PR-review engine, and vice versa.

## Repository layout

Today the tree is organized around the PR-review workflow:

```
action.yml                 # PR review — the root composite GitHub Action
engine/                    # PR review engine (bash + a little Python); front-end agnostic
  bin/ai-pr-review         #   entrypoint
  lib/                     #   endpoint config, SCM glue, helpers
  skills/                  #   the review rubrics/prompts
jenkins-plugin/            # second front end over the same engine
copilot-instructions/      # Copilot-native variant of the same rubric
docs/                      # per-topic docs
tests/                     # bats (bash), pytest (python)
examples/workflows/        # copy-paste consumer workflows
```

A **second, unrelated workflow** should not bolt onto `engine/` or the root
`action.yml`. Give it its own directory so it can be pinned, documented, and
reasoned about on its own.

## Where a new workflow goes

Pick the front end that fits how consumers will call it:

- **Composite action** (most common) — put it under `workflows/<name>/action.yml`
  and consumers reference it as
  `uses: navapbc/ai-common-workflows/workflows/<name>@<sha>`.
  Keep the action thin; put real logic in a sibling `workflows/<name>/engine/`
  (or a shared library only if it is genuinely shared).
- **Reusable workflow** — put a `.github/workflows/<name>.yml` with
  `on: workflow_call` and consumers `uses:` it. Choose this when the workflow
  owns the whole job (multiple steps, matrix, permissions) rather than a single
  step.
- **Plugin step / other CI** — mirror the `jenkins-plugin/` pattern: a thin
  front end that shells out to a small, reviewable engine.

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

If your workflow calls a model, reuse the endpoint conventions the review engine
already establishes in [`engine/lib/endpoints.sh`](../engine/lib/endpoints.sh)
rather than inventing new environment variables:

- `AI_REVIEW_PROVIDER` (or an analogous `*_PROVIDER`) selects
  `api | bedrock | vertex | azure`.
- Bedrock and Vertex host Claude (`claude`); Azure OpenAI hosts OpenAI models
  (`codex`). A custom gateway is just a base-URL override on the `api` path.

Matching these keeps a single mental model for operators configuring several
workflows in the same org. See [private-endpoints.md](private-endpoints.md) for
the per-provider setup.

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
