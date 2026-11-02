# 03 — the same query, parameterized (NEGATIVE)

The mitigated twin of case 02. A correct parameterized query must produce no
findings.

This is the case that catches a rubric drifting toward "any SQL near a
parameter is injection" — the failure mode adjudication exists for, and the one
that gets a review bot switched off.
