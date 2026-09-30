"""Dependabot covers every ecosystem this repo actually has a manifest for.

`docs/security.md` hands consumers a dependabot config and tells them to keep
this action's pin fresh, and the repo ran without one of its own for its first
sixty-odd pull requests. The asymmetry is the kind that is invisible until
someone reads both files in one sitting.

The interesting assertion is not "the file exists" — it is that the file keeps
up. A manifest added later in a directory nothing watches is exactly as stale
as having no config at all, and nothing else in the suite would notice.

Parsed by hand rather than with PyYAML: CI installs pytest and nothing else, so
a third-party import here is a *collection* error that kills the whole job
while passing locally. Only two keys are needed.
"""

import pathlib
import re

import pytest

ROOT = pathlib.Path(__file__).resolve().parents[2]
CONFIG = ROOT / ".github" / "dependabot.yml"

# `- package-ecosystem: x` … `directory: "/y"`, in file order.
_ENTRY = re.compile(
    r'^\s*-\s*package-ecosystem:\s*"?([a-z-]+)"?\s*$'
    r"(?:(?!^\s*-\s*package-ecosystem:).)*?"
    r'^\s*directory:\s*"([^"]+)"',
    re.M | re.S,
)


def _entries():
    text = CONFIG.read_text()
    found = [(m.group(1), m.group(2)) for m in _ENTRY.finditer(text)]
    # Guard the parser itself: a regex that silently matches nothing would make
    # every coverage assertion below vacuously true.
    assert found, "parsed no update entries out of .github/dependabot.yml"
    return found


def test_the_config_exists_and_is_version_2():
    assert CONFIG.is_file(), ".github/dependabot.yml is missing"
    assert re.search(r"^version:\s*2\s*$", CONFIG.read_text(), re.M), (
        "dependabot.yml must declare `version: 2`"
    )


def test_the_parser_finds_the_entries():
    ecosystems = {eco for eco, _ in _entries()}
    assert "github-actions" in ecosystems


@pytest.mark.parametrize(
    "ecosystem,directory,why",
    [
        ("github-actions", "/", "the workflows under .github/workflows/"),
        ("maven", "/jenkins-plugin", "the Jenkins plugin reactor"),
        ("docker", "/", "the sandbox image's Dockerfile"),
    ],
)
def test_each_manifest_directory_is_watched(ecosystem, directory, why):
    assert (ecosystem, directory) in _entries(), (
        f"dependabot.yml has no {ecosystem} entry for {directory} — {why}"
    )


def test_maven_is_pointed_at_the_reactor_root_not_a_module():
    """The reactor root; Dependabot walks the modules from there.

    Pointing at a module instead would update that module's pom and leave the
    other two behind, which looks like coverage and is not.
    """
    maven = [d for eco, d in _entries() if eco == "maven"]
    assert maven, "no maven entry"
    for directory in maven:
        pom = ROOT / directory.lstrip("/") / "pom.xml"
        assert pom.is_file(), f"maven entry points at {directory}, which has no pom.xml"
        assert "<modules>" in pom.read_text(), (
            f"{directory}/pom.xml is not the reactor root — Dependabot would "
            "miss the sibling modules"
        )


def test_composite_actions_use_no_external_action():
    """The stated reason `github-actions` only needs a `/` entry.

    A `/` entry covers .github/workflows/ and NOT workflows/*/action.yml. That
    is fine only while the composites reference nothing external. If one gains
    an external `uses:`, it needs its own dependabot entry — and this is the
    test that says so, because the gap would otherwise be silent: the pin just
    never gets bumped.
    """
    offenders = []
    for action in sorted(ROOT.glob("workflows/*/action.yml")):
        for lineno, line in enumerate(action.read_text().splitlines(), 1):
            m = re.match(r"\s*-?\s*uses:\s*(\S+)", line)
            if m and not m.group(1).startswith("./"):
                offenders.append(f"{action.relative_to(ROOT)}:{lineno}: {m.group(1)}")

    watched = {d for eco, d in _entries() if eco == "github-actions"}
    if offenders and not any(d.startswith("/workflows") for d in watched):
        pytest.fail(
            "a composite action now references an external action, so "
            ".github/dependabot.yml needs a github-actions entry for its "
            "directory:\n  " + "\n  ".join(offenders)
        )


def test_there_is_a_security_policy_and_it_names_the_reporting_channel():
    """A public repo whose subject is security review needs a way in.

    Asserting the channel and not just the file: a SECURITY.md that says
    "contact the maintainers" leaves a reporter guessing, which is how an
    exploitable bug ends up in a public issue.
    """
    policy = ROOT / "SECURITY.md"
    assert policy.is_file(), "SECURITY.md is missing"
    text = policy.read_text()
    assert "Report a vulnerability" in text, (
        "SECURITY.md must name GitHub private vulnerability reporting"
    )
    assert "/security" in text, "SECURITY.md must link the repo's Security tab"
    # The fixtures draw reports; saying so up front is most of the file's value.
    assert "fake credentials" in text.lower() or "credential-shaped" in text, (
        "SECURITY.md should pre-empt reports about the deliberate test fixtures"
    )
