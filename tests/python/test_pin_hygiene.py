"""Guards the SHA-only pinning rule in the docs and examples.

A git tag is a mutable pointer — it can be deleted and re-created against a
different commit, and nothing in a consuming workflow would notice. So
docs/security.md requires a full commit SHA and nothing else. That rule is easy
to state and easy to erode: the natural thing to write in an example is
`@v1.0.0`, and a reviewer skims past it.

These tests fail when a doc or example shows a mutable reference, so the rule is
enforced by CI rather than by remembering. They deliberately check the copy a
consumer would paste, not this repo's own CI — it pins `actions/*` by SHA too,
but that is a separate concern with its own reviewers.
"""

import pathlib
import re

ROOT = pathlib.Path(__file__).resolve().parents[2]

# Files a consumer copies from: the quickstarts, the examples, the READMEs.
SCANNED = (
    sorted(ROOT.glob("docs/*.md"))
    + sorted(ROOT.glob("examples/workflows/*.yml"))
    + sorted(ROOT.glob("copilot-instructions/**/*.md"))
    + [ROOT / "README.md"]
)

# `uses: navapbc/ai-common-workflows/...@<ref>` — the ref must be a 40-char SHA
# or an obvious placeholder, never a tag or branch.
# The ref stops at whitespace or any markdown/YAML punctuation that can follow
# it — a trailing backtick or comma is not part of the ref.
USES_RE = re.compile(r"navapbc/ai-common-workflows[^\s@]*@([^\s\"'`#)\],]+)")

SHA_RE = re.compile(r"^[0-9a-f]{40}$")
PLACEHOLDERS = {
    "<commit-sha>",
    "<40-char-sha>",
    "REPLACE_WITH_COMMIT_SHA",
    "<sha>",
    "<ref>",
}


def _scan(pattern):
    hits = []
    for path in SCANNED:
        if not path.exists():
            continue
        for lineno, line in enumerate(path.read_text().splitlines(), 1):
            for m in pattern.finditer(line):
                hits.append((path.relative_to(ROOT), lineno, m.group(1), line.strip()))
    return hits


def test_no_doc_or_example_pins_this_repo_by_tag_or_branch():
    bad = [
        (p, n, ref, line)
        for p, n, ref, line in _scan(USES_RE)
        if not SHA_RE.match(ref) and ref not in PLACEHOLDERS
    ]
    assert not bad, "mutable refs to ai-common-workflows (use a 40-char SHA):\n" + "\n".join(
        f"  {p}:{n}  @{ref}\n    {line}" for p, n, ref, line in bad
    )


# ── the instruction sync is the documented exception ───────────────────────
# ACW_REF used to be required to be a SHA. It is now `main` on purpose: the
# sync executes nothing (it copies Markdown), never pushes to a default
# branch, and lands every change as a PR whose diff is plain English someone
# reads. A pin would put an unread gate in front of a read one, and would make
# the sync's schedule inert — a fixed ref never produces a diff.
#
# The risk of an exception is that it reads as the rule eroding. So it is not
# enough for it to be true; it has to be EXPLAINED wherever it is visible.
# That is what these two tests hold.

# Wording that establishes the PR, not a pin, as the control.
_GATE_PHRASES = ("the pr is the gate", "pr is the gate", "reviewable pr", "your team reviews")


def test_every_acw_ref_surface_explains_that_the_pr_is_the_gate():
    """An unexplained unpinned ref looks like an oversight.

    Anyone who has read docs/security.md's pinning rule and then meets
    `ACW_REF: main` should find the reason in the same file, not have to go
    looking — otherwise the sensible reaction is to "fix" it back to a SHA.
    """
    missing = []
    for path in SCANNED:
        text = path.read_text()
        if "ACW_REF" not in text:
            continue
        low = text.lower()
        if not any(phrase in low for phrase in _GATE_PHRASES):
            missing.append(str(path.relative_to(ROOT)))
    assert not missing, (
        "file(s) mention ACW_REF without explaining that the PR is the gate: "
        f"{missing}. An unexplained exception to the SHA rule reads as an "
        "oversight and invites someone to 'fix' it."
    )


def test_acw_ref_values_are_main_or_a_sha_never_a_tag():
    """`main` is the default; a SHA is the supported opt-in. A tag is neither.

    The tag argument still holds here — it can be deleted and re-pointed — and
    it buys nothing `main` does not, so it is the one value that is simply
    wrong.
    """
    pattern = re.compile(r"ACW_REF:\s*(\S+)")
    bad = [
        (p, n, ref, line)
        for p, n, ref, line in _scan(pattern)
        if ref != "main" and not SHA_RE.match(ref) and ref not in PLACEHOLDERS
    ]
    assert not bad, "ACW_REF set to something other than main or a SHA:\n" + "\n".join(
        f"  {p}:{n}  {ref}\n    {line}" for p, n, ref, line in bad
    )


def test_no_acw_ref_line_suggests_a_tag_in_a_trailing_comment():
    """The value can be right while the comment beside it is wrong.

    The example carried `ACW_REF: REPLACE_WITH_COMMIT_SHA # e.g. a 40-char
    SHA, or v1.0.0` four lines under a block saying "NOT a tag". The
    value-only check above could not see it, because the value was an
    allowlisted placeholder.
    """
    bad = []
    for path in SCANNED:
        for n, line in enumerate(path.read_text().splitlines(), 1):
            if "ACW_REF:" not in line or "#" not in line:
                continue
            comment = line.split("#", 1)[1]
            if re.search(r"\bv\d+\.\d+", comment) or "tag" in comment.lower():
                bad.append(f"{path.relative_to(ROOT)}:{n}  {line.strip()}")
    assert not bad, "ACW_REF line whose comment offers a tag:\n  " + "\n  ".join(bad)


def test_docs_do_not_offer_a_tag_as_an_acceptable_pin():
    # Catches the prose form, which is how the rule eroded before: several
    # places used to say "a commit SHA or a release tag".
    phrases = (
        "or release tag",
        "or a release tag",
        "or a tag",
        "sha (preferred)",
        "tag/release so consumers",
    )
    bad = []
    for path in SCANNED:
        if not path.exists():
            continue
        for lineno, line in enumerate(path.read_text().splitlines(), 1):
            low = line.lower()
            for phrase in phrases:
                if phrase in low:
                    bad.append((path.relative_to(ROOT), lineno, line.strip()))
    assert not bad, "prose offering a tag as an acceptable pin:\n" + "\n".join(
        f"  {p}:{n}  {line}" for p, n, line in bad
    )


def test_security_md_states_why_a_tag_is_not_immutable():
    # The rule has to carry its reason, or the next person weakens it back.
    text = (ROOT / "docs" / "security.md").read_text().lower()
    assert "mutable pointer" in text
    assert "re-created" in text or "recreated" in text


def test_the_scan_actually_finds_the_reference_form_it_guards():
    # A regex that matches nothing would make every test above vacuous.
    assert _scan(USES_RE), "no ai-common-workflows uses: references found — check USES_RE"
