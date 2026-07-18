# Changelog

All notable changes to this project are documented here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/); the project aims to
follow [Semantic Versioning](https://semver.org/).

## [Unreleased]

### Added

- **Azure OpenAI endpoint** (`provider=azure`, `codex` only): the engine derives
  the OpenAI-compatible deployment URL from `AZURE_OPENAI_ENDPOINT`, the
  deployment name (`model`), and `AZURE_OPENAI_API_VERSION`. Exposed as
  `azure-openai-*` Action inputs and the `azure` endpoint in the Jenkins plugin.
- **Pluggable-repo framing**: the top-level README now presents this repo as a
  collection of independent workflows (AI PR review is the first), and a new
  [docs/adding-workflows.md](docs/adding-workflows.md) documents the conventions
  for adding more.
- **Composite GitHub Action** (`action.yml`) for AI-assisted security &
  compliance PR review: all engine parameters, first-class Bedrock / Vertex /
  Azure OpenAI / custom-gateway endpoints, and `result` / `review-json` outputs.
- **Jenkins plugin** (`jenkins-plugin/`) providing the `aiPrReview` pipeline
  step, org-wide defaults (JCasC-ready), and the same engine bundled as a
  resource. Distributed as a `.hpi` on GitHub Releases with a SHA-256 checksum.
- **Shared review engine** (`engine/`): relocatable bash engine with parallel
  fan-out, self / independent adjudication, and an SCM seam.
- **Copilot instruction files** (`copilot-instructions/`): four prefixed,
  `applyTo`-scoped files plus a subscription workflow that opens update PRs to
  subscriber repos.
- Documentation set, test suites (bats, pytest, JenkinsRule), and CI
  (static checks, engine tests, plugin build/release).

### Security

- **The SCM token is kept out of the AI (review) phase.** The Action and the
  plugin run the review with no `GITHUB_TOKEN`/`GH_TOKEN` in its environment and
  post in a separate process that holds the token, so prompt-injected PR content
  can't reach a repo-write credential. Exception: the `copilot` backend, whose
  model auth is itself a GitHub token.
- Egress control is the consumer's infrastructure responsibility; a built-in
  Docker egress sandbox exists under `engine/lib/sandbox/` but is
  **experimental and not wired into the shipped Action/plugin** (see its
  README). Least-privilege credentials and SHA/checksum pinning are documented
  as imperative in `docs/security.md`.

[Unreleased]: https://github.com/navapbc/ai-common-workflows/commits/main
