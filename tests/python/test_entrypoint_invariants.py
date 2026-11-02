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
import sys

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


def test_no_entrypoint_falls_back_to_self_adjudication():
    """Adjudication defaults to off; every fallback must agree.

    The prompt builders read AI_REVIEW_ADJUDICATION_MODE with a default, and
    those defaults said "self" after the engine default moved to "off". They
    are not reachable today — the mode is exported before the prompt is built —
    but a stale fallback nobody hits is how the next refactor silently restores
    the old behaviour, and this one would do it invisibly: the review would
    just quietly start self-adjudicating again.
    """
    bad = [
        p.relative_to(ROOT)
        for p in ENTRYPOINTS
        if "AI_REVIEW_ADJUDICATION_MODE:-self" in p.read_text()
    ]
    assert not bad, f"entrypoint(s) fall back to self-adjudication: {bad}"


# ── the suite's own dependencies ────────────────────────────────────────────

def test_the_python_suite_is_stdlib_plus_pytest_only():
    """CI installs pytest and nothing else.

    A third-party import here is not a local failure — it is a COLLECTION
    error, so the whole pytest job dies and every other test in the suite goes
    unreported. It also passes locally, where the package happens to be
    installed, which is how it reaches CI in the first place.
    That is not hypothetical: test_secret_fixtures.py shipped with `import
    yaml`, passed locally, and failed CI at collection. The fix was a
    hand-rolled parser for the one file it needed; this test is so the next one
    is caught before the push.
    Widen the allowlist only alongside the `pip install` line in
    .github/workflows/ci.yml and the note in CLAUDE.md.
    """
    allowed = {"pytest"}
    # Repo-local modules reached via sys.path.insert (github_payload,
    # gate_verdict, the corpus scorer...) are not dependencies. Derived from
    # the tree rather than listed, so adding one does not need a test edit.
    local = {p.stem for p in ROOT.rglob("*.py") if ".git" not in p.parts}
    stdlib = set(sys.stdlib_module_names)
    offenders = {}
    for path in sorted((ROOT / "tests" / "python").glob("test_*.py")):
        mods = set()
        for line in path.read_text().splitlines():
            m = re.match(r"^\s*(?:import|from)\s+([A-Za-z_][\w.]*)", line)
            if m:
                mods.add(m.group(1).split(".")[0])
        extra = mods - stdlib - allowed - local
        if extra:
            offenders[path.name] = sorted(extra)
    assert not offenders, (
        "third-party import(s) in the python suite; CI installs only "
        f"{sorted(allowed)}, so this is a collection error there: {offenders}"
    )


def test_the_documented_dry_run_plan_shows_the_real_adjudication_default():
    """A worked example in the docs is a claim about behaviour.

    `docs/codebase-audit.md` prints a sample `--dry-run` plan. When the
    adjudication default moved to "off", that example kept showing
    "Adjudication:   self" — so the page demonstrated a run that could not
    happen, in the one place a reader looks to learn what a run costs.

    Pinned to the engine's own default rather than to a literal, so the example
    has to move whenever the default does.
    """
    core = (ROOT / "engines/_common/harness/core.sh").read_text()
    m = re.search(r"\$\{AI_ADJUDICATION:-(\w+)\}", core)
    assert m, "could not find the AI_ADJUDICATION default in core.sh"
    default = m.group(1)

    doc = (ROOT / "docs/codebase-audit.md").read_text()
    shown = re.findall(r"^\s*Adjudication:\s+(\w+)\s*$", doc, re.M)
    assert shown, "no 'Adjudication:' line in the documented dry-run plan"
    wrong = [v for v in shown if v != default]
    assert not wrong, (
        f"docs/codebase-audit.md shows Adjudication: {wrong}, but the engine "
        f"defaults to {default!r}"
    )


def test_no_doc_sells_disabling_adjudication_as_a_saving():
    """`--no-adjudicate` stopped being a cost lever when the default flipped.

    It is still useful — it forces off when AI_ADJUDICATION is set in the
    environment — but describing it as "cheaper" tells a reader to spend effort
    turning off something that is already off.
    """
    offenders = []
    for path in [ROOT / "docs/codebase-audit.md", ROOT / "docs/github-action.md"] + list(
        (ROOT / "engines/security-compliance-review/harness").glob("ai-*")
    ):
        for line in path.read_text().splitlines():
            if "no-adjudicate" in line and re.search(r"cheaper|saving|cost", line, re.I):
                offenders.append(f"{path.relative_to(ROOT)}: {line.strip()}")
    assert not offenders, offenders
