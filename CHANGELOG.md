# Changelog

All notable changes to this project are documented here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/); the project aims to
follow [Semantic Versioning](https://semver.org/).

## [Unreleased]

### Added

- **§ 3D "Language and Framework Hazards"** in the security perspective, and
  a doc section explaining why there are no per-language rubrics.
  The rubric stays language-neutral by design. § 3D instructs the reviewer to
  apply the hazards idiomatic to whatever is actually in the diff, to **name
  the language or framework** in the finding so a reader can tell a general
  principle from a framework rule, to take framework identity from a manifest
  or an import rather than a file extension, and **not to assert
  version-specific behaviour it cannot see** — a hazard that depends on a
  default which changed between majors is reported as conditional rather than
  asserted. Severity still comes from the one ladder: a finding is not more or
  less severe for being language-specific.
  It delegates rather than enumerates, so there is nothing in it to go stale —
  which is the whole point. A `java.md` would be confidently wrong about Spring
  Security's defaults within a release or two, and a wrong citation is worse
  than silence because it arrives with the same authority as the parts that are
  still right. The model's framework knowledge is also newer than ours, and
  language depth is what Semgrep and CodeQL are genuinely better at — which is
  the "alongside, not instead of" division of labour doing real work.
  `docs/security-compliance-review.md` records that reasoning so the decision
  is not relitigated as an oversight, and `docs/profiles.md` notes that a
  profile is the right home for framework rules a program does need: knowledge
  with a short half-life belongs near the people who will notice it ageing.
- **`--resume` for the codebase audit**, restoring the one capability the
  earlier iteration had that the new bundle format dropped. It continues the
  newest existing bundle for the repo instead of allocating a new run
  directory: directories that already have a report are skipped, and their
  findings are merged into the regenerated index.
  The failure worth guarding was a resumed run **deleting** what it was meant
  to preserve — the bundle is regenerated from the findings JSON, so without
  carrying the previous findings forward the already-written directory docs
  would have been rewritten empty. Prior findings are merged and de-duplicated
  by (path, line, perspective, title), a clean resumed segment cannot downgrade
  a bundle that already has findings to `APPROVE`, and the narrative is
  appended under a `## Resumed segment` divider rather than replaced.
  Resume works at **directory** granularity, matching the reports. Not per
  batch: packing coalesces directories into at most `--jobs` bins, so "already
  done" would mean something different at `--jobs 4` than at `--jobs 8`.
  Nothing left to audit says so and leaves the bundle alone; no existing bundle
  starts a fresh one and says that too. Searching is not restricted to today —
  an audit interrupted last night should be resumable this morning, and the
  directory's date records when the audit started.
- **The audit confirms before it spends.** It prints the plan — scope, file
  count, batch count, expected model calls, endpoint (flagged when public) and
  report destination — then waits on `Proceed? [y/N]`. Anything but `y` aborts
  having sent nothing. `--yes` / `-y` / `AI_AUDIT_ASSUME_YES=1` skip it.
  When stdin is **not a TTY** it refuses outright rather than prompting into
  the void, and the refusal names the file and batch count it would have used:
  a scripted run should not be able to spend by accident. The no-AI-call paths
  (`--dry-run`, `--list-files`, `--list-batches`) never prompt — inspecting
  cost must not require confirming a spend.
- **The codebase audit writes a report bundle**, not just a terminal dump.
  `--output-parent-dir` is now **required** for a real run: an existing
  directory, into which each run creates its own
  `<repo>-<YYYYMMDD>-<NN>` subdirectory. The parent is never created — a typo
  that silently makes a deep path is how a report ends up somewhere nobody
  looks again — and the run number is allocated by scanning the parent, so a
  second audit the same day is `-02` rather than an overwrite. Reports get
  attached to tickets and compared week to week; an overwritten one is worse
  than a missing one because nobody notices.
  The bundle restores the shape the earlier iteration of this tool had, and the
  habits people built on it: a **findings-first `_INDEX.md`** (directories with
  findings first, worst severity first, each linking into that directory's
  findings; clean directories collapsed into a `<details>` at the bottom; a ✅
  note when nothing was found; a suggested triage order), one markdown doc per
  directory with `/` rendered as `__`, and every finding as a `#### ` heading so
  `grep -rl '^#### '` lists exactly the docs worth opening. Plus `report.md`
  (the narrative, including the posture summary) and `findings.json`.
  Generated from the merged findings rather than per-worker output, so the
  bundle is identical whether the audit ran as one call or fanned out — a
  report whose shape depends on `--jobs` cannot be compared against last
  week's. `--json-out` / `--md-out` remain as extra copies at exact paths, and
  `--json-only`, `--dry-run`, `--list-files` and `--list-batches` need no
  output directory, since inspecting scope and cost should not require deciding
  where a report goes.
- **`tests/python/test_entrypoint_invariants.py`** — static guards for the
  obligations an engine entrypoint inherits from `_common`, written after the
  audit shipped without `ai_review::configure_endpoint`. That bug was invisible
  to every existing suite: the engine ran, the JSON parsed, the marker was
  found — the only symptom was that `AI_REVIEW_PROVIDER` did nothing and the
  traffic went somewhere the operator had not chosen. A missing *setup call*
  has no failing assertion unless something checks for the call itself.
  Seven invariants: any entrypoint that invokes a model must configure the
  endpoint and resolve the tool; every entrypoint must call `parse_args` (or
  the shared flags look broken rather than unimplemented), override the generic
  `print_help` (or print help for a workflow the reader is not running), set
  `SKILL_NAME` before logging (or the first `info` call dies on an unbound
  variable under `set -u`), and derive `ENGINE_HOME` from `BASH_SOURCE` rather
  than the CWD (or the rubric is read from the *audited* repo). Plus one
  asserting the entrypoint glob matched something, since a glob that matched
  nothing would make the rest vacuous.
- **`tests/corpus/`** — a detection corpus: fixture diffs with expected
  findings, plus a runner and a scorer. It is the only thing in the repo that
  measures whether the **review** is any good; everything in `tests/bats/` and
  `tests/python/` tests the envelope and would still pass if the rubric
  reported nothing. Run it before and after a rubric change and compare the
  delta — `bash tests/corpus/run.sh`. Excluded from the default suite because
  every case is a real model call.
  Eight seed cases across the distinct rubric areas, **three of them negative**
  (a parameterized query, a correctly-encrypted database, a pure refactor):
  precision is what decides whether a team keeps the tool switched on, and a
  corpus of only positive cases rewards a rubric that reports everything.
  `expected.json` matches on path, a severity floor, perspective and concept
  substrings rather than phrasing — a corpus that fails because the model wrote
  "credential" for "secret" measures wording and gets ignored within a week.
  `README.md` documents five sources for growing to 20+, in descending order of
  value, starting with one case per rubric rule.
- **The posted review now carries its own scope disclaimer.** Docs saying
  "advisory" do not reach a PR reader. Every review body states that it is
  advisory and not exhaustive, that it complements rather than replaces SAST /
  dependency scanning / secret scanning, and — the part that matters for
  compliance work — that any control IDs it cites are **model-generated and
  unverified**, because an ARS or NIST citation in a PR comment reads like an
  audit artifact and may be carried into a deliverable.
- **`tests/python/test_pin_hygiene.py`** — CI now enforces the SHA-only pinning
  rule instead of relying on reviewers to notice. It fails on a tag or branch
  pin of this repo in any doc, example or README, on a non-SHA `ACW_REF`, and
  on the prose loophole ("a commit SHA or a release tag") that is how the rule
  eroded in the first place. Verified against all three regression forms rather
  than only observed to pass, plus a test asserting the scan matches something
  at all — a regex that matched nothing would make the rest vacuous.
- **`max-comments`** — a cap on inline comments per review, default 15
  (`0` disables it). Above the cap the highest-severity findings stay inline
  and the rest are listed in the review body with counts by severity. Nothing
  is dropped, and the gate is unaffected: it reads the engine's findings JSON,
  so a capped review blocks exactly as it would have uncapped.
  There was previously no limit, so a large PR could post dozens of inline
  comments — which is how a review bot gets switched off, a failure that cannot
  be recovered because the disable is cultural rather than technical.
  Selection is by severity with the report order as the tie-break, so the
  chosen subset is stable across re-runs (an unstable cut would post a
  different subset each time and defeat the idempotency suppression). An
  unrecognized severity sorts last rather than first, so it cannot evict a
  known CRITICAL from an inline slot, and the comments are emitted in diff
  order so they land where the code is.
- **The review's `--dry-run` now reports the expected AI call count** and the
  inline cap alongside the batch routing it already printed — fan-out
  multiplies the first pass per batch and `adjudication: independent` adds one
  more on a finding-bearing review, which was documented in prose but not
  visible in the plan. The audit already did this.
- **Codebase audit** — a second entrypoint on the security-review engine,
  `engines/security-compliance-review/harness/ai-security-compliance-audit`,
  that audits an existing repository (or given paths) rather than a change to
  one. Same rubric, severities and findings JSON as the PR review, so findings
  from the two are comparable; a new `skills/base/codebase-audit.md` supplies
  the procedure, the line-anchoring rules whole-file review needs, and a
  posture summary a diff review has no use for.
  **Local and ad-hoc by design.** No composite action, no Jenkins step, no
  posting, no SCM token, and no `--gate` — a full-repo audit costs about one
  model call per batch every run, which is fine by hand and expensive on every
  push, so it is deliberately not wired into any workflow and warns when it
  detects CI. Nothing is written into the audited repo: reports go to stdout or
  to paths named with `--json-out` / `--md-out`.
  **Nothing to vendor.** The earlier iteration
  (`navapbc/ai-transformation-delivery-systems`, `security/review`) required
  syncing a `.skills/` directory into every audited repo. The rubric is read
  from the engine's own directory, so a single clone audits any checkout.
  Scope is `git ls-files`-based (untracked and gitignored files are never
  audited; binaries and files over 256 KB are skipped with a printed reason),
  narrowable by path, `--include`/`--exclude` and `--max-file-bytes`, and
  `--list-files` / `--dry-run` report scope and expected call count before
  anything is spent. `--profile` selects the compliance profile, where the base
  audit rubric always applies and a profile's copy is layered on top as an
  addition. Fan-out, adjudication (`self` by default) and JSON folding are
  reused unchanged. See [docs/codebase-audit.md](docs/codebase-audit.md).
- **`gate: true` fails the job on HIGH or CRITICAL findings**, not on any
  finding. `gate` is a boolean and still defaults to `false`; only what `true`
  means has changed. Previously it failed on any non-`APPROVE` result, and the
  review emits a finding-bearing result for a single LOW observation — so
  gating blocked merges on nits and was effectively unadoptable as a required
  check. MEDIUM and LOW still post as inline comments: gating changes what
  fails the build, never what is reported. The HIGH floor is fixed rather than
  configurable; a different line, if one is ever needed, belongs in its own
  named input rather than as a second kind of value in this one.
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

- **`docs/codebase-audit.md` documents profiles properly.** It showed
  `--profile base,cms-ars` in one example, never explained that the value is an
  ordered list whose first entry must be `base` or `none`, never linked
  `docs/profiles.md`, and had a troubleshooting row reading as though a bare
  `cms-ars` were valid — which is now a configuration error. It now has a short
  section covering the list form, why the bare form is refused, `none` as the
  escape hatch, and that a profile may ship its own `codebase-audit.md`
  additions.
- **`docs/codebase-audit.md` leads with the endpoint decision**, before the
  quickstart: Bedrock, Azure OpenAI, Vertex and self-hosted gateways first with
  copy-paste exports, the public API after. The reason is specific to the audit
  — a PR review exposes the lines someone changed, an audit of `src/` exposes
  `src/` — so the data path is the first decision, not a later tuning step.
  It also notes that the endpoint is per-invocation: an audit run without the
  exports goes to the public API, so they belong in a shell profile.
  `docs/private-endpoints.md` now states up front that it covers the audit too.
- **`docs/security-compliance-review.md` opens with the division of labor**
  against SAST, SCA and secret scanning, before the quickstart: what each tool
  is best at, and the four things this review structurally cannot do
  (diff-scoped, probabilistic, no CVE database or reachability analysis,
  unverified control IDs). A program could previously read "security review"
  as covering what CodeQL and Dependabot cover. `docs/github-action.md` gains a
  short Scope section pointing at it.
- **A commit SHA is now the only accepted pin, everywhere.** Four places still
  offered a release tag as an alternative — `copilot-instructions/README.md`,
  the sync workflow's header, `docs/security.md`'s `ACW_REF` paragraph, and the
  maintainer guidance in `docs/copilot-instructions.md`. A git tag is a mutable
  pointer: it can be deleted and re-created against a different commit, and
  nothing in a consuming workflow would notice. `docs/security.md` now states
  that reason next to the rule, so the next reader cannot weaken it back
  without arguing with it.
  Because the rule is only as good as its friction, the same section now shows
  how to resolve a release to its SHA in one command, and a Dependabot config
  that keeps SHA-pinned `uses:` references current and rewrites the `# vX.Y.Z`
  comment with them — plus the honest note that nothing can do this for
  `ACW_REF`, which is a plain environment variable rather than a recognized
  dependency.
- **`docs/github-action.md` inputs are grouped by when you would reach for
  them** rather than listed flat: getting it running, deciding how loud it is,
  keeping the model in your boundary, tuning cost on large diffs, and
  debugging. It now opens by saying 31 of the 34 inputs are optional and that
  almost every team needs exactly three, with a copy-paste starting
  configuration — a flat list of 34 knobs reads as 34 decisions to make.
- **`profile` is now an ordered list of rubric sources, with the shared floor
  as an explicit member.** `base` | `base,cms-ars` | `base,cms-ars,pci-dss` |
  `none,my-agency-everything`. Sources layer in order, each only ever adding to
  what is above it, and the **last entry wins** a genuine conflict. The
  whole-file override path is **deleted** — `pr_review::rubric` and
  `audit::rubric` are gone, with a test that fails if either returns — so no
  source can replace or suppress what precedes it.
  **The first entry must be `base` or `none`.** Omitting the floor is a silent,
  severe failure: the review still runs, still posts, still reports a verdict,
  having checked almost nothing against ~1,250 lines of rubric that are no
  longer there. `profile: cms-ars` is a natural thing to type, so it is a
  configuration error rather than a quiet downgrade. `base` must also be first —
  listed later it would outrank the overlays layered before it.
  `none` is the full-control escape hatch, declared in the config where a
  reviewer can see it, replacing a per-file override that silently substituted a
  base file. A `none` list must still supply the file carrying the output
  contract (`pr-review.md`, or `codebase-audit.md` for the audit); otherwise the
  run fails up front naming that file, rather than dying later on unparseable
  output.
  `finding-adjudication.md` is deliberately **outside** the list and always read
  from `skills/base/`: it governs how findings are judged, not what is looked
  for, so `none` does not cost a program its false-positive filter.
  Composition lives in `ai_review::resolve_profiles`, `ai_review::rubric_block`
  and `ai_review::require_rubric` in `_common`, shared by the review and audit
  entrypoints rather than duplicated in each.
  **Removed:** the `baseline` profile directory, which was a 10-line README
  standing in for "the floor alone" — now spelled `base`. The `profile` input
  and `AI_REVIEW_PROFILE` default from `baseline` to `base`.
  **Not changed:** the Copilot instructions sync still takes a single `PROFILE`
  whose base set always syncs. It copies files rather than assembling a prompt,
  so the list form is a separate change with its own stale-overlay problem.

- **`ai_review::plan_diff_batches` split into a generic grouper plus a
  diff-scoped caller.** `ai_review::group_files_into_batches` takes file paths
  on stdin, so a workflow whose scope is not a diff reuses the same grouping,
  packing and context budgeting instead of growing a parallel planner that
  would drift from it. `ai_review::fan_out`'s worker flag is likewise now
  `AI_REVIEW_WORKER_FLAG` (default `--__review-one`) rather than hardcoded.
  No behavior change for the existing callers.
- **The docs now steer consumers to the Action rather than presenting it and
  Copilot's native review as equivalent options.** They were described as two
  independent reviewers, which understated the difference: the Action is the
  only path that can block a merge (Copilot submits no blocking review and
  emits no status check), the only one that adjudicates its own findings, and
  the only one where you pin the model and choose whether the diff leaves your
  boundary — plus it emits `review-json` / `result` for downstream automation.
  `docs/copilot-review-setup.md` gains a "what the action does that this does
  not" comparison and opens by saying to adopt the Action first;
  `docs/security-compliance-review.md`, `copilot-instructions/README.md` and
  the top-level README carry the same steer, framing Copilot's review as a
  complement worth adding *after* the Action rather than instead of it.
  Also drops a stale "no CI minutes" claim from the setup page and the README,
  which contradicted the metered-not-free correction already in
  `copilot-instructions/README.md`: Copilot code review consumes AI credits
  and, since 1 June 2026, Actions minutes on private repositories.
- **`--gate` on the engine now matches the composite action**: it fails on a
  HIGH or CRITICAL finding rather than on any non-`APPROVE` result. Local runs,
  the sandbox wrapper and the Action previously disagreed — the Action gated at
  HIGH while the other two blocked on a single LOW finding.
  The decision moved into `engines/_common/harness/gate_verdict.py`, the one
  implementation of "does this review block", reached through
  `ai_review::gate_blocks`. It replaces three separate
  `review_action != "APPROVE"` comparisons (engine entrypoint, sandbox wrapper,
  action gate step), which is what let them drift in the first place. The
  action's gate step no longer parses the findings JSON itself either: one call
  returns both the `result` output and the verdict.
  It cannot fail open by construction — an unreadable findings file or an
  unrecognized severity is reported as blocking, and a caller that cannot get a
  verdict must block.
  **The Jenkins plugin is deliberately not converted yet** and still fails on
  any non-`APPROVE` result, so it gates stricter than the Action rather than
  looser. Converting it means changing its smoke-test stub too — the stub emits
  `{"review_action":"COMMENT","comments":[]}`, which the shared evaluator
  correctly reads as PASS, so three gate tests would need a blocking finding to
  keep testing what they were written to test. The reactor is CI-verified only,
  so that belongs in its own change where the Jenkins job is the whole signal.
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

- **The codebase audit ignored `AI_REVIEW_PROVIDER` entirely.** It never called
  `ai_review::configure_endpoint`, so an audit configured for Bedrock, Vertex
  or Azure OpenAI went to the **public API** with whatever key happened to be
  in the environment — and reported nothing about it. This is the worst shape
  of failure the audit can have: unlike the PR review it sends the whole scope
  rather than a diff, so an ignored endpoint setting means an entire codebase
  to the wrong place. A misconfiguration is now a hard error before the model
  is called (`provider=bedrock requires AWS_REGION`) rather than a silent
  fallback, and `--dry-run` prints a `Provider:` line — flagged
  `(PUBLIC endpoint …)` on the default — so the data path can be checked
  before anything leaves the machine. Endpoint validation still runs after the
  dry-run gate, so inspecting the plan needs no credentials.
- **The review body's feedback ask is now the last line.** It was appended to
  the summary before the overflow sections, so "was this helpful?" appeared
  above the out-of-diff, unanchored and capped findings and read as the end of
  the review. The body is now assembled in a fixed order — summary, scope
  disclaimer, finding sections, attribution last.
- **`adjudication-model` was silently ignored under `provider: azure`.** Azure
  resolves the model from the request URL path, and the engine bakes the
  deployment into `OPENAI_BASE_URL` once at startup; the adjudication pass only
  varied the CLI's model flag. So an `independent` pass configured with a
  second deployment re-ran the **first-pass deployment** — it looked like a
  second opinion and was not one, with nothing warning about it.
  The engine now records the URL template it built and rebuilds the URL for the
  adjudication call, so a different deployment genuinely is used. When the URL
  came from a caller-supplied `openai-base-url` it cannot be rewritten safely
  (the deployment name could be anywhere in it), so that combination is now a
  startup configuration error instead — failing before the first pass is paid
  for rather than after. `self` adjudication is unaffected: it is one call, so
  the override never applied.
  Every other provider was already correct — they select the model from the
  CLI's model flag, and the URL carries no model.
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
