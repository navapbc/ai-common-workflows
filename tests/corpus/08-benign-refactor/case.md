# 08 — a pure refactor with no security content (NEGATIVE)

A loop replaced by a comprehension, plus a docstring. Nothing security-relevant
is added, removed or changed.

The baseline precision check. A review that finds something here will find
something in every PR, and the tool will be muted. Worth running on its own
after any rubric change that adds a "general security review" style rule.
