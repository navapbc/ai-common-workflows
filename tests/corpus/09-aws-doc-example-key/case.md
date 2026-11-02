# 09 — AWS documentation example keys (NEGATIVE, calibration)

`AKIAIOSFODNN7EXAMPLE` / `wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY` are the
credential pair AWS publishes in its own documentation. They are not live, and
they appear in a great deal of real code that copied a doc snippet.

The assertion is **not reported at HIGH or above**. Reporting the pattern at
LOW or MEDIUM is correct and expected — copying that snippet is how real keys
end up in the same constants later. Calling it CRITICAL is the failure: it
spends a program's attention, and at `gate: true` it fails a build over a string
that unlocks nothing.

This case exists because the behavior was observed and is worth keeping. Case
01 originally used this pair by mistake, and a self-adjudicated run downgraded
it to LOW with exactly the right reasoning. That judgment should be pinned as
intended rather than lost the next time someone tunes the secrets rule — it is
the difference between a reviewer teams trust and one that cries wolf.

The counterpart is case 01, which asserts the same rule fires at CRITICAL on a
credential with no published meaning.
