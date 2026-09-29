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
QUICKSTART = ROOT / "docs" / "security-compliance-review.md"

ACTION = "ai-common-workflows/workflows/security-compliance-review@"


def _security_review_examples():
    """Examples that invoke the security-review action.

    Scoped by what the file uses rather than by filename, and deliberately not
    extended to the classifier or the instructions sync — those have a
    different cost and cadence, and sweeping them in here would assert
    something nobody has thought about.
    """
    return sorted(p for p in EXAMPLES.glob("*.yml") if ACTION in p.read_text())


def _quickstart_yaml():
    block = re.search(
        r"```yaml\n(# \.github/workflows/ai-security-compliance-review\.yml.*?)```",
        QUICKSTART.read_text(), re.S,
    )
    assert block, "could not find the quickstart YAML block in the doc"
    return block.group(1)


SOURCES = [(p.name, p.read_text()) for p in _security_review_examples()]
SOURCES.append(("docs/security-compliance-review.md (quickstart)", _quickstart_yaml()))


def test_there_are_sources_to_check():
    # A glob or regex that matched nothing would make every assertion vacuous.
    assert len(SOURCES) >= 5, [n for n, _ in SOURCES]
    assert any("quickstart" in n for n, _ in SOURCES)


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
