"""The corpus scorer decides what counts as a detection.

It had no tests, which is backwards: every other suite tests the envelope, the
corpus is the only thing that measures whether the review is any *good*, and
the scorer is what turns its output into pass/fail. A scorer that silently
stops matching would make the corpus report improvements that did not happen.

These run offline — no model calls, unlike the corpus itself.
"""

import importlib.util
import json
import pathlib

import pytest

ROOT = pathlib.Path(__file__).resolve().parents[2]
CORPUS = ROOT / "tests" / "corpus"

_spec = importlib.util.spec_from_file_location("corpus_score", CORPUS / "score.py")
score = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(score)


def _finding(**kw):
    base = {
        "path": "infra/rds.tf",
        "line": 7,
        "perspective": "compliance",
        "severity": "MEDIUM",
        "title": "Missing inventory tags",
        "description": "No owner tag on the instance.",
    }
    base.update(kw)
    return base


def _run(expected, findings, tmp_path):
    e = tmp_path / "expected.json"
    f = tmp_path / "findings.json"
    e.write_text(json.dumps(expected))
    f.write_text(json.dumps({"comments": findings}))
    return e, f


def _verdict(expected, findings, tmp_path, capsys):
    e, f = _run(expected, findings, tmp_path)
    assert score.main(["score.py", str(e), str(f)]) == 0
    return capsys.readouterr().out.split()


# ── forbidden expectations ──────────────────────────────────────────────────
# The targeted form of `clean: true`, added because case 05 failed every run on
# findings unrelated to what it tests.

def test_a_forbidden_match_fails_the_case(tmp_path, capsys):
    expected = {"findings": [], "forbidden": [
        {"path": "infra/rds.tf", "min_severity": "LOW",
         "perspective": "compliance", "must_match": ["encrypt"]}]}
    out = _verdict(expected, [_finding(title="Storage not encrypted at rest")], tmp_path, capsys)
    assert out[-1] == "FAIL"


def test_unrelated_findings_do_not_fail_a_forbidden_case(tmp_path, capsys):
    """The whole reason this exists.

    A realistic resource always has something a thorough reviewer can say about
    it. Failing on that measured the fixture's completeness, not the rubric.
    """
    expected = {"findings": [], "forbidden": [
        {"path": "infra/rds.tf", "min_severity": "LOW",
         "perspective": "compliance", "must_match": ["encrypt"]}]}
    out = _verdict(expected, [
        _finding(title="Missing inventory tags"),
        _finding(title="Single-AZ deployment"),
        _finding(title="No log exports configured"),
    ], tmp_path, capsys)
    assert out[-1] == "PASS"
    assert out[2] == "3", "the noise must still be counted as extras"


def test_forbidden_respects_the_severity_floor(tmp_path, capsys):
    """Case 09's shape: LOW is the right answer, HIGH is crying wolf."""
    expected = {"findings": [], "forbidden": [
        {"path": "src/x.py", "min_severity": "HIGH",
         "perspective": "security", "must_match": ["key"]}]}
    low = _finding(path="src/x.py", perspective="security", severity="LOW",
                   title="Hardcoded key pattern")
    assert _verdict(expected, [low], tmp_path, capsys)[-1] == "PASS"

    crit = dict(low, severity="CRITICAL")
    assert _verdict(expected, [crit], tmp_path, capsys)[-1] == "FAIL"


def test_forbidden_beats_a_satisfied_positive_expectation(tmp_path, capsys):
    # A case can assert both; the wrong answer is still a failure.
    expected = {
        "findings": [{"path": "src/x.py", "min_severity": "LOW",
                      "perspective": "security", "must_match": ["key"]}],
        "forbidden": [{"path": "src/x.py", "min_severity": "CRITICAL",
                       "perspective": "security", "must_match": ["key"]}],
    }
    out = _verdict(expected, [_finding(path="src/x.py", perspective="security",
                                       severity="CRITICAL", title="Hardcoded key")],
                   tmp_path, capsys)
    assert out[-1] == "FAIL"


def test_absent_forbidden_key_changes_nothing(tmp_path, capsys):
    # Every existing case omits it.
    expected = {"clean": True, "findings": []}
    assert _verdict(expected, [], tmp_path, capsys)[-1] == "PASS"
    assert _verdict(expected, [_finding()], tmp_path, capsys)[-1] == "FAIL"


# ── the matching rules the corpus depends on ────────────────────────────────

def test_unrankable_severity_never_satisfies_a_floor(tmp_path, capsys):
    expected = {"findings": [{"path": "src/x.py", "min_severity": "LOW",
                              "perspective": "security", "must_match": ["key"]}]}
    out = _verdict(expected, [_finding(path="src/x.py", perspective="security",
                                       severity="SEV_BANANA", title="Hardcoded key")],
                   tmp_path, capsys)
    assert out[-1] == "FAIL"


def test_one_finding_satisfies_at_most_one_expectation(tmp_path, capsys):
    exp = {"path": "src/x.py", "min_severity": "LOW",
           "perspective": "security", "must_match": ["key"]}
    expected = {"findings": [exp, dict(exp)]}
    out = _verdict(expected, [_finding(path="src/x.py", perspective="security",
                                       severity="HIGH", title="Hardcoded key")],
                   tmp_path, capsys)
    assert out[0] == "2" and out[1] == "1" and out[-1] == "FAIL"


# ── the checked-in cases stay loadable ──────────────────────────────────────

CASES = sorted(p for p in CORPUS.glob("*/expected.json"))


def test_there_are_cases_to_check():
    assert len(CASES) >= 8, [str(p) for p in CASES]


@pytest.mark.parametrize("path", CASES, ids=lambda p: p.parent.name)
def test_every_case_file_is_valid(path):
    data = json.loads(path.read_text())
    assert (path.parent / "head").is_dir(), "every case needs a head/ tree"
    assert (path.parent / "case.md").is_file(), "every case needs a case.md"
    for key in ("findings", "forbidden"):
        for entry in data.get(key, []):
            assert entry.get("path"), f"{key} entry has no path"
            assert str(entry.get("min_severity", "LOW")).upper() in score.RANK
    # A case that asserts nothing would pass forever without telling anyone.
    assert data.get("clean") or data.get("findings") or data.get("forbidden"), \
        "case asserts nothing"
