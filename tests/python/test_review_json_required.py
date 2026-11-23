"""A review verdict is usable only when the AI supplies findings JSON."""

import json
import os
from pathlib import Path
import subprocess


ROOT = Path(__file__).resolve().parents[2]
ENGINE = ROOT / "engines/security-compliance-review/harness/ai-security-compliance-review"
STUBS = ROOT / "tests/stubs"
FIXTURES = ROOT / "tests/fixtures"


def _review(tmp_path, response_file):
    repo = tmp_path / "repo"
    repo.mkdir()

    def git(*args):
        subprocess.run(["git", *args], cwd=repo, check=True, capture_output=True)

    git("init", "-q")
    git("config", "user.email", "review-test@example.invalid")
    git("config", "user.name", "Review Test")
    source = repo / "app.py"
    source.write_text("print('before')\n")
    git("add", "app.py")
    git("commit", "-qm", "base")
    source.write_text("print('after')\n")
    git("commit", "-qam", "change")

    env = os.environ.copy()
    for key in ("GITHUB_TOKEN", "GH_TOKEN", "AI_REVIEW_PROVIDER", "AI_REVIEW_MODEL"):
        env.pop(key, None)
    env.update(
        PATH=f"{STUBS}{os.pathsep}{env['PATH']}",
        AI_REVIEW_TOOL="claude",
        AI_REVIEW_PROFILE="base",
        ANTHROPIC_API_KEY="test",
        STUB_RESPONSE_FILE=str(response_file),
        CI="true",
        NO_COLOR="1",
    )
    return subprocess.run(
        ["bash", str(ENGINE), "--against", "HEAD~1", "--json-only", "--gate",
         "--no-adjudicate", "--jobs", "1"],
        cwd=repo, env=env, capture_output=True, text=True,
    )


def test_approve_marker_without_json_fails(tmp_path):
    response = tmp_path / "approve-without-json.txt"
    response.write_text("No findings.\n<<<AI_REVIEW_RESULT:APPROVE>>>\n")

    review = _review(tmp_path, response)

    assert review.returncode == 1, review.stderr
    assert not review.stdout.strip()
    assert "did not contain a parseable JSON block" in review.stderr


def test_comment_marker_without_json_fails(tmp_path):
    response = tmp_path / "comment-without-json.txt"
    response.write_text("Findings detected.\n<<<AI_REVIEW_RESULT:COMMENT>>>\n")

    review = _review(tmp_path, response)

    assert review.returncode == 1, review.stderr
    assert not review.stdout.strip()
    assert "did not contain a parseable JSON block" in review.stderr


def test_malformed_json_block_fails(tmp_path):
    response = tmp_path / "malformed-json.txt"
    response.write_text(
        "<!-- AI_REVIEW_JSON_BEGIN -->\n"
        '{"review_action": "APPROVE", "comments": [}\n'
        "<!-- AI_REVIEW_JSON_END -->\n"
        "<<<AI_REVIEW_RESULT:APPROVE>>>\n"
    )

    review = _review(tmp_path, response)

    assert review.returncode == 1, review.stderr
    assert not review.stdout.strip()
    assert "did not contain a parseable JSON block" in review.stderr


def test_approve_fixture_with_json_passes(tmp_path):
    review = _review(tmp_path, FIXTURES / "response-approve.txt")

    assert review.returncode == 0, review.stderr
    findings = json.loads(review.stdout)
    assert findings["review_action"] == "APPROVE"
    assert findings["comments"] == []
