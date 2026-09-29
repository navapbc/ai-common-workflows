"""The copy-paste workflows carry the settings every consumer needs.

The quickstart and the examples are what teams actually paste into their own
repositories, so anything they omit, every consumer rediscovers. Three
settings were missing from all five security-review examples at once, which is
how it goes: each is one line, nobody notices the absence, and the cost lands
on people who are not in this repository.

- `concurrency` — the review is a metered model call. Without it, three pushes
  to a PR run three concurrent reviews that each cost money and post
  overlapping comments.
- `timeout-minutes` — a large diff runs about eight minutes; GitHub's default
  job timeout is six hours of runner time for a hung CLI.
- `persist-credentials: false` on the PR checkout — the token-isolation posture
  docs/security.md recommends. The snippet people copy should model the advice
  the prose gives.

Stdlib only, like the rest of this suite (CI installs pytest and nothing
else), so the parsing is line-based rather than PyYAML.
"""

import pathlib
import re

import pytest

ROOT = pathlib.Path(__file__).resolve().parents[2]
EXAMPLES = ROOT / "examples" / "workflows"

ACTION = "ai-common-workflows/workflows/security-compliance-review@"


def _sources():
    """Every complete workflow that invokes the security-review action.

    Scoped by what a snippet *uses*, not by where it lives. Two examples in
    `docs/` were missed when this only scanned `examples/` plus a hardcoded
    quickstart block — a doc snippet is copy-pasted exactly like a file is, so
    it has to meet the same bar.

    Deliberately not extended to the test classifier or the instructions sync.
    They have a different cost and cadence, and sweeping them in would assert
    something nobody has reasoned about.
    """
    out = []
    for p in sorted(EXAMPLES.glob("*.yml")):
        body = p.read_text()
        if ACTION in body:
            out.append((str(p.relative_to(ROOT)), body))
    for md in sorted(ROOT.glob("docs/*.md")) + [ROOT / "README.md"]:
        text = md.read_text()
        for i, m in enumerate(re.finditer(r"```ya?ml\n(.*?)```", text, re.S), start=1):
            block = m.group(1)
            # A full workflow, not an inputs fragment.
            if ACTION in block and re.search(r"^jobs:", block, re.M):
                out.append((f"{md.relative_to(ROOT)} [yaml block {i}]", block))
    return out


SOURCES = _sources()


def test_there_are_sources_to_check():
    # A glob or regex that matched nothing would make every assertion vacuous.
    assert len(SOURCES) >= 7, [n for n, _ in SOURCES]
    # Both kinds of source must be represented, or a whole class is unchecked.
    assert any(n.startswith("examples/") for n, _ in SOURCES), [n for n, _ in SOURCES]
    assert any("yaml block" in n for n, _ in SOURCES), [n for n, _ in SOURCES]


@pytest.mark.parametrize("name,body", SOURCES, ids=[n for n, _ in SOURCES])
def test_declares_concurrency(name, body):
    assert re.search(r"^concurrency:", body, re.M), (
        f"{name} has no concurrency group: pushes to a PR would run concurrent "
        "reviews, each a model call you pay for"
    )
    assert "cancel-in-progress: true" in body, (
        f"{name} declares concurrency without cancel-in-progress, so a "
        "superseded run still finishes and still bills"
    )


@pytest.mark.parametrize("name,body", SOURCES, ids=[n for n, _ in SOURCES])
def test_bounds_the_job(name, body):
    assert re.search(r"^\s+timeout-minutes:\s*\d+", body, re.M), (
        f"{name} has no timeout-minutes; GitHub's default is six hours"
    )


@pytest.mark.parametrize("name,body", SOURCES, ids=[n for n, _ in SOURCES])
def test_pr_checkout_does_not_persist_credentials(name, body):
    """Only where the workflow checks out the PR head itself.

    A workflow with no checkout of untrusted code has nothing to isolate.
    """
    if "actions/checkout" not in body:
        pytest.skip("no checkout step")
    assert "persist-credentials: false" in body, (
        f"{name} checks out PR code without persist-credentials: false, so the "
        "AI phase could read a repo-write token from .git/config — the posture "
        "docs/security.md recommends everywhere else"
    )
