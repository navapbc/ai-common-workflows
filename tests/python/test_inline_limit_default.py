"""The inline-comment limit has one default, written in two languages.

`DEFAULT_MAX_COMMENTS` in github_payload.py is what actually applies when
`AI_REVIEW_MAX_COMMENTS` is unset. The review entrypoint separately hardcodes
the same number twice — in its `--help` text and in the `--dry-run` plan — and
nothing connects them.

That drift is worse than it looks. The dry-run exists so an operator can check
the plan before spending money on a model call; a plan that reports a limit the
posting phase does not use is a dry-run that lies, and it lies quietly. The
help text is the other copy someone reads instead of the source.

The duplication is deliberate — the shell should not shell out to Python to
print a line of help — so it is pinned here instead of removed.
"""

import pathlib
import re
import sys

ROOT = pathlib.Path(__file__).resolve().parents[2]
ENTRYPOINT = ROOT / "engines/security-compliance-review/harness/ai-security-compliance-review"

sys.path.insert(0, str(ROOT / "engines/_common/scm"))
import github_payload as gp  # noqa: E402


def _entrypoint():
    return ENTRYPOINT.read_text()


def test_the_entrypoint_exists():
    # A path typo would make every assertion below vacuous.
    assert ENTRYPOINT.is_file(), ENTRYPOINT


def test_help_text_states_the_real_default():
    m = re.search(r"AI_REVIEW_MAX_COMMENTS\s+Limit on inline comments per review \(default (\d+);", _entrypoint())
    assert m, "could not find the AI_REVIEW_MAX_COMMENTS help entry"
    assert int(m.group(1)) == gp.DEFAULT_MAX_COMMENTS, (
        f"--help says {m.group(1)}, github_payload.py applies "
        f"{gp.DEFAULT_MAX_COMMENTS}"
    )


def test_dry_run_plan_states_the_real_default():
    """Every fallback on that line, not just the first.

    The line reads the variable twice — once for the number and once to decide
    whether to print "no limit" — so a half-updated edit would print the right
    number and the wrong wording.
    """
    line = next(
        (ln for ln in _entrypoint().splitlines() if "Inline limit:" in ln), None
    )
    assert line, "could not find the Inline limit line in the dry-run plan"
    fallbacks = re.findall(r"\$\{AI_REVIEW_MAX_COMMENTS:-(\d+)\}", line)
    assert fallbacks, f"no ${{AI_REVIEW_MAX_COMMENTS:-N}} fallback in: {line}"
    assert all(int(n) == gp.DEFAULT_MAX_COMMENTS for n in fallbacks), (
        f"dry-run plan falls back to {fallbacks}, github_payload.py applies "
        f"{gp.DEFAULT_MAX_COMMENTS}"
    )


def test_no_other_stale_default_lurks_in_the_entrypoint():
    """Catch a third copy appearing later.

    Scoped to lines that mention the variable, so an unrelated 15 or 50
    elsewhere in the entrypoint does not fail this.
    """
    stale = [
        ln.strip()
        for ln in _entrypoint().splitlines()
        if "AI_REVIEW_MAX_COMMENTS" in ln
        for n in re.findall(r"\b(\d+)\b", ln)
        if n != "0" and int(n) != gp.DEFAULT_MAX_COMMENTS
    ]
    assert not stale, f"line(s) mentioning a default other than {gp.DEFAULT_MAX_COMMENTS}: {stale}"
