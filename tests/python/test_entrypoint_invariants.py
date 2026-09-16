"""Invariants every engine entrypoint must satisfy.

Written after a real bug: `ai-security-compliance-audit` was added as a second
entrypoint and never called `ai_review::configure_endpoint`. Nothing failed.
`AI_REVIEW_PROVIDER` was simply read by no one, so an audit configured for
Bedrock or Azure ran against the public API — sending the whole scope to an
endpoint the operator believed they had avoided, with no error and a
clean-looking report.

That class of bug is invisible to the existing suites: the engine works, the
JSON parses, the gate fires. What is missing is a *setup call*, and the only
symptom is where the traffic went.

So these tests assert the obligations a new entrypoint inherits, by scanning
the source. They are static and cheap, and they fail loudly when someone adds
an engine entrypoint that skips one — which is exactly when nobody is looking
for it.
"""

import pathlib
import re

ROOT = pathlib.Path(__file__).resolve().parents[2]

# Engine entrypoints: engines/<workflow>/harness/ai-*
ENTRYPOINTS = sorted(ROOT.glob("engines/*/harness/ai-*"))


def _calls(path, fn):
    """Does this file call ai_review::<fn>, ignoring comments?"""
    pattern = re.compile(rf"\bai_review::{re.escape(fn)}\b")
    for line in path.read_text().splitlines():
        stripped = line.lstrip()
        if stripped.startswith("#"):
            continue
        if pattern.search(line):
            return True
    return False


def _model_calling(path):
    """Entrypoints that actually invoke a model, as opposed to posting only."""
    return _calls(path, "invoke_ai") or _calls(path, "invoke_tool")


def test_there_are_entrypoints_to_check():
    # A glob that matched nothing would make every test below vacuous.
    assert ENTRYPOINTS, "no engine entrypoints found under engines/*/harness/ai-*"
    assert len(ENTRYPOINTS) >= 3, [p.name for p in ENTRYPOINTS]


def test_every_model_calling_entrypoint_configures_the_endpoint():
    """The bug this file exists for.

    `configure_endpoint` is what turns AI_REVIEW_PROVIDER into the CLI's
    endpoint environment and validates it. Skip it and the provider inputs
    become decorative: the run succeeds against the default public endpoint.
    """
    missing = [
        p.relative_to(ROOT)
        for p in ENTRYPOINTS
        if _model_calling(p) and not _calls(p, "configure_endpoint")
    ]
    assert not missing, (
        "entrypoint(s) invoke a model without calling "
        "ai_review::configure_endpoint, so AI_REVIEW_PROVIDER would be "
        f"silently ignored and traffic would go to the public endpoint: {missing}"
    )


def test_every_model_calling_entrypoint_resolves_the_tool():
    missing = [
        p.relative_to(ROOT)
        for p in ENTRYPOINTS
        if _model_calling(p) and not _calls(p, "resolve_tool")
    ]
    assert not missing, f"entrypoint(s) invoke a model without resolving the tool: {missing}"


def test_every_entrypoint_parses_the_shared_flags():
    """--dry-run, --no-block, --jobs and friends live in _common.

    An entrypoint that never calls parse_args silently ignores all of them,
    which looks like the flag being broken rather than unimplemented.
    """
    missing = [
        p.relative_to(ROOT) for p in ENTRYPOINTS if not _calls(p, "parse_args")
    ]
    assert not missing, f"entrypoint(s) do not call ai_review::parse_args: {missing}"


def test_every_entrypoint_overrides_the_generic_help():
    """_common ships a deliberately generic print_help as a fallback.

    An entrypoint that does not override it prints help for a workflow the
    reader is not running.
    """
    missing = [
        p.relative_to(ROOT)
        for p in ENTRYPOINTS
        if "ai_review::print_help()" not in p.read_text()
    ]
    assert not missing, f"entrypoint(s) do not override print_help: {missing}"


def test_every_entrypoint_sets_skill_name_before_logging():
    """The logging helpers interpolate SKILL_NAME unconditionally.

    Leave it unset and the first ai_review::info call dies with
    "SKILL_NAME: unbound variable" under `set -u` — which is how the audit
    first failed when it was written.
    """
    missing = [
        p.relative_to(ROOT)
        for p in ENTRYPOINTS
        if not re.search(r"^SKILL_NAME=", p.read_text(), re.M)
    ]
    assert not missing, f"entrypoint(s) never set SKILL_NAME: {missing}"


def test_every_entrypoint_resolves_paths_from_its_own_location():
    """Relocatability: paths come from ENGINE_HOME, never the CWD.

    The working directory at runtime is the repo being reviewed, so a path
    resolved from `.` would read the *audited* repo's files as the rubric.
    """
    bad = [
        p.relative_to(ROOT)
        for p in ENTRYPOINTS
        if 'ENGINE_HOME="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"' not in p.read_text()
    ]
    assert not bad, f"entrypoint(s) do not derive ENGINE_HOME from BASH_SOURCE: {bad}"
