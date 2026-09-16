"""Tests for engines/_common/harness/gate_verdict.py — the single decision on
whether a review result fails the build. Four call sites depend on it (the
composite action's gate step, the security-review entrypoint's --gate, the
sandbox wrapper, and the Jenkins plugin by way of review_action), so every
fail-open path here is a gate that silently stops gating."""

import importlib.util
import json
import pathlib

_MODULE_PATH = (
    pathlib.Path(__file__).resolve().parents[2]
    / "engines" / "_common" / "harness" / "gate_verdict.py"
)
_spec = importlib.util.spec_from_file_location("gate_verdict", _MODULE_PATH)
gv = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(gv)


def _findings(*severities, action="COMMENT"):
    return {
        "review_action": action,
        "comments": [
            {"severity": s, "title": f"finding {s}"} for s in severities
        ],
    }


def _verdict(*severities, action="COMMENT"):
    return gv.evaluate(_findings(*severities, action=action))[1]


# ── the floor ───────────────────────────────────────────────────────────────

def test_approve_passes():
    assert _verdict(action="APPROVE") == "PASS"


def test_low_only_passes():
    assert _verdict("LOW") == "PASS"


def test_medium_only_passes():
    assert _verdict("MEDIUM", "LOW") == "PASS"


def test_high_blocks():
    assert _verdict("HIGH") == "BLOCK"


def test_critical_blocks():
    assert _verdict("CRITICAL") == "BLOCK"


def test_high_among_low_blocks():
    assert _verdict("LOW", "MEDIUM", "HIGH") == "BLOCK"


def test_severity_matching_is_case_insensitive():
    assert _verdict("critical") == "BLOCK"
    assert _verdict("low") == "PASS"


def test_severity_is_stripped_before_matching():
    assert _verdict("  HIGH  ") == "BLOCK"


# ── never fail open ─────────────────────────────────────────────────────────

def test_unrecognized_severity_blocks_and_is_reported():
    action, verdict, _, unknown, blocking = gv.evaluate(_findings("SEV_BANANA"))
    assert verdict == "BLOCK"
    assert unknown == ["SEV_BANANA"]
    assert blocking == ["finding SEV_BANANA"]


def test_missing_severity_blocks():
    data = {"review_action": "COMMENT", "comments": [{"title": "no severity"}]}
    _, verdict, _, unknown, _ = gv.evaluate(data)
    assert verdict == "BLOCK"
    assert unknown == ["<missing>"]


def test_request_changes_blocks_without_consulting_severities():
    # A verdict from elsewhere is honored, not re-derived: the AI never emits
    # REQUEST_CHANGES, so if one appears something upstream decided it.
    _, verdict, reason, _, _ = gv.evaluate(_findings("LOW", action="REQUEST_CHANGES"))
    assert verdict == "BLOCK"
    assert "REQUEST_CHANGES" in reason


def test_unrecognized_review_action_raises():
    try:
        gv.evaluate({"review_action": "LGTM"})
    except ValueError as exc:
        assert "LGTM" in str(exc)
    else:
        raise AssertionError("an unrecognized review_action must not be tolerated")


def test_missing_review_action_raises():
    try:
        gv.evaluate({"comments": []})
    except ValueError:
        pass
    else:
        raise AssertionError("a missing review_action must not be tolerated")


def test_comments_not_a_list_raises():
    try:
        gv.evaluate({"review_action": "COMMENT", "comments": "oops"})
    except ValueError:
        pass
    else:
        raise AssertionError("a non-list comments value must not be tolerated")


def test_comment_entry_not_an_object_raises():
    try:
        gv.evaluate({"review_action": "COMMENT", "comments": ["oops"]})
    except ValueError:
        pass
    else:
        raise AssertionError("a non-object comment entry must not be tolerated")


def test_comment_bearing_result_with_no_comments_passes():
    # COMMENT with an empty array is odd but not blocking on its own; the
    # engine's own summary covers it.
    assert gv.evaluate({"review_action": "COMMENT"})[1] == "PASS"
    assert gv.evaluate({"review_action": "COMMENT", "comments": []})[1] == "PASS"


# ── the CLI contract the shell callers parse ────────────────────────────────

def test_main_emits_action_verdict_and_reason(tmp_path, capsys):
    p = tmp_path / "f.json"
    p.write_text(json.dumps(_findings("HIGH")))
    assert gv.main(["gate_verdict.py", str(p)]) == 0
    lines = capsys.readouterr().out.strip().split("\n")
    assert lines[0] == "ACTION\tCOMMENT"
    assert lines[1] == "VERDICT\tBLOCK"
    assert lines[2].startswith("REASON\t")
    assert "BLOCK\tfinding HIGH" in lines


def test_main_exit_2_on_missing_file(tmp_path, capsys):
    assert gv.main(["gate_verdict.py", str(tmp_path / "nope.json")]) == 2
    capsys.readouterr()


def test_main_exit_2_on_unparseable_json(tmp_path, capsys):
    p = tmp_path / "f.json"
    p.write_text("{not json")
    assert gv.main(["gate_verdict.py", str(p)]) == 2
    capsys.readouterr()


def test_main_exit_2_when_top_level_is_not_an_object(tmp_path, capsys):
    p = tmp_path / "f.json"
    p.write_text("[]")
    assert gv.main(["gate_verdict.py", str(p)]) == 2
    capsys.readouterr()


def test_main_exit_2_on_bad_arg_count(capsys):
    assert gv.main(["gate_verdict.py"]) == 2
    capsys.readouterr()


def test_unknown_lines_precede_block_lines(tmp_path, capsys):
    p = tmp_path / "f.json"
    p.write_text(json.dumps(_findings("SEV_X", "HIGH")))
    assert gv.main(["gate_verdict.py", str(p)]) == 0
    out = capsys.readouterr().out
    assert out.index("UNKNOWN\t") < out.index("BLOCK\t")
