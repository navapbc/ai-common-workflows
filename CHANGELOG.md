# Changelog

All notable changes to this project are documented here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/); the project aims to
follow [Semantic Versioning](https://semver.org/).

## [Unreleased]

### Added

- **`gate: true` now fails the job on HIGH or CRITICAL findings**, not on any
  finding. It stays a boolean and still defaults to `false`; only what `true`
  means has changed. Previously `gate: true` failed on any non-`APPROVE`
  result, and the review emits a finding-bearing result for a single LOW
  observation — so gating blocked merges on nits and was effectively
  unadoptable as a required check. MEDIUM and LOW still post as inline
  comments: gating changes what fails the build, never what is reported.
  For an end of the scale explicitly, `gate` also accepts `critical` (CRITICAL
  only) or `any` (the old `true` behavior).
  Two deliberate behaviors: a finding whose severity is missing or
  unrecognized counts as **blocking** (with a warning naming how many) rather
  than being read as LOW, and the gate is evaluated against the engine's own
  findings JSON so a finding that could not be anchored to a diff line still
  counts.
- **[docs/copilot-review-setup.md](docs/copilot-review-setup.md)** — the
  Copilot review path as five numbered steps, and a row for it in the top-level
  README, which previously did not mention Copilot at all: the instruction
  files were reachable only by browsing directories.
  `copilot-instructions/README.md` explains the base/profile model and the pull
  distribution before it gets to "copy this file, set two values", so it works
  as a reference but not as a quickstart. The new page is the how; that one
  stays the why. It also writes down two things neither doc covered and a
  first-time consumer hits immediately: the ruleset rule name for automatic
  review plus the Copilot plan and private-repo-on-free-plan limits that can
  block it, and how to confirm the rubric is actually being applied — a silent
  miss is indistinguishable from Copilot having no findings.
- **AI test classifier** — the repo's second workflow: triages each failing
  test of a PR's change into `APPLICATION_BUG` / `TEST_BUG` / `FLAKY_FAILURE`
  / `ENVIRONMENT_ISSUE` and posts one advisory PR comment with the verdicts
  and a 👍/👎 feedback ask. Diagnostic only (never edits code or tests);
  advisory by default with an opt-in `gate`. Runs OBSERVED (executes the
  repo's suite via the harness's new agentic posture; the AI phase holds no
  SCM token) or INFERRED (`run-suite: false`, diff-only — for untrusted
  forks). Ships as `engines/test-classifier/` + the
  `workflows/test-classifier` composite action. See
  [docs/test-classifier.md](docs/test-classifier.md).

### Changed

- **`COPILOT_SYNC_TOKEN` is now documented as a machine-user PAT.** The docs
  previously said "fine-grained PAT / App token" without saying whose account
  it should come from, which in practice means a person's: sync PRs then arrive
  under a colleague's name as though they wrote them, the token carries that
  person's access to everything else they can reach, and the automation stops
  when their access changes. `docs/copilot-review-setup.md` step 3 now gives
  the machine-user recipe as a requirement rather than a preference — a token
  from a person's account is not offered as an alternative anywhere — covers
  PAT expiry, and states the two non-personal alternatives and their costs — the create-and-approve toggle (grants approve
  to every workflow in the repo) and a GitHub App (stronger, ~10 steps per org,
  worth it via org-level secrets when rolling out widely). The same steer is
  reflected in `copilot-instructions/README.md`, `docs/copilot-instructions.md`,
  `docs/security.md` and the example workflow's header.
- **Copilot instructions now sync into `.github/instructions/ai-review/`**
  rather than flat into `.github/instructions/`. Copilot code review reads
  subdirectories of `.github/instructions/`, so this changes nothing about
  which instructions apply — it puts everything the sync owns in one directory,
  so the workflow never writes beside, or prefix-matches against, instruction
  files the consumer wrote themselves. Deleting that one directory now removes
  the integration cleanly.
  **Migration is automatic:** the sync removes legacy flat
  `.github/instructions/ai-review-*.instructions.md` files on its next run —
  matching that prefix only, never a consumer's own files. Without that step a
  previously-synced repo would get every instruction twice (Copilot reads both
  locations) and would strand a stale overlay at the old path on a `PROFILE`
  switch. Consumers who copy the workflow by hand must take the updated
  example; the sync only ever writes `.github/instructions/`, never the
  workflow file.
  Also corrects a claim in the docs: Copilot does **not** see only a flat
  directory. It applies no precedence *between* instruction files, which is a
  different thing and is why each additions file still states what it
  overrides.
- **`actions/checkout` is now SHA-pinned in the docs and examples**
  (`3d3c42e…` # v7.0.1) rather than the floating `@v7` tag. The quickstarts are
  copied verbatim into consumer repos, so a floating tag there taught the
  opposite of what [docs/security.md](docs/security.md) tells consumers to do —
  and did: a consumer that SHA-pins every other action inherited its one
  floating pin from our example. This repo's own `.github/workflows/` still use
  major tags; pinning those is a separate call.
- **GitHub Actions pinned to current majors for the Node 20 runner
  deprecation** — `actions/checkout` `v4` → **`v7`** (the examples, the docs
  quickstarts, and this repo's own CI), plus `setup-python` `v5` → **`v7`**,
  `setup-java` `v4` → **`v6`**, and `upload-artifact` `v4` → **`v7`** in
  `.github/workflows/`. Node 20 is deprecated on Actions runners, so each of
  these was being force-run on Node 24 with a warning on every run — including
  every consumer who copied a quickstart. Note `upload-artifact@v5` is still
  Node 20; v6 is the first Node 24 major. `attest-build-provenance@v4` is
  unchanged: it is a composite action with no Node runtime of its own, and v4
  is still its current major.
  Two behavior notes: `checkout@v7` refuses to check out a fork PR under
  `pull_request_target` / `workflow_run` (this repo already tells consumers
  never to use `pull_request_target`, so nothing here is affected), and these
  majors require Actions runner **2.327.1+** — relevant only to self-hosted
  runners.
- **Compliance profiles are now additive, and `baseline` is the default**
  (was `cms-ars`). The framework-neutral rubric (CIS / NIST CSF / OWASP) moved
  to `engines/security-compliance-review/skills/base/iac-compliance.md` and
  **always** applies; a profile's `iac-compliance.md` is appended on top as an
  addition that takes precedence on conflict, rather than replacing it.
  `cms-ars` was rewritten to hold only its deltas — NIST/ARS control-ID
  citations for the base findings, plus the CMS/HIPAA-specific checks the base
  lacks (MFA, vulnerability/posture monitoring, WAF/DoS, malware & image
  provenance, pipeline integrity, and the detailed PHI/PII log-content
  review). The same split was applied to the **Copilot instructions**:
  `copilot-instructions/base/instructions/` always syncs, and a profile
  contributes `ai-review-*-additions.instructions.md` layered on top (the sync
  workflow also removes a stale overlay when `PROFILE` changes).
  **Breaking-ish:** a consumer who relied on the old `cms-ars` default must now
  set `profile: cms-ars` explicitly to keep the agency overlay; a custom
  bring-your-own profile directory now only needs to contain its deltas, not a
  full standalone rubric. See [docs/profiles.md](docs/profiles.md).
- **Repo restructured into three shippable layers** (skills · harness ·
  adapters). The engine tree is now `engines/`: the workflow-agnostic runtime
  lives once in `engines/_common/` (dispatch, result markers, JSON extraction,
  fan-out, adjudication, `endpoints.sh`, the SCM seam, the experimental
  sandbox — interface documented in `engines/_common/CONTRACT.md`), and each
  workflow is a self-contained `engines/<name>/` holding its `skills/base/`
  (+ `skills/profiles/`) and a thin `harness/<entrypoint>` that sources
  `_common`. The former `engine/` became `engines/security-compliance-review/`
  + `engines/_common/`; consumer-facing action paths
  (`workflows/security-compliance-review`, `workflows/test-classifier`) are
  unchanged. The shared runtime gained a per-workflow marker/JSON-fence
  parameterization and a suite-running invocation posture (`AI_RUN_SUITE=1`)
  used by the test classifier; the review's read-only invocation behavior is
  unchanged. The Jenkins plugins bundle `_common` + their workflow engine in
  the `.hpi` (entrypoint moved to
  `security-compliance-review/harness/ai-security-compliance-review`).

### Fixed

- **`COPILOT_SYNC_TOKEN` is scoped to `Pull requests: Read and write` only.**
  It was documented with `Contents: Read and write`, which it never uses: the
  sync token authenticates only `gh pr list` and `gh pr create`, while the
  branch push authenticates as the built-in `GITHUB_TOKEN` that
  `actions/checkout` persists into `.git/config`, under the workflow's own
  `contents: write`. `Contents: Read-only` is named as the fallback if
  `gh pr create` turns out to verify the head ref. The Jenkins SCM token is
  unaffected and still needs `Contents: Read` — it reads the repo.
- **The `Suggestion:` line in a posted comment carries its one-line summary
  again.** The pre-restructure reviewer
  (`navapbc/ai-transformation-delivery-systems`, `security/review`) rendered
  `Suggestion: <one-line summary of the suggested change>`; the restructure
  dropped the summary and emitted a bare `Suggestion:` header, the only
  difference in posted-comment formatting between the two. The AI can now emit
  `suggestion_summary` (an imperative describing the *fix*), and the dispatcher
  falls back to the first sentence of `description` when it doesn't — the same
  fallback the original specified. The header renders bare when neither yields
  anything, never with a trailing space.
- **The Copilot instructions sync workflow stopped opening PRs after the first
  one was closed or merged.** It tested for an existing PR with
  `gh pr view <branch>`, which matches a CLOSED or MERGED PR on that branch just
  as readily as an open one. Once the first sync PR left the open state, every
  later run pushed the updated branch, reported "Existing sync PR updated", and
  skipped `gh pr create` — so instruction updates piled up on
  `ai-review/instructions-sync` with no PR to review them and a green check on
  the run. Now scoped with `gh pr list --head <branch> --state open`.
  Consumers must copy the fix into their own
  `.github/workflows/copilot-instructions-sync.yml`: the sync only ever writes
  `.github/instructions/`, never the workflow file itself.
- **The review now diffs `base...HEAD`, not `base..HEAD`.** A pull request's
  diff is what the branch changed since it diverged; the two-dot form
  additionally reported, inverted, every commit landed on the base branch
  since the fork. On a branch whose base had moved — the common case — other
  people's work was attributed to the PR: files it never touched appeared as
  deletions, were batched and reviewed at full token cost, and their findings
  could fail a `--gate` build on somebody else's commit. `AI_REVIEW_AGAINST`
  is now resolved to the merge base, which corrects every consumer at once
  (the diff helpers, the classifier's diff range, the fan-out workers, and the
  `git diff "$AI_REVIEW_AGAINST" HEAD` the rubric tells the model to run). The
  Action deepens history as needed to find the branch point, since
  `actions/checkout` defaults to `fetch-depth: 1`; where no merge base is
  reachable the engine warns and falls back to the old behavior rather than
  failing.
- **The gate can no longer fail open.** Three paths could report `APPROVE`
  for a review that had found something: `fold_review_json.py` silently
  dropped findings missing `path`/`line` and then hard-coded `APPROVE`;
  `github_payload.py` dropped the same findings instead of moving them into
  the review body; and the Jenkins plugin's `readReviewAction` returned
  `APPROVE` whenever its regex missed in a findings file that existed. All
  three now surface the finding and keep the non-clean verdict, and an
  unparseable findings file fails the step instead of passing it.
- **`persist-credentials: false` no longer breaks private repositories.** The
  base-ref fetch ran without a token and swallowed failure, so the hardening
  `docs/security.md` recommends made the review die later with a misleading
  "Git ref not found". That fetch is a trusted, AI-free step and now
  authenticates via a per-invocation credential helper — the token stays out
  of argv and is never written to `.git/config`, so the AI phase still sees a
  credential-free repository.
- **`context-budget` now actually does something.** Its value was never
  interpolated into the prompt — the rubric only *named*
  `$AI_REVIEW_CONTEXT_BUDGET`, which the read-only tool grant gives the model
  no way to read. The resolved ceiling is now stated in a CONTEXT BUDGET
  prompt block, and fan-out workers' per-batch narrowing reaches the model.
- **`--unpushed`** forced needless PR discovery and then had its resolved base
  overwritten, leaving it diffing against the PR base with the staged-diff
  flag still set.
- The GitHub Action's `result` output is now always set (an empty diff reports
  `APPROVE`), matching the Jenkins plugin; `ci_shared.bats` and
  `workflows/_shared/lib` are covered by CI, not just `tests/run.sh`.
- **Copilot-instructions sync: works without granting Actions approve rights.**
  The sync workflow now degrades gracefully when GitHub's default-off "Allow
  GitHub Actions to create and approve pull requests" toggle is disabled: the
  branch is still pushed and a compare URL is printed for a human to open the
  PR. An optional `COPILOT_SYNC_TOKEN` secret (fine-grained PAT / App token)
  enables fully automatic PR creation — with the toggle still off and normal
  `pull_request` CI on the sync PR. Both platform behaviors are documented in
  the workflow header.
- **copilot BYOK hardening:** set-but-empty `COPILOT_PROVIDER_*` /
  `COPILOT_MODEL` env vars (as rendered by unset Action inputs) are unset by
  the engine before the copilot CLI runs, so they can never read as "BYOK
  enabled with an empty endpoint".
- Documented the benign Codex "model metadata not found" warning for Bedrock
  model IDs in [docs/private-endpoints.md](docs/private-endpoints.md).

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
- **Compliance profiles** (`AI_REVIEW_PROFILE`, default `baseline`): the
  compliance perspective always applies a framework-neutral floor (CIS /
  NIST CSF / OWASP); a selectable profile can *add* framework-specific
  citations and checks on top without replacing or weakening it. Ships
  `baseline` (the floor, no additions) and `cms-ars` (adds CMS ARS 5.1 /
  NIST 800-53 control-ID citations plus CMS/HIPAA-specific checks) under
  `engines/security-compliance-review/skills/profiles/`, plus a
  bring-your-own directory path (also additive). Surfaced as the
  `profile` input (Action), the `profile` step/global param (Jenkins), and the
  `PROFILE` in the Copilot-instructions sync workflow. See
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
  `applyTo`-scoped base files that always sync, plus optional per-profile
  `*-additions` files layered on top, distributed by a **self-serve pull**
  workflow ([`examples/workflows/copilot-instructions-sync.yml`](examples/workflows/copilot-instructions-sync.yml))
  that each consumer runs in its own repo with its own token — `ai-common-workflows`
  keeps no subscriber list and needs no cross-repo credential.
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

- **Signed build provenance for the Jenkins plugin releases.** The release
  workflow now attests both `.hpi` files with
  `actions/attest-build-provenance` (Sigstore-signed SLSA provenance, logged in
  the Rekor transparency log), binding each artifact digest to this repo, the
  release workflow, and the tagged commit. Admins verify pre-install with
  `gh attestation verify <file>.hpi -R navapbc/ai-common-workflows` (gh ≥ 2.49).
  The `.sha256` sidecars remain for download integrity; the attestation is the
  authenticity check.
- **The SCM token is kept out of the AI (review) phase.** The Action and the
  plugin run the review with no `GITHUB_TOKEN`/`GH_TOKEN` in its environment and
  post in a separate process that holds the token, so prompt-injected PR content
  can't reach a repo-write credential. Exception: the `copilot` backend, whose
  model auth is itself a GitHub token.
- Egress control is the consumer's infrastructure responsibility; a built-in
  Docker egress sandbox exists under `engines/_common/sandbox/` but is
  **experimental and not wired into the shipped Action/plugin** (see its
  README). Least-privilege credentials and SHA/checksum pinning are documented
  as imperative in `docs/security.md`.

[Unreleased]: https://github.com/navapbc/ai-common-workflows/commits/main
