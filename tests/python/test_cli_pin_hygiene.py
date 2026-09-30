"""The AI CLI is installed at an exact version, never a floating one.

`cli-version` used to default to `latest`. So a workflow SHA-pinned the action,
CI enforced SHA-only pins across every doc and example, `docs/security.md`
argued at length about mutable refs — and then the job `npm install -g`'d an
**agentic** CLI, unpinned, at runtime. That CLI reads untrusted PR content with
shell and file-read tools. It was simultaneously the least-pinned and
highest-privilege component in the run.

Why exact rather than a range, since the reasoning differs from the action rule:
npm **forbids republishing a version**, so `@scope/pkg@1.2.3` is immutable in a
way a git tag is not. `^1.2.3` is not — it resolves to whatever exists at
install time, which is `latest` with extra steps.

The pins are plain strings in bash, invisible to Dependabot, so nothing bumps
them automatically and nothing catches them going stale. This at least catches
them going *floating*.
"""

import pathlib
import re

import pytest

ROOT = pathlib.Path(__file__).resolve().parents[2]
CI_LIB = ROOT / "workflows" / "_shared" / "lib" / "ci.sh"
ACTIONS = sorted(ROOT.glob("workflows/*/action.yml"))
DOCKERFILE = ROOT / "Dockerfile"

EXACT = re.compile(r"^\d+\.\d+\.\d+")
PIN = re.compile(r'^_AI_CLI_VER_([A-Z]+)="([^"]*)"', re.M)
# `ARG CLAUDE_CODE_VERSION=2.1.285` → ("CLAUDE", "2.1.285")
ARG = re.compile(r"^ARG (CLAUDE)_CODE_VERSION=(\S+)|^ARG (CODEX|COPILOT)_VERSION=(\S+)", re.M)


def _pins():
    return dict(PIN.findall(CI_LIB.read_text()))


def _dockerfile_args():
    """The Dockerfile's CLI defaults, keyed the way ci.sh keys its pins."""
    out = {}
    for a, av, b, bv in ARG.findall(DOCKERFILE.read_text()):
        out[a or b] = av or bv
    return out


def test_the_pins_are_findable():
    # A regex that matched nothing would make every assertion below vacuous.
    pins = _pins()
    assert pins, f"no _AI_CLI_VER_* pins found in {CI_LIB.relative_to(ROOT)}"
    assert set(pins) >= {"CLAUDE", "CODEX", "COPILOT"}, sorted(pins)


@pytest.mark.parametrize("tool", sorted(_pins()))
def test_each_pin_is_an_exact_version(tool):
    version = _pins()[tool]
    assert version and version != "latest", (
        f"{tool} CLI pin is {version!r} — an agentic CLI reading untrusted PR "
        "content must not float"
    )
    assert EXACT.match(version), (
        f"{tool} CLI pin {version!r} is not an exact version. A range resolves "
        "at install time, which is `latest` with extra steps; an exact npm "
        "version is immutable because npm forbids republishing one."
    )


def test_install_uses_the_pin_not_a_bare_latest():
    """No `npm install -g pkg@latest` literal anywhere in the installer."""
    body = CI_LIB.read_text()
    bad = [
        line.strip()
        for line in body.splitlines()
        if "npm install" in line and "latest" in line
    ]
    assert not bad, f"installer hardcodes a floating version: {bad}"


@pytest.mark.parametrize("path", ACTIONS, ids=lambda p: p.parent.name)
def test_cli_version_input_does_not_default_to_latest(path):
    """The input's default is the thing consumers inherit without choosing.

    Empty means "use the action's pin". `latest` here would put every consumer
    back on a floating agentic CLI by default, which is the bug.
    """
    inputs = path.read_text()
    m = re.search(
        r"^  cli-version:\n(?:.*\n)*?    default: (.*)$", inputs, re.M
    )
    if not m:
        pytest.skip("action takes no cli-version")
    default = m.group(1).strip().strip('"').strip("'")
    assert default != "latest", (
        f"{path.parent.name}: cli-version defaults to 'latest', so every "
        "consumer installs an unpinned agentic CLI without choosing to"
    )
    assert default == "" or EXACT.match(default), (
        f"{path.parent.name}: cli-version default {default!r} should be empty "
        "(use the action's pin) or an exact version"
    )


# ── The sandbox image ───────────────────────────────────────────────────────
#
# The Dockerfile defaulted all three CLIs to `latest` long after #63 pinned
# them in ci.sh, and a comment justified it by pointing at a release workflow
# that does not exist. The experimental surface is exactly where a floating
# install of an agentic CLI survives, because nobody reads it.


def test_the_dockerfile_args_are_findable():
    args = _dockerfile_args()
    assert args, f"no CLI version ARGs found in {DOCKERFILE.name}"
    assert set(args) == {"CLAUDE", "CODEX", "COPILOT"}, sorted(args)


@pytest.mark.parametrize("tool", ["CLAUDE", "CODEX", "COPILOT"])
def test_the_dockerfile_does_not_float(tool):
    version = _dockerfile_args()[tool]
    assert version != "latest", (
        f"Dockerfile defaults {tool} to `latest`. The image bakes in an "
        "agentic CLI that reads untrusted PR content; nothing overrides this "
        "ARG, because nothing builds the image."
    )
    assert EXACT.match(version), f"{tool} is pinned to {version!r}, not an exact version"


@pytest.mark.parametrize("tool", ["CLAUDE", "CODEX", "COPILOT"])
def test_the_dockerfile_agrees_with_ci_sh(tool):
    """One set of pins, two consumers.

    Equality rather than two independent exactness checks: the failure mode
    worth catching is a bump applied to ci.sh and forgotten here, which leaves
    both sides "pinned" and disagreeing about which version the engine runs
    against.
    """
    assert _dockerfile_args()[tool] == _pins()[tool], (
        f"{tool}: Dockerfile says {_dockerfile_args()[tool]}, "
        f"ci.sh says {_pins()[tool]} — bump both."
    )
