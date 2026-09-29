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
    harness/fold_review_json.py      #   merge per-batch findings after fan-out
    harness/gate_verdict.py          #   the one "does this block?" decision, all surfaces
    harness/write_audit_report.py    #   report bundle for whole-repo runs
    endpoints.sh                     #   provider → CLI mapping (api · bedrock · vertex · azure)
    scm/<name>.sh                    #   SCM seam — github ships; others implement 3 fns
    scm/github_payload.py            #   findings JSON → GitHub review payload
    sandbox/                         #   experimental egress sandbox; NOT shipped or enabled
    CONTRACT.md                      #   the interface every entrypoint targets
  security-compliance-review/        # workflow 1
    harness/ai-security-compliance-review             #   THIN entrypoint → sources _common
    harness/ai-security-compliance-audit              #   a SECOND entrypoint on one engine
    skills/base/*.md                 #   framework-neutral rubric base
    skills/profiles/<name>/          #   per-framework rubric layers (additive, not overrides)
  test-classifier/                   # workflow 2 — same shape, zero overlap
    harness/ai-test-classifier
    skills/base/*.md
workflows/
  _shared/lib/ci.sh                  # shared GH Actions plumbing, sourced by actions
  <name>/action.yml                  # one composite action per workflow
jenkins-plugin/                      # Maven reactor (Jenkins front ends)
  core/                              #   ai-common-core: shared library plugin
  security-compliance-review/        #   the workflow's thin plugin (depends on core)
copilot-instructions/
  base/instructions/                 # Copilot-native variant — always synced
  profiles/<name>/instructions/      #   per-profile *-additions, layered on the base
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
  as `uses: navapbc/ai-common-workflows/workflows/<name>@<sha>`. Keep the action
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

**A new entrypoint is often cheaper than a new workflow.** The security review
engine carries two — `ai-security-compliance-review` (diff-scoped, posts,
gates) and `ai-security-compliance-audit` (whole-repo, local, writes a report
bundle). They share the rubric, the severity ladder and the findings JSON, so
findings from the two are comparable, and neither is a fork of the other. If
your idea is "the same judgment applied to a different scope", add an
entrypoint to the engine that already owns that judgment rather than a second
workflow that will drift from it. Every entrypoint inherits the obligations in
[CONTRACT.md](../engines/_common/CONTRACT.md) — see the checklist below, they
are test-enforced.

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
8. **Skip forked pull requests rather than failing on them.** GitHub withholds
   secrets from a `pull_request` run off a fork **and** issues a read-only
   token, so a workflow that needs either cannot run — a red check on every
   external contribution that the contributor cannot fix. `ci::resolve_pr_context`
   already implements the skip; pass it `EVENT_NAME` and `IS_FORK_PR` from your
   `action.yml` (see the security review's context step) and you inherit it.
   Scope the skip to the `pull_request` event: a maintainer dispatching the
   workflow by hand runs in the base repo with secrets and a write token, and
   that is the escape hatch you point people at.

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
serve several agencies without forks. Follow the settled convention rather
than inventing a new one: rubric sources are an ordered list whose first entry
is `base` or `none`, every source only *adds* to what precedes it, and the last
listed wins a conflict. There is no per-file override — a program that needs to
own the whole rubric declares `none` in the config, where it is visible (see
[profiles.md](profiles.md#how-resolution-works)).

## What CI already enforces

Several conventions are tests, not advice. Knowing which saves you decoding a
failure that names a rule you have not read:

| Test | What it will fail you for |
|---|---|
| `test_entrypoint_invariants.py` | An engine entrypoint that skips `ai_review::configure_endpoint` (your provider input is then silently ignored and traffic goes to the public API), `resolve_tool`, or `parse_args`; that does not override `print_help`; that never sets `SKILL_NAME` (the first log call dies under `set -u`); or that derives paths from the CWD instead of `ENGINE_HOME` |
| `test_entrypoint_invariants.py` | A **third-party import** anywhere in `tests/python/`. CI installs `pytest` and nothing else, so it is a collection error that kills the whole job — parse the one file you need by hand |
| `test_pin_hygiene.py` | A tag or branch pin of this repo in any doc, example or README. SHA only |
| `test_doc_links.py` | A relative link or heading anchor that does not resolve, anywhere in tracked Markdown |
| `test_secret_fixtures.py` | A credential-shaped literal outside the paths `.github/secret_scanning.yml` excludes — add fixtures under `tests/`, not next to the code that ships |
| `bats tests/bats/*.bats` | Only the files listed in `tests/run.sh` **and** `.github/workflows/ci.yml` run. A new bats file in neither is not covered, and nothing tells you |

## Checklist before you open the PR

- [ ] New workflow lives in its own directory; it does not entangle an existing
      engine. (Or: it is a new **entrypoint** on an engine that already owns
      the judgment — usually the better trade.)
- [ ] Quickstart shows SHA pinning and the minimum permissions.
- [ ] A `dry-run` path exists and is covered by a test.
- [ ] Tests added under `tests/` — bats for bash, pytest for python — and a new
      bats file added to **both** `tests/run.sh` and `.github/workflows/ci.yml`.
      Python needs no registration; the suite runs the whole directory.
- [ ] `bash tests/run.sh` passes. If your workflow ships a **rubric**, that
      suite cannot tell you whether you made the judgment worse — it tests the
      envelope. Run `bash tests/corpus/run.sh` before and after and compare the
      delta; it costs real model calls, which is why it is not in the default
      suite.
- [ ] Docs added under `docs/` and linked from the **Workflows in this repo**
      table in the top-level [README](../README.md).
- [ ] A copy-paste example under `examples/` if consumers will call it directly.
      Give it `concurrency` with `cancel-in-progress`, a `timeout-minutes`, and
      `persist-credentials: false` on any checkout of PR code — a metered
      reviewer that races itself, holds a runner for six hours, or leaves a
      write token where untrusted code can read it is a bad default to copy.
- [ ] `CHANGELOG.md` updated. It is `merge=union`, so two branches adding an
      entry rebase cleanly with both kept — check the resulting order.
