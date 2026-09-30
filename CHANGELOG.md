# Changelog

All notable changes to this project are documented here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/); the project aims to
follow [Semantic Versioning](https://semver.org/).

## [Unreleased]

### Added

- **Release automation**, re-cut against `main` rather than merging #10.
  Tagging `vX.Y.Z` on `main` publishes a GitHub Release whose notes carry the
  exact `uses:` line with the SHA to pin. Nothing is built or uploaded — the
  action is source GitHub fetches at `uses:` time, so the tag's commit *is* the
  artifact. Pre-releases (`v1.2.0-rc.1`) are marked automatically, and the
  Jenkins plugin's `jenkins-plugin-v*` namespace is deliberately unmatched.
  Before publishing it checks that the tag is an ancestor of `main` — a tag can
  be pushed from anywhere, and releasing a commit that never reached `main`
  would ship code no CI run saw — that the consumer-facing surface is present,
  and that every entrypoint is **executable**.
  **The surface list is globs, not names.** #10 hardcoded
  `harness/ai-pr-review` and kept it long after the rename, so its first
  release would have failed on the check rather than on a real problem — and
  nothing noticed, because a release workflow only runs when you release.
  `tests/python/test_release_surface.py` now runs those same checks on every
  PR, and fails if the gate ever names a path that does not exist.
  **No moving `vX` alias**, deliberately. #10 force-moved `v1` each release and
  offered `@v1` as a pin for pilot repos; that is the mutable pointer
  `docs/security.md` forbids, shipped as a *supported* way around the rule the
  rest of the repo enforces in CI. A release helps a consumer find a SHA, not
  avoid pinning one. A test fails if a force-moved tag reappears.

- **`.gitattributes` marking `CHANGELOG.md` as `merge=union`.** Changelog
  entries are append-only prose and two branches almost always add theirs at
  the top of the same section, so they collide on every rebase even though both
  sides are wanted. Five consecutive PRs hit it and the resolution was "keep
  both" every time — which is precisely what the built-in `union` driver does,
  with no per-clone configuration.
  Scoped to that one file on purpose: union never reports a collision, so on a
  file where two edits can genuinely contradict each other it would hide a real
  conflict. Verified both directions — a changelog collision now rebases clean
  with both entries kept, and a conflicting edit to a `.py` file still stops the
  rebase.
  It does not fix everything. Union concatenates without thinking, so the
  resulting order may be one nobody chose, and GitHub's server-side merge
  ignores merge drivers — a PR can still show as conflicting in the UI while a
  local rebase resolves cleanly. Local rebases are where this was actually
  costing time.

- **`.github/secret_scanning.yml`**, now that the repository is public, plus
  `tests/python/test_secret_fixtures.py` as its compensating control.
  A security reviewer necessarily contains credential-shaped strings: the
  detection corpus and the bats fixtures exist to hand it something that looks
  leaked and check that it says so, and
  `tests/corpus/01-hardcoded-aws-key` *must* look live — when it used AWS's
  documented example pair the reviewer correctly rated it low, which is the bug
  that case was fixed for. Those trip secret scanning on every push, and an
  alert stream that is always noise is one people stop reading.
  So `tests/corpus/**`, `tests/fixtures/**` and `tests/bats/**` are excluded —
  test data only, never code that runs in a consumer's pipeline. `engines/`,
  `workflows/`, `docs/` and the changelog are deliberately **not** excluded
  even though they name the example key in prose: a one-off dismissal there is
  cheaper than a blind spot over the tree that ships.
  The exclusion is a blind spot, so it does not stand alone. The test fails
  when a credential-shaped literal appears outside those paths, when an
  excluded path no longer holds such a fixture (so the exemption cannot quietly
  widen — Markdown prose does not count as justification, or the rubric's own
  discussion of the example key would bless exempting all of `engines/`), and
  when an Anthropic key, GitHub PAT, OpenAI key or private-key block appears
  anywhere at all including the excluded paths.
  A scan of all 109 commits of history found no real credential of any of those
  shapes. The exclusion list is parsed by hand rather than with PyYAML — CI
  installs pytest and nothing else, so a third-party import is a collection
  error that kills the whole job while passing locally. That is now enforced
  for the whole suite by
  `test_the_python_suite_is_stdlib_plus_pytest_only`, because the first version
  of this test shipped with `import yaml` and failed CI exactly that way.
  Verified against five failure forms, and the first verification pass
  caught two further bugs in the test itself: it scanned only `git ls-files`, missing a
  file added in the commit that introduces it — which is exactly when a pasted
  credential arrives — and it let Markdown prose justify an exclusion.

- **`tests/python/test_doc_links.py`** — every relative link and heading
  anchor in the tracked Markdown now resolves, or CI fails.
  Added after a broken anchor shipped:
  `security.md#the-llm-credential-bedrock--vertex` lost its target when "Azure"
  joined that heading. A heading edit silently breaks every link pointing at
  it, in files the editor never opens, and nothing else in the repo would
  notice.
  It immediately found a second one the hand-rolled sweep had missed, because
  that sweep only looked at `docs/` — this walks everything git tracks.
  **The slug rules are pinned by their own tests**, which is the real lesson.
  Two ad-hoc versions of this check each reported a *correct* link as broken:
  one collapsed runs of whitespace, where GitHub maps each space to its own
  hyphen (`Bedrock / Vertex / Azure` → `bedrock--vertex--azure`); the other
  stripped underscores as emphasis, mangling `COPILOT_SYNC_TOKEN`. Both would
  have led to "fixing" a working link into a broken one. A subtly wrong link
  checker is worse than none, so every rule it depends on is asserted directly.
  Headings inside fenced code blocks are not anchors, duplicate headings get
  GitHub's numeric suffixes, links inside fences are not checked (an example
  may reference a path that does not exist here), and external schemes are
  somebody else's uptime problem. Verified against four breakage forms: a
  renamed heading, a missing file, an anchor typo, and the whitespace-collapse
  slugger bug.

- **`postWhenClean` and `maxComments` on the Jenkins step**, closing the gap
  where the plugin inherited a posting behaviour it had no way to configure.
  The plugin bundles the same engine, and `github_payload.py` reads both knobs
  from the environment — so a Jenkins user already got the new quiet-on-clean
  default and the 50-comment limit, with no parameter to change either. A
  default that cannot be overridden is a worse default than one that can.
  `maxComments` is nullable and left unset when null, so the engine default
  applies rather than `0`, which the engine reads as "no limit" — the opposite
  of a conservative fallback. `postWhenClean` is always written explicitly, so
  the step parameter wins over an `AI_REVIEW_POST_WHEN_CLEAN` inherited from
  the job environment; for a boolean, `false` is a value rather than an
  absence.
  Covered by the round-trip test and three smoke tests that assert both
  variables actually reach the engine process. That seam is invisible to both
  existing suites: the Python tests prove the engine honours the variables and
  the Java tests prove the step round-trips, while a parameter that never
  reaches the process would pass both and do nothing.
- **`AI_REVIEW_CLI_NATIVE_AUTH`** — the engine can now run against an AI CLI
  that holds its own interactive login, instead of refusing a configuration
  that works.
  `claude` and `codex` can be logged in interactively, which leaves no key in
  the environment at all. The credential check reads the environment, so it saw
  "no credential" and stopped with `requires ANTHROPIC_API_KEY`. That is the
  normal setup on a developer's own machine, and it blocked the local codebase
  audit and the detection corpus outright — found by trying to run the corpus
  and watching all sixteen cases abort in under a second without a single model
  call.
  The opt-in is **explicit, and `1` is the only value that enables it.**
  Inferring it from a usable CLI login would recreate the failure the check
  exists to prevent: someone who meant to run in-boundary, forgot
  `AI_REVIEW_PROVIDER`, and silently sent their code to the public API on a
  personal login. The engine also never probes the CLI's credential store —
  reading a stored session to decide whether to proceed would make the
  public-endpoint choice implicitly, and that choice has to stay the
  operator's. Every run that uses it warns that the traffic is public and names
  the in-boundary alternative, and `--doctor` reports the credential source
  rather than a bare "ok", because "ok" means something different when the key
  is in the environment than when it is a personal login.
  It relaxes `provider=api` only: a `bedrock` run with no region is still a
  hard error with the variable set, so it cannot become a way to wave past a
  misconfiguration.
  **And it is refused outright in CI** — `CI`, `GITHUB_ACTIONS`, `JENKINS_URL`
  or `BUILD_ID` present means the opt-in is ignored and the missing-key error
  stands, with a line saying why. The variable is not an input on either
  `action.yml`, but a job-level `env:` in a consumer's own workflow propagates
  into composite steps, so "not an input" is not a guarantee. On a hosted runner
  the opt-in would only trade a clear error for a confusing one; on a
  **self-hosted** runner, one whose home directory carries a persisted login
  would quietly use it against the public API — the boundary violation this
  check exists for, on the infrastructure most likely to belong to a program
  that cares. The detection is deliberately broad, and each marker is asserted
  separately, because Jenkins does not reliably set `CI` and "covered by
  `CI=true`" is how the others quietly stop working.
- **Corpus fixtures that assert what they mean**, plus `forbidden`
  expectations in the scorer and the corpus's first offline tests.
  Two of the eight cases failed every run for reasons unrelated to the rubric,
  found by actually running the corpus rather than reading it.
  **Case 01** asserted CRITICAL on a "live-looking" credential while using
  `AKIAIOSFODNN7EXAMPLE` / `wJalrXUtnFEMI/K7MDENG/...` — the pair AWS publishes
  in its own documentation. A self-adjudicated run downgraded it to LOW with
  exactly the right reasoning: those are not live credentials. The model was
  right and the fixture was wrong, so the case measured whether the model
  recognizes AWS's example key rather than whether it catches hardcoded
  credentials. It now uses generated AWS-shaped values with no published
  meaning.
  **Case 05** used `clean: true` on a realistic `aws_db_instance`, so it failed
  on seven legitimate findings — a password from a Terraform variable, missing
  tags, single-AZ — none of which is the mistake it exists to catch. `clean:
  true` there measured how complete the fixture is rather than how good the
  rubric is, and padding the resource until nothing could be said would have
  made it unrealistic instead. It now uses `forbidden`: no encryption finding,
  with everything else still counted as extras so noise stays visible.
  **New case 09** pins the placeholder behavior as intended — AWS's documented
  example keys must not be reported above LOW. Reporting the pattern quietly is
  right; calling it CRITICAL spends a program's attention and, at `gate: true`,
  fails a build over a string that unlocks nothing.
  `tests/python/test_corpus_score.py` gives the scorer its first tests. It had
  none, which was backwards: every other suite tests the envelope, the corpus is
  the only thing that measures whether the review is any good, and the scorer is
  what turns its output into pass/fail — so a scorer that silently stopped
  matching would report improvements that never happened. Also asserts every
  checked-in case is loadable and actually asserts something.

- **`post-when-clean`** — the review no longer comments on a PR it found
  nothing wrong with. Default `false`; set it `true` to post the approval
  anyway.
  Reported as noise by an adopter, and it is: on a healthy repo most PRs are
  clean, so the old behaviour meant a notification per PR per push whose entire
  content was "nothing happened". The job's own check already carries that
  signal. A reviewer that speaks on every PR regardless of whether it has
  anything to say is one people learn to scroll past, and that habit does not
  reverse — it costs nothing to ignore a bot, and no event makes a team start
  reading it again.
  The opt-in exists because the acknowledgement is worth something to some
  programs: a check status is ephemeral and tied to a run that can age out,
  while a review on the PR is part of the record — the difference between
  saying a security review runs and showing it per PR at assessment time.
  Two carve-outs keep the quiet default safe. **Any finding still posts**,
  including one that could not be anchored to a line and therefore lives in the
  review body — "clean" means nothing to report at all, not "nothing inline".
  And a **`REQUEST_CHANGES` review always posts** even when it carries no
  postable finding: that combination means a malformed or lost-findings run,
  and suppressing it would leave an author with a blocked PR and no reason
  given. An unparseable value logs a warning and stays quiet, because
  defaulting a typo to the loud behaviour would spam a PR on every push — the
  exact failure this input exists to prevent.
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
- **`--doctor` on the codebase audit** — a preflight that checks bash, git,
  `python3`, the selected AI CLI, the provider credentials, the endpoint, the
  profile, the repo and the output directory, and reports what is missing.
  It reports **every** problem in one pass rather than stopping at the first,
  because a fresh machine usually has two or three at once; it makes no model
  call and needs no git repository, so a setup can be checked before `cd`-ing
  anywhere. Exit 1 when something is missing, 0 when ready. A public endpoint
  and an unchosen output directory are reported but do not fail it — those are
  choices, not defects.
  Credential and endpoint validation is delegated to
  `ai_review::configure_endpoint` in a subshell, and profile resolution to
  `ai_review::resolve_profiles`, so the whole provider matrix is not duplicated
  here where it would drift. Their messages are surfaced verbatim, indented.
  Aimed at the friction a Mac laptop actually has: the system `python3` is a
  stub that prompts for the Xcode command line tools, and a wrong
  `AI_REVIEW_PROVIDER` is the failure that silently sends the whole scope to a
  public endpoint.
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
- **`max-comments`** — a limit on inline comments per review, default 50
  (`0` disables it). Over the limit the highest-severity findings stay inline
  and the rest are listed in the review body with counts by severity, under a
  heading that says the limit was reached. Nothing is dropped, and the gate is
  unaffected: it reads the engine's findings JSON, so a limited review blocks
  exactly as it would have unlimited.
  There was previously no limit, so a large PR could post dozens of inline
  comments — which is how a review bot gets switched off, a failure that cannot
  be recovered because the disable is cultural rather than technical.
  The default is deliberately generous. The limit is for the pathological PR,
  not for curating an ordinary one: a first run against a repo nobody has
  reviewed before routinely trips 40-odd findings, and at 15 most of them
  arrived as a body list with no line anchor and no suggested fix — the least
  useful form of the same information. It is pinned by a test so a future
  tightening is a decision rather than a drift.
  Selection is by severity with the report order as the tie-break, so the
  chosen subset is stable across re-runs (an unstable cut would post a
  different subset each time and defeat the idempotency suppression). An
  unrecognized severity sorts last rather than first, so it cannot evict a
  known CRITICAL from an inline slot, and the comments are emitted in diff
  order so they land where the code is.
  **The body section says the limit was hit, and no longer misdescribes what
  overflowed.** It used to call the remainder "the lower-severity remainder",
  which is false whenever a diff trips more findings at the top severity than
  the limit allows: selection breaks ties on report order, so the tail of a
  20-CRITICAL review is still CRITICAL. A real run on a seeded Flask app put
  five CRITICALs — command injection in two admin endpoints, SSRF in a health
  check, a blank-token auth bypass, debug mode bound to all interfaces — in
  that list, under a sentence calling them low-severity leftovers. The heading
  now leads with the limit and the count, the blurb states the total and says
  the list can include HIGH or CRITICAL, and it still promises nothing was
  dropped. A reader who only skims inline comments is told, where they are
  looking, that the review had more to say.
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

- **Consistency sweep after the profile rename, and a test so it stops being a
  sweep.** Renaming `cms-ars` introduced a fresh contradiction: three places
  offered `pci-dss` as an example profile *on the same line as*
  `cms-ars-5.1` — `base,cms-ars-5.1,pci-dss` in `docs/profiles.md`,
  `core.sh` and the action's `profile:` description. PCI DSS publishes
  revisions, so the rule was being broken in the act of stating it. Now
  `pci-dss-4.0`.
  The sweep also caught `docs/adding-workflows.md` still describing profiles as
  *"resolved from `skills/profiles/<name>/` with fallback to `skills/base/`"* —
  the pre-additive override model, the same stale claim fixed in
  `architecture.md`, in a file edited two PRs ago without anyone noticing. It
  now describes the floor-plus-appended-layers model and points at the
  versioning convention.
  `tests/python/test_profile_naming.py` enforces all three parts of the rule:
  bundled profile directories implementing a versioned standard carry a
  revision; illustrative names in any doc, comment or config carry one too,
  because an example is the copy people paste; and rubric **filenames** never
  do, since they are the layering join key and a versioned filename would stop
  composition silently rather than failing.
  Its contrast exemption is scoped **per standard**, not per line: a sentence
  like "`cms-ars-5.1`, not `cms-ars`" has to state the bad form, but
  `base,cms-ars-5.1,pci-dss` carries one of each and is precisely the bug — a
  blanket "this line mentions a versioned name" exemption would have excused
  it. Verified by injecting that exact line, a de-versioned profile directory,
  and a versioned rubric filename.

- **The CMS ARS profile is now `cms-ars-5.1`.** ARS is a versioned standard and
  the profile name did not say which revision it implemented — the revision
  lived only in prose, 19 mentions, already inconsistent (roughly half omitted
  it).
  Two requirements settle it. Programs sit on **different revisions during an
  assessment cycle**, so the repo has to carry more than one at once, which an
  unversioned directory cannot express. And "which revision did this judge
  against?" has to be **answerable from the tooling**: the audit already
  recorded the profile string in its report header, and a posted review now
  carries a `Judged against:` line, so `base,cms-ars-5.1` states the revision
  where `base,cms-ars` could not.
  **No alias, no deprecation shim** — there are no consumer repos yet. An old
  name fails at `resolve_profiles`' existing `exit 2`, whose message lists
  bundled profiles via `find` and so needs no maintenance. An unversioned name
  is deliberately *not* an alias for "latest": that is the mutable pointer the
  versioning removes.
  The revision is in the **directory** name only. Rubric filenames are the
  layering join key — `rubric_block` matches a profile's file to the floor's by
  identical filename — so a versioned filename would break composition.
  `docs/profiles.md` gains a **Versioning a profile** section; it had no
  versioning policy at all.

- **The Copilot instruction sync now tracks `main` instead of a pinned SHA.**
  It was pinned *and* cron'd, and the two cancelled out: a fixed ref re-fetches
  identical content forever, the workflow is idempotent ("no diff → no PR"), so
  the schedule did nothing until a human hand-edited `ACW_REF`.
  `docs/copilot-instructions.md` claimed otherwise — "consumers pick the change
  up the next time their sync workflow runs against a ref they've pinned to" —
  which was simply false, and is why bumping `ACW_REF` kept coming up as manual
  work.
  **The PR is the gate.** The sync never pushes to a consumer's default branch;
  every change lands as a reviewable PR whose diff is plain English. That is a
  stronger control than a pin, not a weaker one: a SHA gates a forty-character
  value nobody inspects, the PR gates the content itself. Requiring both put an
  unread gate in front of a read one.
  This is a deliberate **exception** to the SHA-only rule, not a relaxation of
  it. The rule exists because `uses: org/repo@ref` runs that repository's code
  in your job with your token — a mutable ref is a mutable execution path. The
  sync executes nothing: it copies Markdown, and its only `uses:` is
  `actions/checkout`, still SHA-pinned. `docs/security.md` gains **The
  instruction sync's one exception** stating all of this, including the
  residual risk (a compromised upstream plus a reviewer who merges without
  reading) and the supported opt-in for programs that require a pin.
  Because an unexplained exception reads as erosion and invites someone to
  "fix" it back, `test_pin_hygiene.py` now holds that **every file mentioning
  `ACW_REF` also explains that the PR is the gate**, that the value is `main`
  or a SHA but never a tag, and — closing a loophole the old value-only check
  could not see — that no `ACW_REF` line offers a tag in a trailing comment.
  The example carried `ACW_REF: REPLACE_WITH_COMMIT_SHA # e.g. a 40-char SHA,
  or v1.0.0` four lines below a block saying "NOT a tag"; the value was an
  allowlisted placeholder, so nothing caught it.

- **`docs/adding-workflows.md` refreshed.** It had drifted in three ways.
  Its repository tree omitted half of `engines/_common` — `gate_verdict.py`,
  `fold_review_json.py`, `write_audit_report.py`, `scm/github_payload.py`, the
  unshipped `sandbox/` — and the audit entrypoint, so a reader could not see
  that one engine carries two entrypoints. It labelled `skills/profiles/` as
  "rubric overrides", contradicting the additive model the same page explains
  correctly two sections later. And its checklist predated most of what CI now
  enforces.
  It gains a **What CI already enforces** table, because several conventions
  are tests rather than advice now, and a failure that names a rule you have
  never read is a bad first contribution: entrypoint invariants (a missing
  `configure_endpoint` silently sends traffic to the public API), the
  stdlib-only Python suite, SHA-only pins, doc anchors, credential-shaped
  fixtures, and the fact that a new bats file must be listed in **both**
  `tests/run.sh` and `.github/workflows/ci.yml` or it simply does not run.
  New guidance that a **second entrypoint on an existing engine is usually the
  better trade than a second workflow** — the review and the audit share a
  rubric, a severity ladder and a findings format precisely because the audit
  was not built as its own workflow. A new convention that a workflow reading
  PR content should skip forked pull requests rather than fail on them, with a
  pointer at the shared resolver that already does it. And a note that a rubric
  change needs `tests/corpus/run.sh`, since `tests/run.sh` tests the envelope
  and would pass a rubric that reported nothing.

- **The two security-review examples in `docs/` now match the ones in
  `examples/`**, and the test that pins them scans by what a snippet *uses*
  rather than where it lives.
  `docs/github-action.md`'s manual-dispatch workflow and
  `docs/private-endpoints.md`'s Bedrock workflow were both missing
  `concurrency` and `timeout-minutes`, and the Bedrock one was missing
  `persist-credentials: false`. The previous test scanned `examples/*.yml`
  plus one hardcoded quickstart block, so a complete workflow living in a
  fenced block anywhere else was invisible to it — and a doc snippet is
  copy-pasted exactly like a file is.
  `test_example_workflows.py` now finds every fenced YAML block that invokes
  the action and declares `jobs:`, across `docs/` and the README, and asserts
  that both kinds of source are represented so neither class can silently drop
  out of the scan. Coverage went from 6 sources to 8. The classifier and the
  instructions-sync examples stay out of scope: different cost and cadence,
  and sweeping them in would assert something nobody has reasoned about.
- **Copilot's native review is now framed as the alternative to the Action, not
  a layer on top of it.** Four documents said to "adopt the action first" and
  add Copilot as a complementary second opinion. That was wrong in a way worth
  naming: the "run it alongside, not instead of" argument is correct for SAST,
  dependency and secret scanning — different detection method, so they compose
  — and it got carried over to a comparison where it does not hold. Copilot
  native and the Action apply the **same rubric by the same method**, so running
  both mostly means the same finding reported twice on the same line, and two
  metered bills.
  It also gave bad advice to the teams most likely to need this. "Adopt the
  action first" is useless to a program that has Copilot procured and
  authorized while a frontier-model key is months of paperwork away, or out of
  reach entirely — and that is a procurement and accreditation question, not a
  temporary state. The docs now present a choice decided by what a program can
  obtain, with Copilot-with-instructions as a real option rather than a
  consolation prize, and say plainly what going Copilot-only costs: the gate,
  control of the model and data path, machine-readable output, and profile
  composition.
  The `docs/security-compliance-review.md` entry keeps the scanner distinction
  explicit, since that is the framing that does still apply and the one this
  was confused with.

- **The quickstart and every security-review example now carry `concurrency`,
  `timeout-minutes` and `persist-credentials: false`**, pinned by
  `tests/python/test_example_workflows.py`.
  All five examples were missing all three, which is how this goes: each is one
  line, nobody notices an absence, and the cost lands on people who are not in
  this repository. Without a concurrency group, three pushes to a PR run three
  concurrent reviews — each a metered model call, each posting overlapping
  comments. Without `timeout-minutes`, a hung CLI holds a runner for GitHub's
  default six hours against a job that takes about eight minutes. And
  `persist-credentials: false` is the token-isolation posture `docs/security.md`,
  `docs/architecture.md`, `docs/github-action.md` and two other examples all
  recommend — the quickstart was the one place not modelling the repository's
  own advice, which is backwards for the snippet people actually paste.
  The quickstart also now states what the defaults give you (advisory, silent
  on a clean PR, 50 inline comments, no adjudication pass) instead of leaving a
  reader to assemble that from the input table, and carries a short caveat that
  GitHub withholds secrets from forked pull requests so the job fails rather
  than skipping — with a pointer away from `pull_request_target`, which would
  run a privileged token against untrusted PR content.

- **Doc coherence pass after the adjudication default moved.** Four documents
  sold the Action over Copilot's native review partly on adjudication —
  "it adjudicates its own findings to cut false positives", "it filters its own
  false positives", "Copilot's native review … does not adjudicate its own
  findings", and a comparison-table row naming `self` as the default. One
  default change invalidated all of them, and #45 only caught the copy in
  `docs/security-compliance-review.md`.
  A selling point repeated in four places is a selling point that goes stale in
  four places. They now claim what the Action actually does better: anchoring
  findings on the lines that caused them with suggested fixes, and being
  tunable per program — profile overlays, a severity gate, an inline-comment
  limit, and adjudication as an opt-in rather than a default.
  The gating example silently set `adjudication: independent` under a
  "stronger second opinion" comment written when adjudication was on by
  default. It now says what is known: gating is the case where paying for a
  second opinion may still be worth it, `independent` roughly doubles cost, and
  it has not been measured — so opt in deliberately and check it against your
  own code. An example that quietly contradicts the default teaches the default
  is wrong.
  Also fixed a broken cross-doc anchor: `security.md#the-llm-credential-bedrock--vertex`
  lost its target when Azure was added to that heading.

- **Adjudication now defaults to `off`.** It was `self`.
  A current model verifies its own work without being told to, and telling it
  to costs tokens and causes over-verification. Anthropic's Opus 5 migration
  guidance names both modes almost verbatim — "include a final verification
  step", "use a subagent to verify" — and says to delete that scaffolding:
  "removing them reduces over-verification with no capability regression." It
  also notes this *inverts* a standard prompting best practice, so a rubric
  that applies self-checking uniformly needs the carve-out rather than a global
  rule.
  Measured against `tests/corpus` before switching, one run each. **`self`
  suppressed nothing.** The negative control produced the same seven findings
  in both modes, same severities, near-identical wording. Across all eight
  cases its only effect anywhere was one severity downgrade — a correct one, on
  a fixture that turned out to be wrong (see the corpus fixture entry) — while
  producing two *more* unexpected findings overall and taking longer. It was
  paying nothing for what it cost.
  **The modes are kept, not removed.** The guidance is Anthropic-model-specific,
  and this engine also runs `codex` and `copilot`, on models a program may have
  pinned for ATO reasons. A default is the right lever; deletion is not. Turn
  `self` or `independent` back on there, or wherever the corpus shows a benefit
  on your own code.
  Two fallbacks that still said `self` moved with it. An unrecognized
  `AI_ADJUDICATION` value now resolves to `off` **and warns**, where it used to
  resolve silently to `self` — harmless when `self` was the default, not now,
  since a typo would buy the behaviour the default declines and bill for it on
  every review. The prompt builders' `AI_REVIEW_ADJUDICATION_MODE:-self` is
  unreachable today but is exactly how a later refactor would restore the old
  behaviour invisibly, so it is now `off` and pinned by a test.
  One doc claim went with it: `docs/security-compliance-review.md` sold the
  Action over Copilot's native review partly on "it adjudicates its own
  findings to cut false positives". That is no longer true by default, and the
  measurement says it was not true in practice either.

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

- **`ai-security-compliance-review` shipped without its executable bit**, while
  its two sibling entrypoints had theirs. Invisible in CI because both actions
  invoke it as `bash <file>`; it breaks for anyone who installs the tree and
  runs it directly, which is exactly what the local audit path and any future
  packaging do. `tests/run.sh` was missing its bit too. The release gate now
  checks this, and so does the test suite on every PR.

- **The AI CLI was installed unpinned.** `cli-version` defaulted to `latest`,
  so a consumer SHA-pinned the action, CI enforced SHA-only pins across every
  doc and example, `docs/security.md` argued at length about mutable refs — and
  then the job `npm install -g`'d an **agentic** CLI at a floating version. That
  CLI is the component that reads the untrusted diff with shell and file-read
  tools, which made it simultaneously the least-pinned and highest-privilege
  thing in the run. Pinning the action was never the whole supply chain.
  `cli-version` now defaults to a per-tool version pinned in
  `workflows/_shared/lib/ci.sh` (`_AI_CLI_VER_*`), covering both the review and
  the classifier, which shared the default. Jenkins is unaffected: its agents
  need the CLI pre-installed, so the Actions path is the only one that installs
  anything at runtime.
  **Exact versions, not ranges**, and for a different reason than the action
  rule. npm forbids republishing a version, so `@scope/pkg@1.2.3` is immutable
  in the way a git tag is not; `^1.2.3` resolves at install time, which is
  `latest` with extra steps.
  `cli-version: latest` still works for anyone who wants it and now logs a
  warning saying what it does — a choice rather than a default.
  `tests/python/test_cli_pin_hygiene.py` and four bats cases hold it: each pin
  is an exact `x.y.z`, the installer contains no floating literal, and neither
  action's input defaults to `latest`. Verified against three regressions — a
  pin reverted to `latest`, a pin turned into a caret range, and the input
  default flipped back.
  One limit stated in `docs/security.md` rather than papered over: these pins
  are strings in bash, invisible to Dependabot, so nothing bumps them and the
  test catches a pin going *floating* but not going *stale*. A pin that is
  never reviewed is a CLI that never gets a security fix.

- **The framework-neutral floor instructed CMS ARS citations.**
  `skills/base/pr-review.md` said *"For compliance findings, always include the
  NIST 800-53 Rev 5 control ID and the CMS ARS 5.1 control ID"*, and the
  example JSON cited ARS too. So `--profile base` — a program with no CMS
  relationship — was told to cite CMS controls. The layering tests could not
  see it: they check that a profile's file is appended, not what the floor
  already says.
  Versioning made it sharper, since a floor naming one revision contradicts
  whichever profile is actually loaded. The floor now says to cite only from a
  framework a loaded profile names, and to describe the control objective in
  plain language when none does. The capability moved rather than disappearing:
  `skills/profiles/cms-ars-5.1/iac-compliance.md` has carried the citation
  instruction all along.
  `tests/python/test_floor_is_framework_neutral.py` holds it, scoped to
  framework **revisions** rather than framework names — the floor legitimately
  describes what PHI is and why HIPAA cares, and banning the word would gut
  real detection content. A paragraph that names a profile in backticks is
  exempt, because pointing at where a framework lives is not citing it; the
  profile names come from disk so the exemption cannot drift. A complementary
  test fails if the capability is deleted rather than moved.
  Two stale claims went with it: `action.yml:6` and
  `docs/security-compliance-review.md:7` said "(CMS ARS by default)" when the
  default is `base`, and the two Jenkins Jelly placeholders offered `baseline`,
  which the engine rejects outright — it requires `base` or `none` first.

- **The audit docs still described adjudication as on.** It has defaulted to
  `off` since the default moved, and the audit inherits that from the shared
  runtime — but three places had not caught up, all of them the kind a reader
  trusts.
  `docs/codebase-audit.md`'s worked `--dry-run` plan printed
  `Adjudication:   self`, demonstrating a run that cannot happen in the one
  place someone looks to learn what a run costs. (It was also missing the
  `Tool:` and `Provider:` rows the real output has had since the provider fix.)
  The same page and the audit's `--help` both listed `--no-adjudicate` as
  "cheaper, noisier" — telling a reader to spend effort turning off something
  already off. The flag is still useful and stays: it forces off when
  `AI_ADJUDICATION` is set in the environment, which is what `--help` now says.
  Removing the stale line left the page with no way to learn adjudication can
  be turned **on** — its only remaining mention was `Adjudication: off` in the
  dry-run plan, unexplained. There is now a short section: `AI_ADJUDICATION=self`
  folds a re-read into the calls already being made (no extra call, more output
  tokens), `independent` adds exactly **one** call regardless of batch count,
  and `--no-adjudicate` forces off when the variable is set in the environment.
  It is a **top-level `## Adjudication` section**, not a subsection of "The
  four things you'll actually use" where it first landed — adjudication is not
  one of the four, and a fifth thing hidden under a heading that promises four
  is a thing readers skim past. It opens by saying what adjudication *is*
  (findings are confirmed, downgraded or dropped; it can only remove or soften,
  never add — verified against `finding-adjudication.md`), because every prior
  mention on the page assumed the reader already knew, and links to
  `github-action.md#adjudication-and-fan-out` for the full treatment. That page
  had the explanation all along and `codebase-audit.md` linked to it zero times.
  It also says when it is worth it *for an audit*, which the `off` default does
  not settle: that default was measured on diffs, where `self` suppressed
  nothing, and an audit sends whole files rather than a change — more surface
  for a speculative finding, and often a report someone else reads.
  Two tests guard the docs. One pins the documented plan's adjudication value
  to the engine's own default, so the example has to move whenever the default
  does; the other fails any doc or entrypoint that sells `--no-adjudicate` as a
  cost saving. Four bats cases cover the behaviour itself, which the audit
  suite had none of: the default, both modes' cost shapes, and the flag's
  override. This is the fourth time a default change has left a doc example
  behind, and a worked example is a claim about behaviour.

- **`--doctor` was unusable for the Copilot CLI, in two ways.**
  It printed `npm install -g @anthropic-ai/claude-code` as the install hint for
  **any** missing CLI, so a copilot user was told to install Claude Code. The
  engine already knew the right package for each tool
  (`core.sh` `require_cli`); doctor just used a hardcoded fallback.
  Worse, it reported `endpoint ok` for copilot with **no GitHub token at all**.
  Copilot's model auth *is* a GitHub token and `endpoints.sh` never hard-fails
  on a missing one — it warns that the CLI "must already be authenticated on
  this host" — but doctor discarded everything `configure_endpoint` printed
  whenever it exited 0. For the one tool whose credential check is advisory,
  the advice was thrown away, and "ok" became a claim doctor could not back.
  Warnings emitted on the success path are now echoed under the row that
  earned them, indented like the failure path, with the routine
  `Endpoint: tool=...` audit line filtered out so only real warnings appear.
- **`docs/codebase-audit.md` said nothing about how to use Copilot.** The word
  appeared once, in a comment, as `# or codex, or copilot`. There is now a
  section covering what actually differs: copilot takes no API key (its auth is
  `GITHUB_TOKEN` / `GH_TOKEN` / `COPILOT_GITHUB_TOKEN`, or an existing host
  login); **`AI_REVIEW_CLI_NATIVE_AUTH=1` does nothing for it**, which matters
  because the page introduces that flag ten lines earlier and a reader would
  reasonably try it; a missing token warns rather than fails, so the run dies
  later inside the CLI; it runs on GitHub's models, so "public endpoint" means
  something different here; and the BYOK settings — documented in
  `private-endpoints.md` only as Action inputs — are plain environment
  variables locally.

- **A pull request from a fork is now skipped with a notice, not failed.**
  It used to die in the engine with `requires ANTHROPIC_API_KEY`, putting a red
  check on every external contribution — one the contributor could not act on
  and the maintainer had to explain.
  There is no configuration in which it could have worked. GitHub withholds
  secrets from a fork run, so there is no model credential, **and** issues a
  read-only `GITHUB_TOKEN`, so there is nothing to post with; `id-token: write`
  is unavailable too, so federating into Bedrock or Vertex does not rescue it.
  Two independent blockers, neither reachable from the `permissions:` block.
  The skip is scoped to the `pull_request` event on purpose. A maintainer
  running the workflow by hand against a fork PR (`workflow_dispatch` with
  `pr-number` / `base-ref`) executes in the base repository with secrets and a
  write token, and must not be skipped — that is the escape hatch the notice
  itself recommends, and guarding on "is a fork" alone would have broken it.
  A missing or empty fork signal **reviews** rather than skips. That direction
  is the one that matters: defaulting the other way would silently skip every
  pull request, leaving a workflow that is green, posts nothing, and looks
  installed.
  `docs/github-action.md` gains a **Forked pull requests** section covering why
  it cannot work, how to review one by hand, and why `pull_request_target` is
  the wrong workaround here specifically — it would point an agentic CLI with
  shell and file-read tools at contributor code with a privileged token in the
  same environment, which is the threat `docs/security.md` is built around.

- **`pr-number` never worked off a `pull_request` event**, on either action.
  It is documented as an override — "Defaults to the pull_request event's
  number" — which reads as an invitation to run on `workflow_dispatch` and name
  the PR yourself. The base ref had no matching input, so
  `ci::resolve_pr_context` stopped with `Could not determine the PR base ref`,
  and there was no knob to fix it: the composite sets `EVENT_BASE_REF` in its
  own step `env:`, so a value a caller exports in an earlier step is
  overwritten with the empty string. The only reachable path was the one nobody
  needed an override for.
  There is now a **`base-ref`** input on both actions, preferred over the event
  payload exactly as `pr-number` is, which makes manual and scheduled runs
  against a named PR work: pass both inputs and check out
  `refs/pull/<n>/head`. The error message names the input that fixes it and the
  PR it was asked about, instead of pointing at `actions/checkout`, which
  populates nothing here. `docs/github-action.md` gains a worked
  `workflow_dispatch` example under **Re-running a review**, next to the
  dedup behaviour a second pass runs into.
  The two halves are asserted to stay a pair by
  `tests/python/test_action_pr_context.py` — declared input, wired into the
  resolving step, and named in `pr-number`'s own description. Half-wired inputs
  are invisible to every other suite: the YAML is valid, the bash is covered,
  and the one path anyone had exercised is fine.
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
