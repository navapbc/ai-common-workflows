"""Tests for engines/_common/scm/github_payload.py — the review-JSON → GitHub API
payload transform. This is the highest-defect-density code in the engine
(idempotency de-dup, diff-position filtering, 422-avoidance), so it gets the
most exhaustive coverage."""

import importlib.util
import json
import os
import pathlib

_MODULE_PATH = (
    pathlib.Path(__file__).resolve().parents[2]
    / "engines" / "_common" / "scm" / "github_payload.py"
)
_spec = importlib.util.spec_from_file_location("github_payload", _MODULE_PATH)
gp = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(gp)


def _finding(path="src/app.py", line=3, perspective="security", severity="CRITICAL", **kw):
    base = {
        "path": path,
        "line": line,
        "side": "RIGHT",
        "perspective": perspective,
        "severity": severity,
        "title": "Some finding",
        "description": "Details.",
        "suggestion_kind": "applicable",
        "suggestion_body": "fixed = True",
    }
    base.update(kw)
    return base


def _review(action="COMMENT", comments=None):
    return {"review_action": action, "summary": "s", "comments": comments or []}


def _existing(path, line, perspective, ours=True):
    marker = "_Reviewed by AI, was this helpful?" if ours else "human note"
    body = f"{perspective}(high): title\n\n{marker}"
    return json.dumps({"path": path, "line": line, "body": body})


# ── render_body ──────────────────────────────────────────────────────────────

def test_render_body_applicable_uses_suggestion_fence():
    body = gp.render_body(_finding(suggestion_kind="applicable"))
    assert "```suggestion" in body
    assert body.rstrip().endswith("👎._")


def test_render_body_reference_uses_language_fence():
    body = gp.render_body(_finding(suggestion_kind="reference", suggestion_language="hcl"))
    assert "```hcl" in body
    assert "```suggestion" not in body


# ── patch parsing / diff positions ──────────────────────────────────────────

def test_parse_patch_added_and_context_lines():
    patch = "@@ -1,2 +1,3 @@\n context\n+added\n-removed\n context2"
    right, left = gp.parse_patch(patch)
    # new-side numbering: 1 context, 2 added, 3 context2
    assert right == {1, 2, 3}
    # old-side numbering: 1 context, 2 removed, 3 context2
    assert left == {1, 2, 3}


# ── build_payload: happy path ───────────────────────────────────────────────

def test_two_findings_in_diff_produce_two_inline_comments():
    files = json.dumps({"filename": "src/app.py", "patch": "@@ -1,1 +1,4 @@\n+a\n+b\n+c\n+d"})
    payload, _ = gp.build_payload(
        _review(comments=[_finding(line=3), _finding(line=4, perspective="compliance", severity="HIGH")]),
        "",
        files,
    )
    assert payload["event"] == "COMMENT"
    assert len(payload["comments"]) == 2
    assert gp.AI_ATTRIBUTION in payload["body"]


# ── idempotency: de-dup by (path, line, perspective) ────────────────────────

def test_suppresses_finding_already_anchored():
    existing = _existing("src/app.py", 3, "security")
    payload, msgs = gp.build_payload(_review(comments=[_finding(line=3)]), existing, "")
    # Only finding was already posted on an unchanged line → skip sentinel.
    assert payload is None
    assert any("Suppressed 1" in m for m in msgs)


def test_same_line_different_perspective_not_suppressed():
    existing = _existing("src/app.py", 3, "security")
    payload, _ = gp.build_payload(
        _review(comments=[_finding(line=3, perspective="compliance", severity="HIGH")]),
        existing,
        "",
    )
    assert payload is not None
    assert len(payload["comments"]) == 1


def test_outdated_comment_line_null_does_not_anchor():
    existing = json.dumps({"path": "src/app.py", "line": None,
                           "body": "security(high): t\n_Reviewed by AI, was this helpful?_"})
    payload, _ = gp.build_payload(_review(comments=[_finding(line=3)]), existing, "")
    assert payload is not None  # re-commented because old comment is outdated


def test_human_comment_does_not_anchor():
    existing = _existing("src/app.py", 3, "security", ours=False)
    payload, _ = gp.build_payload(_review(comments=[_finding(line=3)]), existing, "")
    assert payload is not None  # not one of ours → not an anchor


# ── diff-position filtering ─────────────────────────────────────────────────

def test_finding_outside_diff_moved_to_body():
    files = json.dumps({"filename": "src/app.py", "patch": "@@ -1,1 +1,1 @@\n+only_line_1"})
    payload, msgs = gp.build_payload(_review(comments=[_finding(line=999)]), "", files)
    assert payload["comments"] == []          # not inline (would 422)
    assert "outside the diff" in payload["body"]
    assert any("outside the PR diff" in m for m in msgs)


def test_no_diff_info_disables_filtering():
    # have_diff is False → findings are trusted as-is (body-only fallback in gh.sh guards the post).
    payload, _ = gp.build_payload(_review(comments=[_finding(line=999)]), "", "")
    assert len(payload["comments"]) == 1


# ── malformed input tolerance ───────────────────────────────────────────────

def test_unanchorable_comment_moved_to_body_not_dropped():
    """A finding missing the fields needed to anchor an inline comment must
    still reach the PR. Dropping it makes a real finding invisible."""
    bad = {"path": "x", "line": 1, "severity": "CRITICAL", "title": "Vulnerable dep"}
    payload, msgs = gp.build_payload(_review(comments=[bad]), "", "")
    assert payload is not None, "a finding must never be silently dropped"
    assert payload["comments"] == []  # cannot be inline-anchored
    assert "Findings without a line anchor" in payload["body"]
    assert "Vulnerable dep" in payload["body"]
    assert any("moving it into the review body" in m for m in msgs)


def test_finding_with_no_line_still_reaches_the_body():
    bad = {"path": "requirements.txt", "perspective": "security",
           "severity": "CRITICAL", "title": "CVE-2024-x", "description": "d"}
    payload, _ = gp.build_payload(_review(comments=[bad]), "", "")
    assert payload is not None
    assert "requirements.txt" in payload["body"]


def test_non_dict_comment_entry_ignored():
    payload, msgs = gp.build_payload(_review(comments=["oops"]), "", "")
    assert payload is None  # nothing postable at all
    assert any("non-object" in m for m in msgs)


def test_skip_message_does_not_claim_already_posted_when_nothing_was():
    """The 'already posted on unchanged lines' explanation must only appear
    when findings were actually suppressed by an existing comment."""
    _, msgs = gp.build_payload(_review(action="COMMENT", comments=[]), "", "")
    joined = " ".join(msgs)
    assert "already posted" not in joined
    assert "no postable findings" in joined


def test_skip_message_says_already_posted_when_suppressed():
    existing = _existing("src/app.py", 3, "security")
    _, msgs = gp.build_payload(_review(comments=[_finding(line=3)]), existing, "")
    assert any("already posted on unchanged lines" in m for m in msgs)


def test_malformed_existing_comment_ndjson_ignored():
    existing = "not json\n" + _existing("src/app.py", 3, "security")
    payload, _ = gp.build_payload(_review(comments=[_finding(line=3)]), existing, "")
    assert payload is None  # the valid anchor still suppresses


# ── skip sentinel ───────────────────────────────────────────────────────────

def test_comment_action_with_nothing_new_returns_skip():
    payload, _ = gp.build_payload(_review(action="COMMENT", comments=[]), "", "")
    assert payload is None


def test_approve_with_no_comments_still_posts():
    payload, _ = gp.build_payload(_review(action="APPROVE", comments=[]), "", "")
    assert payload is not None
    assert payload["event"] == "APPROVE"
