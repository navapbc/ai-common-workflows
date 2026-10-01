"""There is no built-in sandbox, and no documentation claims one.

`CLAUDE.md` has long carried the convention "don't claim a network boundary the
tool doesn't enforce". The main thing undermining it was an experimental
Docker/egress-proxy sandbox sitting in `engines/_common/sandbox/` — never
wired into either front end, never verified against a real CLI, and silently
reviewing an empty checkout on sibling-container runners. It was removed in
full; see docs/adr/0002-remove-the-experimental-egress-sandbox.md.

Unbuilt code does not stay honest. That directory's `Dockerfile` named a
release workflow that had never existed in this layout and floated all three
agentic CLI installs on `latest` for weeks after the same pins were fixed
everywhere else. Nobody noticed, because nobody reads a file nothing builds.

**If you are reintroducing a sandbox:** delete this module deliberately, in the
same change that adds working code and documentation that describes what it
actually enforces. That coupling is the point — the claim and the code should
move together, which is what went wrong last time.
"""

import pathlib
import re
import subprocess

import pytest

ROOT = pathlib.Path(__file__).resolve().parents[2]

GONE = [
    "engines/_common/sandbox",
    "Dockerfile",
    "tests/bats/sandbox.bats",
    "tests/python/test_allowlist_proxy.py",
]

# Shipped prose. Deliberately excludes CHANGELOG.md (a historical record of what
# was true at the time) and docs/adr/ (records that discuss the removal).
def _shipped_docs():
    out = subprocess.run(
        ["git", "ls-files", "*.md"], cwd=ROOT, capture_output=True, text=True, check=True
    ).stdout.split()
    return [
        ROOT / p
        for p in out
        if p != "CHANGELOG.md" and not p.startswith("docs/adr/")
    ]


def test_the_doc_scan_is_not_empty():
    # A listing that returned nothing would make the assertions below vacuous.
    docs = _shipped_docs()
    assert len(docs) >= 15, [str(p.relative_to(ROOT)) for p in docs]


@pytest.mark.parametrize("path", GONE)
def test_the_sandbox_tree_is_absent(path):
    assert not (ROOT / path).exists(), (
        f"{path} is back. If that is deliberate, delete this module in the same "
        "change — and make sure the docs describe what it actually enforces."
    )


def test_nothing_references_the_removed_paths():
    """Catches a half-removal: a reference left pointing at a deleted file."""
    offenders = []
    tracked = subprocess.run(
        ["git", "ls-files"], cwd=ROOT, capture_output=True, text=True, check=True
    ).stdout.split()
    needles = ("engines/_common/sandbox", "tests/bats/sandbox.bats", "allowlist_proxy")
    for rel in tracked:
        if rel in ("CHANGELOG.md", pathlib.Path(__file__).relative_to(ROOT).as_posix()):
            continue
        if rel.startswith("docs/adr/"):
            continue
        f = ROOT / rel
        if not f.is_file():
            continue
        try:
            text = f.read_text()
        except UnicodeDecodeError:
            continue
        for n, line in enumerate(text.splitlines(), 1):
            if any(x in line for x in needles):
                offenders.append(f"{rel}:{n}: {line.strip()[:80]}")
    assert not offenders, "references to removed sandbox paths:\n  " + "\n  ".join(offenders)


# A sandbox mentioned as existing, or as forthcoming.
#
# Negation is checked by looking BACKWARDS from the match, not forwards: the
# honest sentences in these docs read "There is **no** built-in sandbox", so a
# forward lookahead flagged every correct statement and none of the wrong ones.
MENTIONS = re.compile(r"\bbuilt-in (?:network |egress )?sandbox\b", re.I)
FORTHCOMING = re.compile(
    r"\bsandbox\b[^.\n]{0,40}\b(on the roadmap|in a future release|coming soon|planned for)\b",
    re.I,
)
NEGATED = re.compile(
    r"\b(no|not|never|without|isn'?t|aren'?t|lacks|lacking|nothing)\b", re.I
)


def _promises(line):
    """True when `line` asserts a sandbox rather than denying one."""
    if FORTHCOMING.search(line):
        return True
    m = MENTIONS.search(line)
    if not m:
        return False
    # Everything from the start of the sentence up to the mention.
    before = line[: m.start()]
    before = re.split(r"(?<=[.!?])\s", before)[-1]
    return not NEGATED.search(before)


def test_no_shipped_doc_promises_a_sandbox():
    """The convention in CLAUDE.md, enforced.

    Saying there is NO built-in sandbox is fine and expected — several docs do.
    Asserting one exists, or that one is coming, is not.
    """
    offenders = []
    for f in _shipped_docs():
        for n, line in enumerate(f.read_text().splitlines(), 1):
            if _promises(line):
                offenders.append(f"{f.relative_to(ROOT)}:{n}: {line.strip()[:90]}")
    assert not offenders, (
        "documentation promises a sandbox the engine does not provide:\n  "
        + "\n  ".join(offenders)
        + "\n\nEgress and sandboxing are the consumer's responsibility. Say that, "
        "without a qualifier implying a boundary is partially present or imminent."
    )


@pytest.mark.parametrize(
    "path,needle",
    [
        ("CLAUDE.md", "consumer's responsibility"),
        ("docs/security.md", "your infrastructure's responsibility"),
        ("SECURITY.md", "consumer's responsibility"),
    ],
)
def test_the_consumer_responsibility_is_stated(path, needle):
    """The complement.

    Without this, the rule above is satisfiable by deleting every mention of
    egress — which would leave a reader with no statement either way, the one
    outcome worse than an overclaim.
    """
    assert needle in (ROOT / path).read_text(), (
        f"{path} no longer states that egress/sandboxing is the consumer's "
        "responsibility"
    )
