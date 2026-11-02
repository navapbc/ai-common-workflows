"""The release gate's checks hold against the tree it will gate.

The previous release automation verified a hardcoded list of consumer-facing
files, and that list named `engines/security-compliance-review/harness/ai-pr-review`
long after the file was renamed. So the workflow would have failed on the very
first tag — on a check that was itself the stale thing. Nothing caught it,
because a release workflow only runs when you release, and nobody had.

Two guards, both cheap, both running on every PR rather than at tag time:

1. The entrypoints a release ships are **executable**. They are invoked as
   `bash <file>` by the actions, so a missing exec bit is invisible in CI and
   breaks the moment someone installs the tree and runs it directly. That was
   real: `ai-security-compliance-review` shipped non-executable while its two
   siblings were fine.
2. The release workflow's surface check is **derived, not listed** — no
   hardcoded path that can rot. A glob goes stale only if the layout changes,
   and then it fails loudly, because an unmatched glob stays literal and trips
   the existence test.
"""

import pathlib
import re

import pytest

ROOT = pathlib.Path(__file__).resolve().parents[2]
RELEASE = ROOT / ".github" / "workflows" / "release.yml"
ENTRYPOINTS = sorted(ROOT.glob("engines/*/harness/ai-*"))


def test_the_release_workflow_exists():
    # Everything below is about this file; its absence must not pass quietly.
    assert RELEASE.is_file(), f"{RELEASE.relative_to(ROOT)} is missing"
    assert ENTRYPOINTS, "no engine entrypoints found"


@pytest.mark.parametrize("path", ENTRYPOINTS, ids=lambda p: p.name)
def test_shipped_entrypoints_are_executable(path):
    import os

    assert os.access(path, os.X_OK), (
        f"{path.relative_to(ROOT)} is not executable. The actions run it as "
        "`bash <file>` so CI cannot see this, but anyone who installs the tree "
        "and runs it directly gets permission denied."
    )


def test_the_surface_check_is_derived_not_hardcoded():
    """A named path in the gate is a path that can rot.

    The previous attempt failed exactly this way. Every path the check tests
    must be either a glob or a file that exists right now — a literal naming
    something absent is the bug, not a caught error.
    """
    body = RELEASE.read_text()
    block = re.search(r"for path in \\\n(.*?);? *do", body, re.S)
    assert block, "could not find the surface loop in release.yml"

    paths = [p.strip().rstrip("\\").strip() for p in block.group(1).split()]
    paths = [p for p in paths if p and p != "\\"]
    assert paths, "surface loop lists nothing"

    literals_missing = [
        p for p in paths if "*" not in p and not (ROOT / p).exists()
    ]
    assert not literals_missing, (
        f"release.yml checks for path(s) that do not exist: {literals_missing}. "
        "That is how the previous release workflow broke — it named "
        "harness/ai-pr-review after the rename, so every tag failed on the "
        "check rather than on a real problem."
    )
    assert any("*" in p for p in paths), (
        "the surface check hardcodes every path; use globs so it cannot name a "
        "file that no longer exists"
    )


def test_the_release_does_not_publish_a_moving_alias():
    """No `vX` alias.

    An earlier draft force-moved `v1` on every release and offered `@v1` as a
    pin — the mutable pointer docs/security.md forbids, shipped as a supported
    way around the rule the rest of the repo enforces.
    """
    body = RELEASE.read_text()
    bad = [
        line.strip()
        for line in body.splitlines()
        if re.search(r"git (tag|push).*-f", line) and not line.strip().startswith("#")
    ]
    assert not bad, f"release.yml force-moves a tag: {bad}"


def test_the_release_notes_tell_consumers_to_pin_a_sha():
    body = RELEASE.read_text()
    assert "GITHUB_SHA" in body, "release notes must carry the SHA to pin"
    assert re.search(r"mutable pointer", body), (
        "release notes should say why a SHA and not the tag — the release is "
        "how a consumer finds the SHA, and the notes are where they look"
    )
