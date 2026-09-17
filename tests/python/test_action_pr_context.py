"""Every composite action must offer the PR context as a whole, or not at all.

Written after a real bug. `security-compliance-review` and `test-classifier`
both shipped a `pr-number` input documented as "Defaults to the pull_request
event's number" — which reads as an invitation to run on any event and name the
PR yourself. It never worked. The base ref had no matching input, so on
`workflow_dispatch` `ci::resolve_pr_context` errored with "Could not determine
the PR base ref" and the consumer had no knob to fix it: the composite sets
`EVENT_BASE_REF` in its own step `env:`, so a value exported by an earlier step
in the caller is overwritten with the empty string.

The failure mode is an input that exists, is documented, and is unusable. No
other suite can see it: the YAML is valid, the bash is covered, and the
pull_request path — the only one anyone had run — is fine.

So this asserts the pair stays a pair. Both halves of the context get an
explicit input, both are wired into the step that resolves it, and the docs
tell you they go together.

Parsing is hand-rolled rather than via PyYAML: the suite is deliberately
stdlib-only, and a dependency contributors must install before they can run
anything is a worse trade than a scanner for two files we own. The scanners
below are self-checking — `test_the_scanners_still_parse_these_files` fails if
they stop finding what they are looking for, so a format change cannot turn
these assertions into silent no-ops.
"""

import pathlib
import re

import pytest

ROOT = pathlib.Path(__file__).resolve().parents[2]
ACTIONS = sorted(ROOT.glob("workflows/*/action.yml"))

# Both halves of the PR context, each as (explicit input, event payload).
CONTEXT_ENV_KEYS = (
    "PR_NUMBER_INPUT",
    "EVENT_PR_NUMBER",
    "BASE_REF_INPUT",
    "EVENT_BASE_REF",
)


def _input_block(text):
    """The `inputs:` mapping, as {name: raw block text}.

    Top-level `inputs:` with its keys at exactly two spaces. Nested lines
    (`description:`, `default:`) belong to the key above them.
    """
    lines = text.splitlines()
    try:
        start = next(i for i, ln in enumerate(lines) if ln.rstrip() == "inputs:")
    except StopIteration:
        return {}

    found = {}
    current = None
    for ln in lines[start + 1 :]:
        if ln.strip() and not ln.startswith(" "):
            break  # next top-level key (runs:, branding:, ...)
        m = re.match(r"^ {2}([A-Za-z0-9_-]+):", ln)
        if m:
            current = m.group(1)
            found[current] = ln + "\n"
        elif current is not None:
            found[current] += ln + "\n"
    return found


def _context_env_blocks(text):
    """Every `env:` mapping that mentions PR_NUMBER_INPUT, as {KEY: value}.

    Matched by content rather than by step name so renaming the step does not
    quietly disable the check.
    """
    blocks = []
    lines = text.splitlines()
    for i, ln in enumerate(lines):
        if not re.match(r"^\s+env:\s*$", ln):
            continue
        indent = len(ln) - len(ln.lstrip())
        env = {}
        for body in lines[i + 1 :]:
            if not body.strip():
                break
            body_indent = len(body) - len(body.lstrip())
            if body_indent <= indent:
                break
            m = re.match(r"^\s+([A-Za-z_][A-Za-z0-9_]*):\s*(.*)$", body)
            if not m:
                break
            env[m.group(1)] = m.group(2).strip()
        if "PR_NUMBER_INPUT" in env:
            blocks.append(env)
    return blocks


def test_there_are_actions_to_check():
    # A glob that matched nothing would make every test below vacuous.
    assert ACTIONS, "no composite actions found under workflows/*/action.yml"
    assert len(ACTIONS) >= 2, [str(p.relative_to(ROOT)) for p in ACTIONS]


@pytest.mark.parametrize("path", ACTIONS, ids=lambda p: p.parent.name)
def test_the_scanners_still_parse_these_files(path):
    """Guard against the assertions below degrading into no-ops.

    Every check here is conditional on finding something. If a formatting
    change breaks the scanners, the other tests would all skip or pass
    trivially — so assert the scanners see a plausible action first.
    """
    text = path.read_text()
    inputs = _input_block(text)
    assert len(inputs) >= 10, f"only parsed {sorted(inputs)} — scanner broken?"
    assert "ai-tool" in inputs, sorted(inputs)
    # Descriptions must come through too; one test reads them.
    assert "description" in inputs["ai-tool"], inputs["ai-tool"]
    assert _context_env_blocks(text), "no env block mentioning PR_NUMBER_INPUT"


@pytest.mark.parametrize("path", ACTIONS, ids=lambda p: p.parent.name)
def test_pr_number_input_is_paired_with_base_ref(path):
    """The bug this file exists for."""
    inputs = _input_block(path.read_text())
    if "pr-number" not in inputs:
        pytest.skip("action does not take a PR number")
    assert "base-ref" in inputs, (
        f"{path.parent.name} offers 'pr-number' but no 'base-ref'. On a "
        "non-pull_request event the base cannot be derived from the payload, "
        "so 'pr-number' alone fails in ci::resolve_pr_context with no way for "
        "the consumer to supply the missing half."
    )


@pytest.mark.parametrize("path", ACTIONS, ids=lambda p: p.parent.name)
def test_both_context_inputs_reach_the_resolving_step(path):
    """A declared input that is never put in the step env is decorative.

    This is the half of the bug that YAML validation cannot see: `base-ref`
    could exist as an input, be documented, and still never be read.
    """
    for env in _context_env_blocks(path.read_text()):
        missing = [k for k in CONTEXT_ENV_KEYS if k not in env]
        assert not missing, (
            f"{path.parent.name} resolves the PR context without {missing}"
        )
        assert "inputs.base-ref" in env["BASE_REF_INPUT"], (
            f"{path.parent.name}: BASE_REF_INPUT must come from the action "
            f"input, got {env['BASE_REF_INPUT']!r}"
        )


@pytest.mark.parametrize("path", ACTIONS, ids=lambda p: p.parent.name)
def test_pr_number_docs_say_base_ref_comes_with_it(path):
    """The original description is what made the gap plausible to a reader.

    Anyone who reads "Defaults to the pull_request event's number" concludes
    they may set it on another event. They may — with base-ref. Say so where
    they are looking.
    """
    inputs = _input_block(path.read_text())
    if "pr-number" not in inputs:
        pytest.skip("action does not take a PR number")
    assert "base-ref" in inputs["pr-number"], (
        f"{path.parent.name}: the 'pr-number' description should name "
        "'base-ref' as its companion on non-pull_request events"
    )
