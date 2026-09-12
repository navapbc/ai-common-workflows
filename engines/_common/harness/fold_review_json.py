"""Merge per-batch AI review JSON blocks into one review.

Invoked by engines/security-compliance-review/harness/ai-security-compliance-review after a fan-out run as:

    python3 fold_review_json.py batch1.json batch2.json ... > merged.json

Each input file holds one review JSON object (the block a worker extracted
from its AI response). The merged output has the same schema:

  - comments: concatenation of all batches' comments, de-duplicated by
    (path, line, perspective). When two batches flag the same location from
    the same perspective, the higher-severity finding wins (ties keep the
    first seen), so overlapping batch boundaries can only make the review
    stricter, never quieter.
  - review_action: the worst action any batch reported, never softened.
    REQUEST_CHANGES passes through if any batch emitted it (the AI is
    instructed never to, but worst-of folding must not soften it).
  - summary: recomputed from the merged findings.

**Folding must never fail open.** The fan-out path derives the gate verdict
from this merged JSON (not from the per-batch result markers), so anything
dropped here is invisible to the gate. Two rules follow:

  - A finding that cannot be inline-anchored (missing path/line) is NOT
    silently discarded — it is reported on stderr and listed in the summary
    so it reaches the PR body, and it still counts as a finding.
  - review_action is only APPROVE when every batch said APPROVE *and*
    nothing was dropped. A batch that reported findings keeps its action even
    if none of its comments survived anchoring.

Unreadable or malformed input files are fatal (exit 1): a missing batch means
part of the diff went unreviewed, and reporting a partial review as complete
would be a silent coverage gap.
"""

import json
import sys

SEVERITY_RANK = {"CRITICAL": 4, "HIGH": 3, "MEDIUM": 2, "LOW": 1}
ACTION_RANK = {"REQUEST_CHANGES": 3, "COMMENT": 2, "APPROVE": 1}

# Fields required to anchor a finding as an inline comment.
ANCHOR_FIELDS = ("path", "line")


def _describe(c):
    """One-line human description of a finding that could not be anchored."""
    persp = str((c.get("perspective") or "security")).lower()
    sev = str(c.get("severity", "LOW")).upper()
    title = c.get("title", "Finding")
    where = c.get("path") or "(no path)"
    line = c.get("line")
    loc = f"{where}:{line}" if line is not None else where
    return f"{persp}({sev.lower()}) {loc} - {title}"


def merge(reviews):
    """Merge review JSON objects; returns (merged_dict, messages).

    messages are diagnostics for stderr — never silently swallowed.
    """
    messages = []
    by_key = {}
    order = []
    worst_action = "APPROVE"
    unanchorable = []

    for review in reviews:
        action = review.get("review_action", "COMMENT")
        if ACTION_RANK.get(action, 2) > ACTION_RANK[worst_action]:
            worst_action = action
        for c in review.get("comments", []):
            if not isinstance(c, dict):
                messages.append(f"WARN: ignoring non-object entry in comments: {c!r}")
                continue
            if any(c.get(k) is None for k in ANCHOR_FIELDS):
                # Cannot be inline-anchored, but it IS a finding: keep it
                # visible and let it carry weight in the verdict.
                unanchorable.append(c)
                messages.append(
                    "WARN: finding cannot be inline-anchored (missing "
                    f"{'/'.join(k for k in ANCHOR_FIELDS if c.get(k) is None)}); "
                    f"surfacing it in the review body: {_describe(c)}"
                )
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
    for c in comments + unanchorable:
        sev = str(c.get("severity", "LOW")).upper()
        if sev in counts:
            counts[sev] += 1

    total = len(comments) + len(unanchorable)

    # Never soften: APPROVE requires every batch to have said APPROVE AND
    # nothing to have been found or dropped. A batch that reported findings
    # keeps its action even if none of its comments could be anchored.
    if total or worst_action != "APPROVE":
        action = worst_action if worst_action != "APPROVE" else "COMMENT"
    else:
        action = "APPROVE"

    if total:
        summary = (
            "AI-assisted PR review (security + compliance), run across "
            f"{len(reviews)} diff batch(es). Found {total} finding(s) "
            f"({counts['CRITICAL']} critical, {counts['HIGH']} high, "
            f"{counts['MEDIUM']} medium, {counts['LOW']} low). "
            "See inline comments for details and suggested fixes."
        )
    elif action != "APPROVE":
        # A batch reported findings but emitted no usable comment objects.
        # Say so plainly rather than claiming a clean review.
        summary = (
            "AI-assisted PR review (security + compliance), run across "
            f"{len(reviews)} diff batch(es). At least one batch reported "
            f"'{worst_action}' but emitted no usable findings — treating the "
            "review as non-clean. Check the job log for the batch reports."
        )
        messages.append(
            f"WARN: a batch reported '{worst_action}' with no usable comment "
            "objects; keeping the non-APPROVE verdict rather than folding to APPROVE."
        )
    else:
        summary = (
            "AI-assisted PR review (security + compliance), run across "
            f"{len(reviews)} diff batch(es). No findings."
        )

    # Findings that cannot be inline-anchored go into the review body, so they
    # are never lost between the model and the PR.
    if unanchorable:
        summary = (
            summary.rstrip()
            + "\n\n---\n\n#### Findings without a line anchor\n\n"
            + "\n".join(f"- {_describe(c)}" for c in unanchorable)
        )

    return {"review_action": action, "summary": summary, "comments": comments}, messages


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
    merged, messages = merge(reviews)
    for m in messages:
        print(m, file=sys.stderr)
    print(json.dumps(merged))


if __name__ == "__main__":
    main(sys.argv[1:])
