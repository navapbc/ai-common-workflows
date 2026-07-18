# CLAUDE.md — ai-common-workflows

Guidance for Claude Code and contributors working **on** this repo. Kept short
on purpose: stable facts live here, volatile specifics live in `docs/` and are
linked. If something here fights the code, trust the code and fix this file.

## What this is

A collection of reusable, AI-assisted CI/CD workflows. Each workflow is a thin
front end over a shared, front-end-agnostic engine. The first (currently only)
workflow is a **security & compliance PR review**.

## Architecture

- `engine/` — the review engine (bash + a little Python). **Single source of
  truth** for review behavior; relocatable (resolves paths from `ENGINE_HOME`,
  never the CWD). Change review logic here, once.
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
- **Jenkins:** `cd jenkins-plugin && mvn -B -ntp verify`. This is **CI-verified
  only** — the `hpi` packaging does not build in every sandbox; rely on the
  `Jenkins plugin` CI job for the reactor, `@Extension` registration, and tests.
- Keep the test stubs in `tests/stubs/` honest — they stand in for the AI CLIs
  and `gh` with no network.

## Load-bearing conventions (don't break these)

- **No SCM token in the AI phase.** The review runs with no
  `GITHUB_TOKEN`/`GH_TOKEN` in scope; posting happens in a separate phase that
  holds the token. Exception: `copilot`, whose model auth *is* a GitHub token.
  This guarantee lives in the `action.yml` step `env:` blocks and the Jenkins
  `StepExecution` — keep it visible there, never hidden in shared bash.
- **SHA-pin and least-privilege** everywhere in docs/examples; don't loosen.
- **Egress is the consumer's responsibility** — there is no built-in sandbox.
  Don't claim a network boundary the tool doesn't enforce.
- **Secrets via env, never argv or logs.**

## Sharp edges

- A composite action **cannot** `uses: ./…` a sibling composite cross-repo
  (GitHub resolves `./` against the *consumer's* checkout). Share logic as bash
  sourced via `github.action_path`, not nested composites.
- Read the relevant doc before changing a surface — each is the source of truth
  for its area:
  - Adding a workflow → [docs/adding-workflows.md](docs/adding-workflows.md)
  - Providers / private endpoints (api · bedrock · vertex · azure · BYOK) → [docs/private-endpoints.md](docs/private-endpoints.md)
  - Compliance profiles (`AI_REVIEW_PROFILE`, `engine/profiles/`) → [docs/profiles.md](docs/profiles.md)
  - Copilot instruction distribution → [copilot-instructions/README.md](copilot-instructions/README.md)
  - Threat model / credentials → [docs/security.md](docs/security.md)

## Commits & PRs

- Branch off `main`; open a PR and get CI green (including the Jenkins build)
  before merge. PRs are typically **squash-merged**, so don't rely on individual
  commit granularity surviving.
- End commit messages with a `Co-Authored-By:` trailer for the assisting model.
