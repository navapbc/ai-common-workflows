# Releasing

A release is a **GitHub Release pointing at one immutable commit**, plus notes
telling a consumer the SHA to pin. Nothing is built or uploaded: the action is
source that GitHub fetches at `uses:` time, so the tag's commit *is* the
artifact.

## Cutting one

```bash
git checkout main && git pull --ff-only
git tag -s v1.0.0 -m "v1.0.0"
git push origin v1.0.0
```

`.github/workflows/release.yml` does the rest. Pre-releases work too —
`v1.2.0-rc.1` is marked as a pre-release automatically.

The Jenkins plugin releases on its own `jenkins-plugin-v*` tag namespace, which
this workflow deliberately does not match.

## What the workflow checks before publishing

- **The tag is an ancestor of `main`.** A tag can be pushed from anywhere;
  releasing a commit that never reached `main` would ship code no CI run saw.
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

The rubric is not versioned by this scheme. It changes continuously and its
effect is on judgment rather than interface; `tests/corpus/` is what measures
that, and it is not part of the release gate.
