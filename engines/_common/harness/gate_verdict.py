"""Decide whether a review result should fail the build.

Invoked with the engine's findings JSON, as a file or on stdin:

    python3 gate_verdict.py review.json
    printf '%s' "${json}" | python3 gate_verdict.py -

This is the single implementation of "does this review block". Before it there
were four: the composite action's gate step, the security-review entrypoint,
the sandbox wrapper, and (by reading `review_action` itself) the Jenkins
plugin. Three of those compared `review_action != "APPROVE"`, which blocks on a
single LOW finding, because the AI emits a finding-bearing result for any
finding at all. Keeping the comparison in one place is what lets the gate mean
the same thing however the engine was launched.

Output on stdout, one record per line, tab-separated:

    ACTION\tAPPROVE|COMMENT|REQUEST_CHANGES
    VERDICT\tBLOCK|PASS
    REASON\t<short phrase for a log line>
    UNKNOWN\t<severity as it appeared, or <missing>>   (zero or more)
    BLOCK\t<finding title>                             (zero or more)

Exit status:

    0  evaluated; read VERDICT
    2  the file is missing, unreadable, or malformed

**This must never fail open.** A caller that sees exit 2 has to fail the build,
not assume PASS — an unparseable findings file is an engine malfunction, and
treating it as "nothing to report" would silently disable the gate. The same
rule is why an unrecognized severity counts as blocking below rather than being
read as LOW: a finding nobody can classify is not a finding anybody should be
allowed to merge past unseen.

The gate floor is HIGH, deliberately not configurable. Gating on everything
fails merges on nits, and no consumer has needed a different line; if one ever
does, that belongs in a separately named input rather than as a second kind of
value in `gate`.
"""

import json
import sys

# Severity ladder shared with the review skill's output contract.
RANK = {"LOW": 1, "MEDIUM": 2, "HIGH": 3, "CRITICAL": 4}

# Findings at or above this rank fail the build when gating is on.
FLOOR = RANK["HIGH"]

# Verdicts the AI may emit. REQUEST_CHANGES is never produced by the AI (the
# skill forbids it), but if a dispatcher or a future engine emits one it is a
# verdict in its own right and is honored rather than re-derived from
# severities.
ACTIONS = ("APPROVE", "COMMENT", "REQUEST_CHANGES")


def evaluate(data):
    """Return (action, verdict, reason, unknown, blocking) for one findings object."""
    action = data.get("review_action")
    if action not in ACTIONS:
        raise ValueError(f"unrecognized review_action: {action!r}")

    if action == "APPROVE":
        return action, "PASS", "no findings", [], []
    if action == "REQUEST_CHANGES":
        return action, "BLOCK", "review_action is REQUEST_CHANGES", [], []

    comments = data.get("comments") or []
    if not isinstance(comments, list):
        raise ValueError("comments is not a list")

    unknown, blocking = [], []
    for c in comments:
        if not isinstance(c, dict):
            raise ValueError("comment entry is not an object")
        raw = str(c.get("severity", "")).strip().upper()
        rank = RANK.get(raw)
        title = c.get("title", "untitled")
        if rank is None:
            unknown.append(raw or "<missing>")
            blocking.append(title)
        elif rank >= FLOOR:
            blocking.append(title)

    if blocking:
        return action, "BLOCK", f"{len(blocking)} HIGH or CRITICAL finding(s)", unknown, blocking
    return action, "PASS", "nothing is HIGH or CRITICAL", unknown, blocking


def main(argv):
    if len(argv) != 2:
        print("usage: gate_verdict.py <findings.json|->", file=sys.stderr)
        return 2
    source = argv[1]
    try:
        if source == "-":
            data = json.load(sys.stdin)
        else:
            with open(source) as fh:
                data = json.load(fh)
    except (OSError, ValueError) as exc:
        where = "stdin" if source == "-" else source
        print(f"gate_verdict: cannot read {where}: {exc}", file=sys.stderr)
        return 2
    if not isinstance(data, dict):
        print("gate_verdict: findings JSON is not an object", file=sys.stderr)
        return 2
    try:
        action, verdict, reason, unknown, blocking = evaluate(data)
    except ValueError as exc:
        print(f"gate_verdict: {exc}", file=sys.stderr)
        return 2

    out = [f"ACTION\t{action}", f"VERDICT\t{verdict}", f"REASON\t{reason}"]
    out += [f"UNKNOWN\t{u}" for u in unknown]
    out += [f"BLOCK\t{b}" for b in blocking]
    print("\n".join(out))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
