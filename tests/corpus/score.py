"""Score one corpus case: did the review report what the case expects?

    python3 score.py expected.json findings.json
    -> "<expected> <found> <extra> PASS|FAIL"   (one line, space-separated)

Matching is deliberately loose on wording and strict on substance. A finding
counts as matched when it is on the expected path, at or above the expected
severity floor, in the expected perspective if one is named, and its title plus
description contain every `must_match` substring.

The looseness is the point. A corpus that fails because the model wrote
"credential" where the fixture said "secret" measures phrasing, and a corpus
that measures phrasing gets ignored within a week. What it must not be loose
about is *whether the vulnerability was reported at all*.
"""

import json
import sys

RANK = {"LOW": 1, "MEDIUM": 2, "HIGH": 3, "CRITICAL": 4}


def _haystack(finding):
    return " ".join(
        str(finding.get(k, "")) for k in ("title", "description", "suggestion_summary")
    ).lower()


def matches(expectation, finding):
    if finding.get("path") != expectation["path"]:
        return False

    want_persp = expectation.get("perspective")
    if want_persp and str(finding.get("perspective", "")).lower() != want_persp.lower():
        return False

    floor = RANK.get(str(expectation.get("min_severity", "LOW")).upper(), 1)
    # An unrecognized severity does not satisfy a floor: a finding nobody can
    # rank is not evidence the rubric caught anything.
    got = RANK.get(str(finding.get("severity", "")).strip().upper())
    if got is None or got < floor:
        return False

    hay = _haystack(finding)
    return all(sub.lower() in hay for sub in expectation.get("must_match", []))


def main(argv):
    if len(argv) != 3:
        print("usage: score.py <expected.json> <findings.json>", file=sys.stderr)
        return 2

    expected = json.load(open(argv[1]))
    findings = (json.load(open(argv[2])).get("comments") or [])

    expectations = expected.get("findings", [])
    want_clean = expected.get("clean", False)

    matched_findings = set()
    found = 0
    for exp in expectations:
        for i, f in enumerate(findings):
            if i in matched_findings:
                continue  # one reported finding satisfies at most one expectation
            if matches(exp, f):
                matched_findings.add(i)
                found += 1
                break

    extra = len(findings) - len(matched_findings)

    if want_clean:
        # A negative case fails on ANY finding. Precision is what decides
        # whether a team keeps the tool switched on.
        verdict = "PASS" if not findings else "FAIL"
    else:
        verdict = "PASS" if found == len(expectations) else "FAIL"

    print(f"{len(expectations)} {found} {extra} {verdict}")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
