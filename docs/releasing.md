# Releasing

A release is a **GitHub Release pointing at one immutable commit**, plus notes
telling a consumer the SHA to pin. Nothing is built or uploaded: the action is
source that GitHub fetches at `uses:` time, so the tag's commit *is* the
artifact.

## Is there anything to release?

A release exists so a consumer can **find a SHA**. If the code behind the new
SHA is identical to the last release's, the version number is the only thing
that changed, and an upgrade that changes nothing is how people learn to stop
reading upgrades.

```bash
git diff --name-only "$(git describe --abbrev=0 --match 'v[0-9]*.[0-9]*.[0-9]*')"..main -- workflows engines
```

Empty output means there is nothing to release. Repo hygiene, docs, tests and
the Jenkins plugin all live outside those two directories on purpose — they are real work, and none of them changes what a
consumer's job runs.

Don't take this on trust: the workflow **refuses** such a tag, before anything
is published. See *What the workflow checks* below.

## Cutting one

```bash
git checkout main && git pull --ff-only
git tag -s v1.0.0 -m "v1.0.0"   # or -a, if you have no GPG key configured
git push origin v1.0.0
```

`.github/workflows/release.yml` does the rest. Pre-releases work too —
`v1.2.0-rc.1` is marked as a pre-release automatically.

`-s` signs the tag and is the better habit ([docs/security.md](security.md)
explains why the tag's own provenance is worth having), but it fails outright
with `gpg: No secret key` if you have no key for your committer identity. The
workflow does not inspect the tag object, so `-a` — or even a bare `git tag` —
releases fine; the signature is provenance for a human reader, not a gate.

### Don't publish from the GitHub UI

Releases → "Draft a new release" creates the tag *and* the release in one
action. The tag push still fires this workflow, which then fails at
`gh release create` because the release already exists — leaving the release
published with GitHub's auto-generated changelog instead of the SHA-pin notes,
and a red ✗ beside it. Push the tag from a terminal and let the workflow
publish.

The Jenkins plugin releases on its own `jenkins-plugin-v*` tag namespace, which
this workflow deliberately does not match.

## What the workflow checks before publishing

- **The tag is an ancestor of `main`.** A tag can be pushed from anywhere;
  releasing a commit that never reached `main` would ship code no CI run saw.
- **Something under `workflows/` or `engines/` changed** since the most recent
  stable release reachable from this tag. Docs are shipped too, but a doc fix
  does not require anyone to move a pin — they can read docs on `main`.
  Pre-releases are never used as the baseline, so promoting `v1.2.0-rc.1` to
  `v1.2.0` is not refused for having an identical surface, which it does by
  design.
- **The consumer-facing surface exists** — every `workflows/*/action.yml`, the
  shared CI library, the shared runtime, and every engine entrypoint.
- **Every entrypoint is executable.** The actions invoke them as `bash <file>`,
  so a missing exec bit is invisible in CI and breaks for anyone who installs
  the tree and runs it directly.

The surface list is **globs, not names**. The previous attempt at this hardcoded
`harness/ai-pr-review` and kept it after the file was renamed, so the first
release would have failed on the check rather than on a real problem — and
nothing noticed, because a release workflow only runs when you release.
`tests/python/test_release_surface.py` now runs those same checks on every PR.

## There is no moving `vX` tag

Deliberately. An earlier draft force-moved `v1` on each release and offered
`@v1` as a pin for pilot repositories. That is the mutable pointer
[security.md](security.md) forbids — a tag can be deleted and re-created against
different content, and nothing in a consumer's workflow would notice. Shipping
one as a *supported* pin would have handed people a blessed way around the rule
the rest of the repo enforces in CI.

So a release exists to help someone **find** a SHA, not to avoid pinning one.
The generated notes carry the exact line to paste:

```yaml
      - uses: navapbc/ai-common-workflows/workflows/security-compliance-review@<40-char-sha> # v1.0.0
```

The trailing comment records which release the SHA is, so an upgrade stays a
reviewable one-line diff.

## Versioning

Semantic versioning over the **consumer-facing surface**: action inputs and
their defaults, the engine's environment variables, the findings JSON shape, and
the exit codes.

A default changing behaviour is a breaking change even when no input is
renamed — `adjudication` moving to `off` and `max-comments` moving to `50`
both changed what every consumer gets without them editing anything.

### While on 0.x

This project starts at **`v0.1.0`**. Semver reserves major version zero for
exactly this: the surface is not yet stable and may change. Numbering map:

| Change | Bump | Example |
|---|---|---|
| Breaking — an input renamed or removed, a default that changes behaviour, a findings-JSON or exit-code change | **MINOR** | `0.1.0` → `0.2.0` |
| Everything else — new optional input, better rubric, bug fix, docs | **PATCH** | `0.1.0` → `0.1.1` |

That is the standard `0.x` convention, and the alternative is worse: under
`1.x` the rule above would make every sensible default adjustment a major bump,
and a number that increments on ordinary tuning stops telling anyone anything.
`adjudication` moving to `off` is precisely the kind of change that should be
cheap to make while nobody depends on it.

**A breaking change in `0.x` is still breaking.** The bump is smaller; the
CHANGELOG entry is not. Say what a consumer has to do.

### Reaching 1.0.0

Cut `1.0.0` when there is adoption worth protecting — a program depending on
these defaults in a pipeline someone is accountable for. At that point the
surface freezes under the normal rules and a breaking change costs a major
version.

Things worth having settled before then, none of which block a `0.x` release:
the detection corpus large enough to catch a rubric regression; the two front
ends agreeing on the gate verdict (the Jenkins plugin currently applies its own
rule rather than calling `gate_verdict.py`); and more than one real production
run behind the defaults.

The rubric is not versioned by this scheme. It changes continuously and its
effect is on judgment rather than interface; `tests/corpus/` is what measures
that, and it is not part of the release gate.
