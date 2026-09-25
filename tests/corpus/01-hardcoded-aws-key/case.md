# 01 — hardcoded AWS credentials

Exercises `code-security.md` step 3A (mandatory secrets detection). A literal
AWS access key pair in source, which the rubric defines as CRITICAL.

The floor is CRITICAL deliberately: if the rubric ever reports a live-looking
credential as anything less, that is a regression worth failing on, not a
calibration quibble.

**The key pair must not be one AWS publishes as a documentation example.** This
case originally used `AKIAIOSFODNN7EXAMPLE` / `wJalrXUtnFEMI/K7MDENG/...`, and a
run with self-adjudication on downgraded it to LOW with the correct reasoning —
those are AWS's own doc placeholders, so they are not live credentials. The
model was right and the fixture was wrong: it asserted "live-looking" while
using the most famously not-live pair in existence, so it measured whether the
model recognizes AWS's example key rather than whether it catches hardcoded
credentials. The values here are generated and AWS-shaped, with no published
meaning. Case 09 covers the recognizing-a-placeholder behavior on purpose.
