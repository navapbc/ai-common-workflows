"""Validate model verdicts and independent-adjudication finding boundaries."""

import json
import sys
from collections import defaultdict


SEVERITY_RANK = {"LOW": 1, "MEDIUM": 2, "HIGH": 3, "CRITICAL": 4}
MARKER_ACTION = {
    "review": {"APPROVE": "APPROVE", "COMMENT": "COMMENT"},
    "audit": {"AUDIT_CLEAN": "APPROVE", "AUDIT_FINDINGS": "COMMENT"},
}


def validate_contract(review, kind, marker):
    if not isinstance(review, dict):
        raise ValueError("JSON must be an object")
    if marker not in MARKER_ACTION[kind]:
        raise ValueError(f"{marker} is not an allowed {kind} model marker")
    action = review.get("review_action")
    comments = review.get("comments")
    if action != MARKER_ACTION[kind][marker]:
        raise ValueError("marker does not match review_action")
    if not isinstance(comments, list) or not all(isinstance(c, dict) for c in comments):
        raise ValueError("comments must be an array of findings")
    if (action == "APPROVE" and comments) or (action == "COMMENT" and not comments):
        raise ValueError("review_action does not match findings cardinality")


def validate_adjudication(first, revised):
    originals = defaultdict(list)
    remaining = defaultdict(list)
    for finding in first["comments"]:
        identity = json.dumps(
            {key: value for key, value in finding.items() if key != "severity"},
            sort_keys=True,
        )
        rank = SEVERITY_RANK.get(finding.get("severity"))
        if rank is None:
            raise ValueError("first-pass finding has no recognized severity")
        originals[identity].append(rank)

    for finding in revised["comments"]:
        identity = json.dumps(
            {key: value for key, value in finding.items() if key != "severity"},
            sort_keys=True,
        )
        rank = SEVERITY_RANK.get(finding.get("severity"))
        if rank is None:
            raise ValueError("adjudicated finding has no recognized severity")
        if identity not in originals:
            raise ValueError("adjudication introduced or changed a finding")
        remaining[identity].append(rank)

    for identity, ranks in remaining.items():
        original_ranks = sorted(originals[identity], reverse=True)
        revised_ranks = sorted(ranks, reverse=True)
        if len(revised_ranks) > len(original_ranks):
            raise ValueError("adjudication duplicated a finding")
        if any(new > old for new, old in zip(revised_ranks, original_ranks)):
            raise ValueError("adjudication raised a finding's severity")


def main(args):
    try:
        if len(args) == 2 and args[0] in MARKER_ACTION:
            validate_contract(json.load(sys.stdin), args[0], args[1])
        elif args == ["adjudication"]:
            first, revised = json.load(sys.stdin)
            validate_adjudication(first, revised)
        else:
            raise ValueError("expected review|audit <marker> or adjudication")
    except (ValueError, TypeError, KeyError) as exc:
        print(f"Review contract violation: {exc}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
