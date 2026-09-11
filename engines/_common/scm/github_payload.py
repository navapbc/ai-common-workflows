"""Build the GitHub review-API payload from the AI's review JSON.

Invoked by engines/_common/scm/github.sh as:

    python3 github_payload.py < review.json

Inputs:
    stdin                        the AI's review JSON block (one object)
    AI_REVIEW_EXISTING_COMMENTS  NDJSON, one {path, line, body} per line —
                                 the AI reviewer's existing inline comments
                                 on the PR (idempotency anchors)
    AI_REVIEW_PR_FILES           NDJSON, one {filename, patch} per line —
                                 the PR's per-file patches (diff positions)

Output (stdout):
    Either the JSON payload for POST /repos/{o}/{r}/pulls/{n}/reviews, or
    the literal sentinel line __AI_REVIEW_SKIP_POST__ when everything in the
    review has already been posted and nothing new remains.

Status/diagnostic lines go to stderr only.
"""

import json
import os
import re
import sys


ATTRIBUTION_MARKER = "Reviewed by AI"
AI_ATTRIBUTION = (
    "_Reviewed by AI, was this helpful? Please react with "
    "\U0001F44D or \U0001F44E._"
)
SKIP_SENTINEL = "__AI_REVIEW_SKIP_POST__"


def perspective_of(body):
    """Extract the perspective label from a rendered comment's first line."""
    lines = (body or "").strip().splitlines()
    first = lines[0] if lines else ""
    m = re.match(r"\s*(security|compliance)\s*\(", first, re.I)
    return m.group(1).lower() if m else None


def anchored_keys(existing_comments_ndjson):
    """Build the set of (path, line, perspective) that already carry a live
    AI comment.

    An existing comment is a de-dup anchor only if (a) it is one of ours
    (carries the attribution marker) and (b) GitHub still positions it on the
    current diff (line is not null). When a line or its hunk changes, GitHub
    outdates the comment (line -> null), so it stops anchoring and we
    re-comment automatically. Titles are intentionally NOT in the key — runs
    are non-deterministic and reword titles for the same issue.
    """
    anchored = set()
    for raw in existing_comments_ndjson.splitlines():
        raw = raw.strip()
        if not raw:
            continue
        try:
            ec = json.loads(raw)
        except Exception:
            continue
        body = ec.get("body") or ""
        if ATTRIBUTION_MARKER not in body:  # not one of ours
            continue
        ln = ec.get("line")
        if ln is None:  # outdated → line changed → re-comment
            continue
        anchored.add((ec.get("path"), ln, perspective_of(body)))
    return anchored


def render_body(c):
    """Render one comment body in Conventional Comments + suggestion format."""
    perspective = c.get("perspective", "security")
    severity = c.get("severity", "LOW").upper()
    sev_lc = severity.lower()
    title = c.get("title", "Finding")
    description = c.get("description", "")
    kind = c.get("suggestion_kind", "reference")
    body = c.get("suggestion_body", "")
    if kind == "applicable":
        fence = "suggestion"
    else:
        fence = c.get("suggestion_language", "")
    return (
        f"{perspective}({sev_lc}): {title}\n\n"
        f"Description: {description}\n\n"
        f"Severity: {severity}\n\n"
        f"Suggestion:\n\n"
        f"```{fence}\n{body}\n```\n\n"
        f"{AI_ATTRIBUTION}\n"
    )


def parse_patch(patch):
    """Parse a unified patch into (RIGHT-side line set, LEFT-side line set)."""
    right, left = set(), set()
    new_ln = old_ln = None
    for pl in patch.split("\n"):
        if pl.startswith("@@"):
            m = re.match(r"@@ -(\d+)(?:,\d+)? \+(\d+)(?:,\d+)? @@", pl)
            if m:
                old_ln = int(m.group(1))
                new_ln = int(m.group(2))
            continue
        if new_ln is None:
            continue
        if pl.startswith("+"):
            right.add(new_ln)
            new_ln += 1
        elif pl.startswith("-"):
            left.add(old_ln)
            old_ln += 1
        elif pl.startswith(" "):
            right.add(new_ln)
            left.add(old_ln)
            new_ln += 1
            old_ln += 1
    return right, left


def diff_positions(pr_files_ndjson):
    """Build per-file commentable line sets from the PR's file patches.

    GitHub rejects the ENTIRE review (HTTP 422) if any inline comment lands on
    a line that is not part of the diff, so findings outside these sets get
    moved into the review body instead. Returns (right_lines, left_lines,
    have_diff); when have_diff is False no diff info was available and
    filtering is skipped (the body-only POST fallback in github.sh still
    protects the run).
    """
    right_lines, left_lines = {}, {}
    have_diff = False
    for raw in pr_files_ndjson.splitlines():
        raw = raw.strip()
        if not raw:
            continue
        try:
            pf = json.loads(raw)
        except Exception:
            continue
        fn = pf.get("filename")
        patch = pf.get("patch")
        if not fn or not patch:
            continue
        have_diff = True
        r, l = parse_patch(patch)
        right_lines.setdefault(fn, set()).update(r)
        left_lines.setdefault(fn, set()).update(l)
    return right_lines, left_lines, have_diff


def build_payload(data, existing_comments_ndjson, pr_files_ndjson):
    """Transform the AI review JSON into the GitHub API payload (or the skip
    sentinel). Returns (payload_dict_or_None, messages) where messages are
    diagnostics for stderr."""
    messages = []
    action = data.get("review_action", "COMMENT")
    summary = data.get("summary", "AI-assisted PR review (security + compliance).")
    comments_in = data.get("comments", [])

    anchored = anchored_keys(existing_comments_ndjson)
    right_lines, left_lines, have_diff = diff_positions(pr_files_ndjson)

    def in_diff(path, line, side):
        if not have_diff:
            return True  # no diff info available → do not filter
        if side == "LEFT":
            return line in left_lines.get(path, set())
        return line in right_lines.get(path, set())

    # Append the attribution as the final line of the top-level review body.
    # Guard against duplication if the AI already included it in the summary.
    if AI_ATTRIBUTION not in summary:
        summary = summary.rstrip() + "\n\n" + AI_ATTRIBUTION

    comments_out = []
    suppressed = 0
    out_of_diff = []
    unanchorable = []
    for c in comments_in:
        if not isinstance(c, dict):
            messages.append(f"WARN: ignoring non-object entry in comments: {c!r}")
            continue
        missing = [
            k for k in ("path", "line", "perspective", "severity", "title", "description")
            if c.get(k) is None
        ]
        if missing:
            # Cannot be inline-anchored, but it IS a finding. Surface it in the
            # review body rather than dropping it — a dropped finding is
            # invisible to the PR author and to anyone reading the review.
            messages.append(
                f"WARN: finding missing {'/'.join(missing)}; moving it into the "
                f"review body instead of dropping it: {c!r}"
            )
            unanchorable.append(c)
            continue
        key = (c["path"], c["line"], (c.get("perspective") or "security").lower())
        if key in anchored:
            suppressed += 1
            continue
        side = c.get("side", "RIGHT")
        if not in_diff(c["path"], c["line"], side):
            out_of_diff.append(c)
            continue
        comments_out.append({
            "path": c["path"],
            "line": c["line"],
            "side": side,
            "body": render_body(c),
        })

    if suppressed:
        messages.append(
            f"[pr-review] Suppressed {suppressed} finding(s) already posted on unchanged lines."
        )

    # Findings that cannot be inline-anchored — either their line is not in the
    # diff (GitHub would 422 the whole review) or they are missing the fields
    # needed to anchor them. Surface both in the review body instead.
    def _md(c, with_line=True):
        persp = (c.get("perspective") or "security").lower()
        sev = str(c.get("severity", "LOW")).lower()
        loc = c.get("path") or "(no path)"
        if with_line and c.get("line") is not None:
            loc = f"{loc}:{c.get('line')}"
        return f"- **{persp}({sev})** `{loc}` - {c.get('title', 'Finding')}"

    if out_of_diff:
        messages.append(
            f"[pr-review] {len(out_of_diff)} finding(s) reference lines outside the "
            f"PR diff; moving them into the review body."
        )
        summary = (
            summary.rstrip()
            + "\n\n---\n\n#### Findings outside the diff (not inline-anchored)\n\n"
            + "\n".join(_md(c) for c in out_of_diff)
        )

    if unanchorable:
        messages.append(
            f"[pr-review] {len(unanchorable)} finding(s) lack the fields needed to "
            f"anchor an inline comment; moving them into the review body."
        )
        summary = (
            summary.rstrip()
            + "\n\n---\n\n#### Findings without a line anchor\n\n"
            + "\n".join(_md(c) for c in unanchorable)
        )

    # If there is genuinely nothing new to post — everything already commented
    # on unchanged lines, and nothing was moved to the body — skip the redundant
    # empty COMMENT review. APPROVE is left alone: it carries no inline comments
    # and re-approving is harmless.
    if action == "COMMENT" and not comments_out and not out_of_diff and not unanchorable:
        if suppressed:
            messages.append(
                "[pr-review] All findings already posted on unchanged lines; nothing new to comment."
            )
        else:
            # Don't claim findings were "already posted" when there were none
            # to post — that sends an operator looking for comments that never
            # existed.
            messages.append(
                "[pr-review] The review reported COMMENT but carried no postable "
                "findings; nothing to post."
            )
        return None, messages

    payload = {
        "event": action if action in ("APPROVE", "COMMENT", "REQUEST_CHANGES") else "COMMENT",
        "body": summary,
        "comments": comments_out,
    }
    return payload, messages


def main():
    try:
        data = json.load(sys.stdin)
    except Exception as e:
        print(f"ERROR: could not parse review JSON from AI output: {e}", file=sys.stderr)
        sys.exit(1)

    payload, messages = build_payload(
        data,
        os.environ.get("AI_REVIEW_EXISTING_COMMENTS", ""),
        os.environ.get("AI_REVIEW_PR_FILES", ""),
    )
    for m in messages:
        print(m, file=sys.stderr)
    if payload is None:
        print(SKIP_SENTINEL)
        sys.exit(0)
    print(json.dumps(payload))


if __name__ == "__main__":
    main()
