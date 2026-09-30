"""Profile names for versioned standards carry their revision, everywhere.

`docs/profiles.md` § Versioning a profile: a profile implementing a versioned
standard carries the revision in its directory name — `cms-ars-5.1`, not
`cms-ars` — so revisions coexist and a run can say which one it judged against.

A rule stated in one document and repeated as examples in nine others drifts.
It already did: renaming `cms-ars` left `pci-dss` sitting *on the same line* as
`cms-ars-5.1` in three places, contradicting the rule in the act of stating it.

So the rule is enforced rather than remembered:

1. A bundled profile directory implementing a versioned standard is versioned.
2. An illustrative profile name in any doc, comment or config is too — an
   example is the copy people actually paste.
3. Rubric FILENAMES stay unversioned. They are the layering join key
   (`ai_review::rubric_block` matches a profile's file to the floor's by
   identical filename), so a versioned filename would break composition.
"""

import pathlib
import re

import pytest

ROOT = pathlib.Path(__file__).resolve().parents[2]

# Standards that publish numbered revisions. A profile naming one of these must
# say which. Frameworks without revisions (OWASP Top 10 by year, CIS, HIPAA)
# are deliberately absent — there is no edition to pin.
VERSIONED_STANDARDS = ("cms-ars", "pci-dss", "nist-800-53", "fedramp-rev")

# `<standard>` optionally followed by `-<major>.<minor>`.
def _unversioned(standard):
    return re.compile(rf"(?<![a-z0-9.-]){re.escape(standard)}(?!-?\d)(?![a-z0-9])")


# Where a reader copies a profile name from.
SCANNED = (
    sorted(ROOT.glob("docs/*.md"))
    + sorted(ROOT.glob("engines/*/README.md"))
    + sorted(ROOT.glob("engines/*/harness/ai-*"))
    + sorted(ROOT.glob("workflows/*/action.yml"))
    + sorted(ROOT.glob("examples/workflows/*.yml"))
    + sorted(ROOT.glob("copilot-instructions/README.md"))
    + [ROOT / "README.md", ROOT / "engines/_common/harness/core.sh"]
)

# The rule's own statement needs the bad form to contrast against, and the
# changelog records history that must not be rewritten.
EXEMPT_FILES = {"profiles.md"}


def _profile_dirs():
    return sorted(
        d for d in ROOT.glob("engines/*/skills/profiles/*") if d.is_dir()
    )


def test_there_is_something_to_check():
    # A glob matching nothing would make every assertion below vacuous.
    assert _profile_dirs(), "no bundled profile directories found"
    assert len(SCANNED) >= 12, [str(p.relative_to(ROOT)) for p in SCANNED]
    assert all(p.exists() for p in SCANNED)


@pytest.mark.parametrize("d", _profile_dirs(), ids=lambda d: d.name)
def test_bundled_profile_dirs_are_versioned(d):
    for standard in VERSIONED_STANDARDS:
        if _unversioned(standard).search(d.name):
            pytest.fail(
                f"profile directory '{d.name}' implements {standard}, a versioned "
                f"standard, without a revision. Name it '{standard}-<rev>' so "
                "revisions can coexist — see docs/profiles.md#versioning-a-profile"
            )


@pytest.mark.parametrize("path", SCANNED, ids=lambda p: str(p.relative_to(ROOT)))
def test_documented_profile_names_are_versioned(path):
    if path.name in EXEMPT_FILES:
        pytest.skip("states the rule; needs the unversioned form to contrast")
    offenders = []
    for n, line in enumerate(path.read_text().splitlines(), 1):
        for standard in VERSIONED_STANDARDS:
            if not _unversioned(standard).search(line):
                continue
            # A line stating the rule needs the bad form to contrast against:
            # "`cms-ars-5.1`, not `cms-ars`". Exempt only when the SAME standard
            # also appears versioned on that line — per-standard, because
            # "base,cms-ars-5.1,pci-dss" carries one of each and is exactly the
            # bug this catches. A blanket "line has a versioned name" exemption
            # would have excused it.
            if re.search(rf"{re.escape(standard)}-\d", line):
                continue
            offenders.append(f"{path.relative_to(ROOT)}:{n}  {line.strip()[:90]}")
    assert not offenders, (
        "unversioned name for a versioned standard:\n  "
        + "\n  ".join(offenders)
        + "\n\nAn example is the copy people paste. Add the revision."
    )


@pytest.mark.parametrize("d", _profile_dirs(), ids=lambda d: d.name)
def test_rubric_filenames_are_not_versioned(d):
    """The complement — the revision goes on the directory, never the file.

    Filenames are the layering join key: rubric_block matches a profile's file
    to the floor's by identical name, so a versioned filename silently stops
    layering instead of failing loudly.
    """
    floor_names = {p.name for p in (d.parents[1] / "base").glob("*.md")}
    for f in d.rglob("*.md"):
        assert not re.search(r"-\d+\.\d+\.md$", f.name), (
            f"{f.relative_to(ROOT)} has a version in its FILENAME; the revision "
            "belongs on the directory. Filenames are the layering join key."
        )
        if f.parent == d:
            assert f.name in floor_names, (
                f"{f.relative_to(ROOT)} matches no floor file, so it layers onto "
                f"nothing. Floor files: {sorted(floor_names)}"
            )
