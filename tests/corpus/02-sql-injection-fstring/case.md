# 02 — SQL built by f-string interpolation

Exercises `code-security.md` step 3B (OWASP A03:2021 Injection). User-supplied
`user_id` interpolated into SQL.

Floor is MEDIUM, not HIGH: severity here legitimately depends on whether the
reviewer can see that `user_id` is externally controlled, and the diff does not
show the caller. Requiring HIGH would measure how confidently the model
speculates.
