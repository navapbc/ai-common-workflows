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


def test_acw_ref_is_never_documented_as_a_tag():
    # ACW_REF is the instruction sync's pin. It is a plain env var, so nothing
    # validates it at run time — the docs are the only guard.
    pattern = re.compile(r"ACW_REF:\s*(\S+)")
    bad = [
        (p, n, ref, line)
        for p, n, ref, line in _scan(pattern)
        if not SHA_RE.match(ref) and ref not in PLACEHOLDERS
    ]
    assert not bad, "ACW_REF documented as a non-SHA ref:\n" + "\n".join(
        f"  {p}:{n}  {ref}\n    {line}" for p, n, ref, line in bad
    )


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
