"""Tests for engines/_common/harness/fold_review_json.py — merging per-batch findings."""

import importlib.util
import pathlib

_MODULE_PATH = (
    pathlib.Path(__file__).resolve().parents[2]
    / "engines" / "_common" / "harness" / "fold_review_json.py"
)
_spec = importlib.util.spec_from_file_location("fold_review_json", _MODULE_PATH)
fold = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(fold)


def _c(path, line, perspective="security", severity="HIGH"):
    return {"path": path, "line": line, "perspective": perspective, "severity": severity,
            "title": "t", "description": "d"}


def _r(action="COMMENT", comments=None):
    return {"review_action": action, "summary": "s", "comments": comments or []}


def test_concatenates_distinct_findings():
    merged, _ = fold.merge([
        _r(comments=[_c("a.py", 1)]),
        _r(comments=[_c("b.py", 2)]),
    ])
    assert merged["review_action"] == "COMMENT"
    assert len(merged["comments"]) == 2


def test_all_batches_empty_yields_approve():
    merged, _ = fold.merge([_r("APPROVE"), _r("APPROVE")])
    assert merged["review_action"] == "APPROVE"
    assert merged["comments"] == []


def test_dedup_by_path_line_perspective_keeps_higher_severity():
    merged, _ = fold.merge([
        _r(comments=[_c("a.py", 1, severity="LOW")]),
        _r(comments=[_c("a.py", 1, severity="CRITICAL")]),
    ])
    assert len(merged["comments"]) == 1
    assert merged["comments"][0]["severity"] == "CRITICAL"


def test_same_line_different_perspective_both_kept():
    merged, _ = fold.merge([
        _r(comments=[_c("a.py", 1, perspective="security")]),
        _r(comments=[_c("a.py", 1, perspective="compliance")]),
    ])
    assert len(merged["comments"]) == 2


def test_request_changes_is_not_softened():
    merged, _ = fold.merge([
        _r("REQUEST_CHANGES", comments=[_c("a.py", 1)]),
        _r("APPROVE"),
    ])
    assert merged["review_action"] == "REQUEST_CHANGES"


def test_summary_reports_batch_count_and_counts():
    merged, _ = fold.merge([
        _r(comments=[_c("a.py", 1, severity="CRITICAL")]),
        _r(comments=[_c("b.py", 2, severity="LOW")]),
    ])
    assert "2 diff batch(es)" in merged["summary"]
    assert "1 critical" in merged["summary"]


# ── never fail open ─────────────────────────────────────────────────────────
# The fan-out path derives the GATE verdict from this merged JSON, so anything
# dropped here is invisible to the gate. These lock that shut.

def test_finding_without_line_does_not_fold_to_approve():
    """Regression: a batch reporting COMMENT whose finding lacks a line anchor
    used to merge to APPROVE, silently passing --gate on a real finding."""
    merged, msgs = fold.merge([
        {"review_action": "COMMENT", "summary": "s", "comments": [
            {"path": "requirements.txt", "perspective": "security",
             "severity": "CRITICAL", "title": "Vulnerable dep", "description": "d"}]},
        _r("APPROVE"),
    ])
    assert merged["review_action"] == "COMMENT", "must not fail open"
    assert "Findings without a line anchor" in merged["summary"]
    assert "Vulnerable dep" in merged["summary"]
    assert any("cannot be inline-anchored" in m for m in msgs)


def test_unanchorable_finding_counts_toward_the_totals():
    merged, _ = fold.merge([
        {"review_action": "COMMENT", "summary": "s", "comments": [
            {"path": "a.txt", "severity": "CRITICAL", "title": "t"}]},
    ])
    assert "1 finding(s)" in merged["summary"]
    assert "1 critical" in merged["summary"]


def test_comment_action_with_zero_comments_is_not_softened():
    """A batch that says COMMENT but emits no comments is self-contradicting;
    trust the non-clean verdict rather than reporting APPROVE."""
    merged, msgs = fold.merge([_r("COMMENT", comments=[])])
    assert merged["review_action"] == "COMMENT"
    assert "no usable findings" in merged["summary"]
    assert any("keeping the non-APPROVE verdict" in m for m in msgs)


def test_request_changes_survives_even_with_no_usable_comments():
    merged, _ = fold.merge([_r("REQUEST_CHANGES", comments=[])])
    assert merged["review_action"] == "REQUEST_CHANGES"


def test_genuinely_clean_review_still_approves():
    merged, msgs = fold.merge([_r("APPROVE"), _r("APPROVE")])
    assert merged["review_action"] == "APPROVE"
    assert "No findings" in merged["summary"]
    assert msgs == []


def test_non_dict_comment_entry_is_reported_not_swallowed():
    merged, msgs = fold.merge([{"review_action": "COMMENT", "summary": "s",
                                "comments": ["oops"]}])
    assert any("non-object" in m for m in msgs)
    assert merged["review_action"] == "COMMENT"  # still not softened
