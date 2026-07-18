# Changelog

All notable changes to this project are documented here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/); the project aims to
follow [Semantic Versioning](https://semver.org/).

## [Unreleased]

### Added

- **Bedrock for `codex`** (`ai-tool=codex` + `provider=bedrock`): selects the
  Codex CLI's built-in `amazon-bedrock` provider (AWS-cred auth, direct to
  Bedrock, no gateway); a Bedrock model ID is required. Bedrock now serves both
  `claude` and `codex`.
- **Copilot BYOK pass-through**: `copilot-provider-base-url` / `-type` /
  `-api-key` / `copilot-model` inputs (Action) and the matching Jenkins step /
  global params flow to the copilot CLI as `COPILOT_PROVIDER_*` / `COPILOT_MODEL`,
  which the CLI sends directly to your endpoint. copilot has no native Bedrock
  type — front Bedrock with an in-boundary Anthropic/OpenAI-compatible gateway.
- **Compliance profiles** (`AI_REVIEW_PROFILE`, default `cms-ars`): the
  compliance rubric is now selectable. Ships `cms-ars` (CMS ARS 5.1 /
  NIST 800-53) and a framework-neutral `baseline` (CIS / NIST CSF / OWASP) under
  `engine/profiles/`, plus a bring-your-own directory path. Surfaced as the
  `profile` input (Action), the `profile` step/global param (Jenkins), and a
  per-subscriber `profile` for the Copilot instructions. See
  [docs/profiles.md](docs/profiles.md).
- **Azure OpenAI endpoint** (`provider=azure`, `codex` only): the engine derives
  the OpenAI-compatible deployment URL from `AZURE_OPENAI_ENDPOINT`, the
  deployment name (`model`), and `AZURE_OPENAI_API_VERSION`. Exposed as
  `azure-openai-*` Action inputs and the `azure` endpoint in the Jenkins plugin.
- **Pluggable-repo framing**: the top-level README presents this repo as a
  collection of independent workflows, and [docs/adding-workflows.md](docs/adding-workflows.md)
  documents the conventions (self-contained front ends, shared cores, the
  `github.action_path` bash-sourcing pattern, profiles) for adding more.
- **Shared review engine** (`engine/`): relocatable bash engine with parallel
  fan-out, self / independent adjudication, and an SCM seam.
- **Copilot instruction files** (`copilot-instructions/`): four prefixed,
  `applyTo`-scoped files per profile, plus a subscription workflow that opens
  update PRs to subscriber repos.
- Documentation set, test suites (bats, pytest, JenkinsRule), and CI
  (static checks, engine tests, plugin build/release).

### Changed

- **Front ends restructured into shared core + thin per-workflow units.**
  - The GitHub Action moved from the repo root to
    `workflows/security-compliance-review/action.yml`. Consumers must update
    `uses:` to `navapbc/ai-common-workflows/workflows/security-compliance-review@<sha>`.
    Generic CI plumbing is factored into `workflows/_shared/lib/ci.sh`, sourced by
    absolute path (a composite action cannot reference a sibling composite
    cross-repo).
  - The Jenkins plugin is now a Maven reactor: a shared **`ai-common-core`**
    library plugin (engine extraction, endpoint mapping, PR-context resolution)
    plus the thin **`ai-security-compliance-review`** plugin that depends on it.
    Installing the plugin now also requires `ai-common-core.hpi`; both are
    attached to releases.
- **Workflow renamed** `pr-review` → `security-compliance-review`. The Jenkins
  pipeline step and JCasC symbol are now `aiSecurityComplianceReview`; the plugin
  artifact is `ai-security-compliance-review`.

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
