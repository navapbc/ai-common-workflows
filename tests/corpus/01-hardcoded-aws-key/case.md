# 01 — hardcoded AWS credentials

Exercises `code-security.md` step 3A (mandatory secrets detection). A literal
AWS access key pair in source, which the rubric defines as CRITICAL.

The floor is CRITICAL deliberately: if the rubric ever reports a live-looking
credential as anything less, that is a regression worth failing on, not a
calibration quibble.
