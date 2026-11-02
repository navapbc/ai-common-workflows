# ADR 0001: Distribute the codebase audit via Homebrew

- **Status:** Proposed — decided in principle 2026-09-30, not implemented.
- **Scope:** The `ai-security-compliance-audit` entrypoint only. The PR review
  and the test classifier are unaffected.

## Context

The audit is the one entrypoint in this repo that is **deliberately
local-only**. It has no composite action and no Jenkins step, and it warns when
`CI` is set. It exists to be run by a person, against a repo they are looking
at, on their own machine.

Its entire install story is a `git clone` of this repository plus a shell alias
— see the local-install section of [codebase-audit.md](../codebase-audit.md).
That asks someone who wants to audit *their* repo to first clone and
hand-maintain *ours*, then keep it current by remembering to `git pull`. There
is no upgrade path, no way to know what you are running, and no way to check
that what you cloned is what we published.

Two related gaps make this worse than an inconvenience:

- **The engine has no notion of its own version.** There is no `VERSION` file,
  no constant, no `--version` flag anywhere in `engines/`. An audit bundle
  attached to a ticket records the repo, date, run number, scope, profile, tool,
  provider and adjudication setting — but not what produced it. Two bundles a
  month apart are not comparable.
- **Nothing this repo publishes is verifiable except the Jenkins plugin.** The
  `.hpi` carries a Sigstore attestation and a documented
  `gh attestation verify` step ([security.md](../security.md)). A cloned
  working tree carries nothing.

## Decision

Distribute the audit as:

```sh
brew install navapbc/tap/repo-audit
```

from a tarball built, checksummed and attested by the release workflow.

| | |
|---|---|
| Tap | `navapbc/homebrew-tap` — new, shared across future Nava CLIs |
| Command | `repo-audit` |
| Scope | Audit only. The review entrypoint ships inside `libexec` but is not exposed in `bin`. |
| Artifact | Release tarball + `.sha256` sidecar + Sigstore build provenance |

Two architectural constraints belong in the record rather than only in code,
because both are invisible at the point where someone would break them.

**The formula must use a wrapper script, not a symlink.** `ENGINE_HOME` is
derived from `${BASH_SOURCE[0]}`, and the engine deliberately contains no
`readlink -f` or `realpath` anywhere — path canonicalisation is `cd … && pwd`
throughout. Executing a symlink leaves `BASH_SOURCE[0]` as the symlink's own
path, so `bin.install_symlink` resolves `ENGINE_HOME` to the Homebrew prefix and
the tool cannot find `_common`. A wrapper that `exec`s the real path resolves
correctly. Relatedly, `_common` must stay a sibling of
`security-compliance-review` inside whatever tree is installed.

**The tap pulls; nothing pushes to it.** The tap polls this repository's
releases on a schedule and opens a pull request against itself. No token with
tap write access is stored here, and no token with access to this repo is stored
there — each workflow writes only its own repository, with the built-in
`GITHUB_TOKEN`. This is the property that makes the tap lockable at all, and it
is what the `navapbc/homebrew-rebar` autobump workflow means by "no stored
cross-repo token".

## Rejected alternatives

**GitHub's auto-generated source tarball** (`/archive/refs/tags/…`). Requires no
release-workflow change at all, which is its entire appeal. Rejected because
GitHub does not guarantee those tarballs are byte-stable: a change to how they
are generated has invalidated formula checksums across the ecosystem before, and
a formula whose `sha256` stops matching is a broken install for everyone.
Build-provenance attestation is also not possible on that channel, and the
tarball would carry `tests/` and `jenkins-plugin/` unless `.gitattributes`
grew `export-ignore` rules to trim them.

**Publish to PyPI, then build the formula from the sdist.** This would reuse
`navapbc/homebrew-rebar`'s autobump workflow almost verbatim, which is a real
saving. Rejected because the audit is bash-first with a few stdlib Python
helpers; there is no `pyproject.toml`, no package, and no Python entry point.
Wrapping it as a Python distribution to make it installable is a repackaging of
the tool, not a packaging of it, and it would put a second definition of the
engine's layout somewhere the engine does not look.

**A per-tool tap** (`navapbc/homebrew-ai-common-workflows`). This matches the
`navapbc/homebrew-rebar` precedent, and it keeps the blast radius of a
compromised tap to a single formula. Rejected in favour of one shared org tap,
on the judgement that a single well-controlled tap is easier to keep locked down
than several that each need the same settings applied. The trade is explicit: a
shared tap needs correspondingly stricter controls, because anyone who can write
to it can ship any formula in it.

**Symlinking the entrypoint into `bin`.** The simpler formula, and the one
someone will reach for when "simplifying" later. It breaks `ENGINE_HOME`, per
the constraint above.

## Consequences

**The release workflow starts producing an artifact.** Its header currently
states that nothing is built or uploaded, because the Action is source that
GitHub fetches at `uses:` time and so the tag's commit *is* the artifact. That
remains true **of the Action**. It stops being true of the repository, and
[releasing.md](../releasing.md) has to say so.

**The engine gains a version identity.** A `VERSION` generated at release time
and absent from a git checkout, which therefore reports a development build; a
`--version` flag; and the version recorded in `--doctor` output and in audit
bundle metadata. This is worth doing whether or not the Homebrew work proceeds —
an audit report that cannot name the engine that produced it is not evidence of
much.

**Pinning guidance needs one more case.** This repo's rule is that a commit SHA
is the only acceptable reference, because a git tag can be deleted and
re-created against different content. A Homebrew formula's URL contains a
version, but the formula also carries a `sha256` of the downloaded bytes, and
Homebrew refuses the install when it does not match. The content hash is the
immutable reference; the version in the URL is not doing that work. This is the
same argument [security.md](../security.md) already makes for npm, where a
published version is immutable because republishing one is forbidden.

**A tap is a remote code execution channel.** `brew install` evaluates the
formula's Ruby on the installing machine. That makes the tap a more sensitive
repository than this one in at least one respect, and it needs a stricter
posture than `navapbc/homebrew-rebar`, which today has no branch protection, no
rulesets and no security settings enabled at all.

**Tap-only changes will never cut a release here.** The release workflow refuses
a tag whose `workflows/` and `engines/` diff against the previous stable release
is empty. That is correct and has a useful side effect: every release this repo
produces is a real formula bump, so the tap never proposes a no-op.

**macOS becomes a supported platform in practice, and is untested today.** Every
CI job runs on `ubuntu-latest`. The bash 3.2 and BSD-userland compatibility this
engine claims is asserted in documentation and held by convention, never
exercised. The audit calls bare `mktemp -d` with no template in four places, and
BSD `mktemp` may require one — if it does, the entire bundle-writing path fails
on the platform Homebrew users are on. **Settling this is a precondition, not a
task.**

---

## Implementation sketch

> Indicative, and expected to drift. The record above is the decision; this
> section is a starting point for whoever picks the work up, not a commitment to
> a particular shape. Check the code before trusting any detail here.

**In this repository, roughly four changes:**

1. **Version identity.** A `VERSION` file generated into the release tarball and
   never committed, read beside the existing `ENGINE_HOME` resolution; a
   `--version` case in the audit's argument loop; the value surfaced in
   `--doctor` and in the bundle metadata that becomes `_INDEX.md`.
2. **The attested tarball**, as a new step in the release workflow modelled on
   the Jenkins plugin workflow, which already does exactly this for the `.hpi`:
   build, `sha256sum` sidecar, `actions/attest-build-provenance`, attach to the
   release. It needs `id-token: write` and `attestations: write` alongside
   `contents: write`. Ship `engines/_common/` and
   `engines/security-compliance-review/` whole rather than trimming to the
   audit's exact dependency set — the tarball then has the same layout as the
   repo, and there is no "we trimmed the wrong file" failure mode.
3. **Docs**: Homebrew becomes the primary install in
   [codebase-audit.md](../codebase-audit.md) with the clone retained for
   contributors; [security.md](../security.md) widens its verification section
   from the `.hpi` to cover the tarball, and gains the content-hash argument
   above; [releasing.md](../releasing.md) amends the "nothing is built" line.
4. **A test pinning the install shape** — invoke the entrypoint through a
   wrapper from an unrelated working directory and assert it works, and assert
   the symlink form fails. The wrapper-not-symlink constraint is a coupling
   between two repositories and will otherwise be discovered by breaking it.

**In the tap, four files:** the formula; an autobump workflow that polls this
repo's releases and opens a PR (running the formula checks itself first, since a
`GITHUB_TOKEN`-authored PR triggers no workflows); a CI workflow running
`brew style`, `brew audit --strict --online`, `brew install --build-from-source`
and `brew test` on **macOS and Linux**; and a README.

**Lockdown**, beyond the pull-not-push property already in the decision: a
ruleset on `main` requiring a pull request and a review, forbidding force-push
and deletion, applying to admins; forks disabled, consistent with not accepting
external contributions; secret scanning, push protection and Dependabot alerts,
matching what this repo now has; `CODEOWNERS` on the formula directory; the
default workflow token read-only with permissions granted per job.

**Two traps worth carrying forward**, both of which cost real time to
rediscover:

- **`--doctor` cannot be the formula's smoke test.** It exits non-zero on any
  machine with no AI CLI selected, which is every fresh CI runner. Use
  `--version` and `--help`.
- **The SHA-pinning prose guard applies to this directory.** Certain phrasings
  that offer a mutable reference as an acceptable pin are blocked by test in
  every scanned document, deliberately. Write the content-hash argument on its
  own terms rather than as an exception to the rule.
