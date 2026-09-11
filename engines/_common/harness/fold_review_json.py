"""Merge per-batch AI review JSON blocks into one review.

Invoked by engines/security-compliance-review/harness/ai-pr-review after a fan-out run as:

    python3 fold_review_json.py batch1.json batch2.json ... > merged.json

Each input file holds one review JSON object (the block a worker extracted
from its AI response). The merged output has the same schema:

  - comments: concatenation of all batches' comments, de-duplicated by
    (path, line, perspective). When two batches flag the same location from
    the same perspective, the higher-severity finding wins (ties keep the
    first seen), so overlapping batch boundaries can only make the review
    stricter, never quieter.
  - review_action: COMMENT if any comments survive, else APPROVE.
    REQUEST_CHANGES passes through if any batch emitted it (the AI is
    instructed never to, but worst-of folding must not soften it).
  - summary: recomputed from the merged findings.

Unreadable or malformed input files are fatal (exit 1): a missing batch means
part of the diff went unreviewed, and reporting a partial review as complete
would be a silent coverage gap.
"""

import json
import sys

SEVERITY_RANK = {"CRITICAL": 4, "HIGH": 3, "MEDIUM": 2, "LOW": 1}
ACTION_RANK = {"REQUEST_CHANGES": 3, "COMMENT": 2, "APPROVE": 1}


def merge(reviews):
    """Merge review JSON objects; returns the merged dict."""
    by_key = {}
    order = []
    worst_action = "APPROVE"
    for review in reviews:
        action = review.get("review_action", "COMMENT")
        if ACTION_RANK.get(action, 2) > ACTION_RANK[worst_action]:
            worst_action = action
        for c in review.get("comments", []):
            if not isinstance(c, dict) or "path" not in c or "line" not in c:
                continue
            key = (c["path"], c["line"], (c.get("perspective") or "security").lower())
            if key not in by_key:
                by_key[key] = c
                order.append(key)
            else:
                held = SEVERITY_RANK.get(str(by_key[key].get("severity", "LOW")).upper(), 1)
                new = SEVERITY_RANK.get(str(c.get("severity", "LOW")).upper(), 1)
                if new > held:
                    by_key[key] = c

    comments = [by_key[k] for k in order]

    counts = {"CRITICAL": 0, "HIGH": 0, "MEDIUM": 0, "LOW": 0}
    for c in comments:
        sev = str(c.get("severity", "LOW")).upper()
        if sev in counts:
            counts[sev] += 1

    if comments:
        action = worst_action if worst_action != "APPROVE" else "COMMENT"
        summary = (
            "AI-assisted PR review (security + compliance), run across "
            f"{len(reviews)} diff batch(es). Found {len(comments)} finding(s) "
            f"({counts['CRITICAL']} critical, {counts['HIGH']} high, "
            f"{counts['MEDIUM']} medium, {counts['LOW']} low). "
            "See inline comments for details and suggested fixes."
        )
    else:
        action = "APPROVE"
        summary = (
            "AI-assisted PR review (security + compliance), run across "
            f"{len(reviews)} diff batch(es). No findings."
        )

    return {"review_action": action, "summary": summary, "comments": comments}


def main(paths):
    if not paths:
        print("ERROR: fold_review_json.py requires at least one input file", file=sys.stderr)
        sys.exit(1)
    reviews = []
    for p in paths:
        try:
            with open(p, encoding="utf-8") as f:
                reviews.append(json.load(f))
        except Exception as e:
            print(f"ERROR: could not read batch review JSON {p}: {e}", file=sys.stderr)
            sys.exit(1)
    print(json.dumps(merge(reviews)))


if __name__ == "__main__":
    main(sys.argv[1:])
