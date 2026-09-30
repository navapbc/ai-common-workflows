"""The shared rubric floor names no framework *revision*.

`skills/base/` is the framework-neutral floor every run loads; a profile layers
a framework on top. That separation is why profiles exist — one engine serving
several agencies without forks.

It had leaked. `skills/base/pr-review.md` instructed *"always include the NIST
800-53 Rev 5 control ID and the CMS ARS 5.1 control ID"*, and the example JSON
cited ARS as well. So `--profile base` — a program with no CMS relationship —
was told to cite CMS controls. The layering tests could not see it: they check
that a profile's file gets appended, not what the floor already said.

Versioning the profile made it sharper. With `cms-ars-5.1` and a future
`cms-ars-5.2` as siblings, a floor naming one revision contradicts whichever
profile is actually loaded.

**Scoped to revisions on purpose.** The floor legitimately names frameworks as
*detection context* — what PHI is and why HIPAA cares, why FIPS matters for
federal crypto. Banning the word "HIPAA" would gut real content. A revision
("ARS 5.1", "800-53 Rev 5") is different: it is a claim about which published
edition is being judged against, which only a profile can make, and it is the
thing that goes stale. That is also exactly the shape of the bug.

A profile SHOULD name its framework and revision — that is its job, and its
directory name says so. The second test holds that the capability moved rather
than being deleted.

**Both floors, not just the engine's.** `copilot-instructions/base/` is the
same floor for Copilot's native review, and seven places in the docs tell a
consumer the two apply "the same rubric". Nothing shares a source between them
— different decomposition, roughly a third the length, maintained by hand — so
the only thing keeping a rule true on both sides is whoever remembered. This
test was scoped to `engines/` and the identical leak appended to the Copilot
floor passed 365 tests in silence, which is how #62 could have fixed one tree
and left the other. Equality of the two rubrics is not checkable; this one
invariant is.
"""

import pathlib
import re

import pytest

ROOT = pathlib.Path(__file__).resolve().parents[2]
FLOORS = sorted(ROOT.glob("engines/*/skills/base/*.md")) + sorted(
    ROOT.glob("copilot-instructions/base/instructions/*.md")
)

# Revision markers: a framework name followed by an edition.
REVISIONS = {
    "cms-ars-revision": re.compile(r"\bCMS\s+ARS\s+\d+\.\d+", re.I),
    "nist-800-53-revision": re.compile(r"800-53\s+Rev(ision)?\.?\s*\d+", re.I),
    "pci-dss-revision": re.compile(r"\bPCI[\s-]?DSS\s+v?\d+\.\d+", re.I),
}

def _bundled_profile_names():
    """Profile directory names, from the filesystem — never a hardcoded list."""
    return {
        d.name
        for d in list(ROOT.glob("engines/*/skills/profiles/*"))
        + list(ROOT.glob("copilot-instructions/profiles/*"))
        if d.is_dir()
    }


def _points_at_a_profile(text):
    """Does this paragraph name a profile in backticks?

    A pointer to where a framework lives is legitimate in the floor:
    "`cms-ars-5.1` adds CMS ARS 5.1 / NIST SP 800-53 Rev 5 citations".

    Matching the bare English word "profile" was NOT enough, and is how the
    first version of this test passed while the real leak was injected back in:
    the instruction lives in a long paragraph that uses the word "profile"
    several times, so the whole block was excused. It has to be a backticked
    profile NAME, and the names come from disk so this cannot drift.
    """
    return any(f"`{name}`" in text for name in _bundled_profile_names())


def test_there_are_floor_files_to_check():
    # A glob that matched nothing would make this vacuous.
    assert FLOORS, "no floor rubric files found"
    assert len(FLOORS) >= 4, [str(p.relative_to(ROOT)) for p in FLOORS]


def test_both_floors_are_in_scope():
    """Named separately so adding a tree cannot silently drop one.

    `len(FLOORS) >= 4` was satisfied by the engine alone, so a glob that
    stopped matching the Copilot tree would leave the count healthy and the
    coverage gone — the exact shape of the gap this test was widened to close.
    """
    trees = {p.parts[-4] for p in FLOORS}
    assert "copilot-instructions" in trees, sorted(trees)
    assert any(t != "copilot-instructions" for t in trees), sorted(trees)


def _paragraphs(text):
    """(first line number, joined text) per blank-line-separated block.

    Scanned by paragraph, not by line: this prose is hard-wrapped, so a
    sentence like "Use the `cms-ars-5.1` profile for CMS ARS 5.1 / NIST 800-53
    Rev 5 mapping" spans two lines, and a line-based check sees the second half
    as a bare revision with no profile pointer.
    """
    para, start = [], 1
    for n, line in enumerate(text.splitlines(), 1):
        if line.strip():
            if not para:
                start = n
            para.append(line)
        elif para:
            yield start, " ".join(para)
            para = []
    if para:
        yield start, " ".join(para)


@pytest.mark.parametrize("path", FLOORS, ids=lambda p: f"{p.parts[-4]}/{p.name}")
def test_floor_names_no_framework_revision(path):
    offenders = []
    for n, para in _paragraphs(path.read_text()):
        if _points_at_a_profile(para):
            continue
        for name, rx in REVISIONS.items():
            if rx.search(para):
                offenders.append(f"{path.relative_to(ROOT)}:{n} ({name})  {para.strip()[:90]}")
    assert not offenders, (
        "the framework-neutral floor names a framework revision:\n  "
        + "\n  ".join(offenders)
        + "\n\nMove it into the profile that owns that framework. The floor is "
        "loaded by every run, including programs with no relationship to it — "
        "and with versioned profiles as siblings, a revision here contradicts "
        "whichever profile is actually loaded."
    )


@pytest.mark.parametrize(
    "tree,pattern",
    [
        ("engine", "engines/*/skills/profiles/*/*.md"),
        ("copilot", "copilot-instructions/profiles/*/instructions/*.md"),
    ],
)
def test_the_citation_capability_moved_rather_than_vanished(tree, pattern):
    """The complement, asserted per tree.

    Without this, the rule above could be 'satisfied' by stripping revisions
    everywhere, which would quietly gut what a compliance profile is for.

    Per tree rather than across both, because a single global assertion is
    satisfied by the engine profiles alone — so stripping every revision out
    of the Copilot profiles would leave it green while removing the whole
    reason that tree has profiles.
    """
    profiles = sorted(ROOT.glob(pattern))
    assert profiles, f"no {tree} profile rubric files matched {pattern}"
    bearing = [
        p.relative_to(ROOT)
        for p in profiles
        if any(rx.search(p.read_text()) for rx in REVISIONS.values())
    ]
    assert bearing, (
        f"no {tree} profile names a framework revision — the citation "
        "capability was removed from the floor without landing anywhere"
    )
