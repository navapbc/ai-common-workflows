# CLAUDE.md — ai-common-workflows

Guidance for Claude Code and contributors working **on** this repo. Kept short
on purpose: stable facts live here, volatile specifics live in `docs/` and are
linked. If something here fights the code, trust the code and fix this file.

## What this is

A collection of reusable, AI-assisted CI/CD workflows in three shippable
layers: per-workflow **skills**, a mostly-shared **harness**, and thin
**adapters** per CI. Two workflows so far: the **security & compliance PR
review** and the **AI test classifier**.

## Architecture

- `engines/_common/` — the shared, workflow-agnostic runtime (dispatch,
  markers, fan-out, adjudication, endpoints, SCM seam). **Never copied** into
  an engine — entrypoints source it. Interface: `engines/_common/CONTRACT.md`.
- `engines/<workflow>/` — one engine per workflow: `skills/base/` (+
  `skills/profiles/` when it judges against a framework) and a THIN
  `harness/<entrypoint>`. Relocatable (paths from `ENGINE_HOME`, never the
  CWD); copy the `engines/` tree as a unit.
- `workflows/<name>/action.yml` — the GitHub Action front end (a thin composite).
  Generic CI plumbing is bash in `workflows/_shared/lib/`, sourced by an absolute
  path derived from `${{ github.action_path }}`.
- `jenkins-plugin/` — a Maven reactor: `ai-common-core` (shared **library**
  plugin) + one thin `hpi` plugin per workflow, which bundles the engine as a
  zipped resource.
- `copilot-instructions/` — Copilot-native rubric, one set per compliance profile.

Both front ends call the same engine via env + flags; neither reaches into engine
internals.

## How to test

- **Bash/Python:** `bash tests/run.sh` (shellcheck, shfmt, pytest, bats). When
  you add a shell lib or a bats file, also add it to the lists in `tests/run.sh`
  **and** `.github/workflows/ci.yml`, or CI won't cover it.
- **The Python suite is stdlib + pytest only.** CI runs `pip install pytest`
  and nothing else, so a third-party import is a *collection* error there —
  the whole job dies and every other test goes unreported, after passing
  locally where the package happens to exist. Parse the one file you need by
  hand and give the parser its own assertion (see `_excluded_globs` in
  `tests/python/test_secret_fixtures.py` and `_input_block` in
  `test_action_pr_context.py`). Enforced by
  `test_the_python_suite_is_stdlib_plus_pytest_only`.
- **Jenkins:** `cd jenkins-plugin && mvn -B -ntp verify`. This is **CI-verified
  only** — the `hpi` packaging does not build in every sandbox; rely on the
  `Jenkins plugin` CI job for the reactor, `@Extension` registration, and tests.
- Keep the test stubs in `tests/stubs/` honest — they stand in for the AI CLIs
  and `gh` with no network.
- **Changing a rubric?** `tests/run.sh` cannot tell you if you made the review
  worse — it tests the envelope, not the judgment. Run `bash tests/corpus/run.sh`
  before and after, and compare the delta. It costs real model calls, which is
  why it is not in the default suite. See `tests/corpus/README.md`.

## Load-bearing conventions (don't break these)

- **No SCM token in the AI phase.** The review runs with no
  `GITHUB_TOKEN`/`GH_TOKEN` in scope; posting happens in a separate phase that
  holds the token. Exception: `copilot`, whose model auth *is* a GitHub token.
  This guarantee lives in the `action.yml` step `env:` blocks and the Jenkins
  `StepExecution` — keep it visible there, never hidden in shared bash.
- **SHA-pin and least-privilege** everywhere in docs/examples; don't loosen.
- **Egress and sandboxing are the consumer's responsibility.** The engine runs
  natively on the runner or agent and enforces no network boundary. Don't claim
  one. An experimental Docker/egress-proxy sandbox was removed in full — see
  [docs/adr/0002](docs/adr/0002-remove-the-experimental-egress-sandbox.md) — so
  there is no partial implementation to point at.
- **Secrets via env, never argv or logs.**

## Sharp edges

- A composite action **cannot** `uses: ./…` a sibling composite cross-repo
  (GitHub resolves `./` against the *consumer's* checkout). Share logic as bash
  sourced via `github.action_path`, not nested composites.
- Read the relevant doc before changing a surface — each is the source of truth
  for its area:
  - Adding a workflow → [docs/adding-workflows.md](docs/adding-workflows.md)
  - Providers / private endpoints (api · bedrock · vertex · azure · BYOK) → [docs/private-endpoints.md](docs/private-endpoints.md)
  - Compliance profiles (`AI_REVIEW_PROFILE`, the review engine's `skills/profiles/`) → [docs/profiles.md](docs/profiles.md)
  - Copilot instruction distribution → [copilot-instructions/README.md](copilot-instructions/README.md)
  - Threat model / credentials → [docs/security.md](docs/security.md)
  - Why something is the way it is → [docs/adr/](docs/adr/README.md)
    (decisions + the alternatives rejected; not a description of current
    behaviour)

## Commits & PRs

- Branch off `main`; open a PR and get CI green (including the Jenkins build)
  before merge. PRs are typically **squash-merged**, so don't rely on individual
  commit granularity surviving.
- **Releasing:** tag `vX.Y.Z` on `main` and the release workflow does the rest —
  see [docs/releasing.md](docs/releasing.md). There is deliberately no moving
  `vX` alias; a release helps a consumer *find* a SHA, not avoid pinning one.
- `CHANGELOG.md` is `merge=union` (`.gitattributes`), so two branches adding an
  entry at the same spot rebase cleanly with both kept instead of conflicting.
  Check the resulting order — union concatenates, it does not think. GitHub's
  server-side merge ignores merge drivers, so a PR can still show as
  conflicting in the UI; rebase locally and force-push.
- End commit messages with a `Co-Authored-By:` trailer for the assisting model.
