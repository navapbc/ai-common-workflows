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
    merged = fold.merge([
        _r(comments=[_c("a.py", 1)]),
        _r(comments=[_c("b.py", 2)]),
    ])
    assert merged["review_action"] == "COMMENT"
    assert len(merged["comments"]) == 2


def test_all_batches_empty_yields_approve():
    merged = fold.merge([_r("APPROVE"), _r("APPROVE")])
    assert merged["review_action"] == "APPROVE"
    assert merged["comments"] == []


def test_dedup_by_path_line_perspective_keeps_higher_severity():
    merged = fold.merge([
        _r(comments=[_c("a.py", 1, severity="LOW")]),
        _r(comments=[_c("a.py", 1, severity="CRITICAL")]),
    ])
    assert len(merged["comments"]) == 1
    assert merged["comments"][0]["severity"] == "CRITICAL"


def test_same_line_different_perspective_both_kept():
    merged = fold.merge([
        _r(comments=[_c("a.py", 1, perspective="security")]),
        _r(comments=[_c("a.py", 1, perspective="compliance")]),
    ])
    assert len(merged["comments"]) == 2


def test_request_changes_is_not_softened():
    merged = fold.merge([
        _r("REQUEST_CHANGES", comments=[_c("a.py", 1)]),
        _r("APPROVE"),
    ])
    assert merged["review_action"] == "REQUEST_CHANGES"


def test_summary_reports_batch_count_and_counts():
    merged = fold.merge([
        _r(comments=[_c("a.py", 1, severity="CRITICAL")]),
        _r(comments=[_c("b.py", 2, severity="LOW")]),
    ])
    assert "2 diff batch(es)" in merged["summary"]
    assert "1 critical" in merged["summary"]
