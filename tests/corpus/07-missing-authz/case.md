# 07 — a new route added without the authorization decorator

Exercises `code-security.md` step 3B (OWASP A01:2021 Broken Access Control).

The most valuable shape in the whole corpus, and the hardest: the new handler
is not wrong in isolation. It is wrong because the handler directly above it —
visible in the same diff — carries `@require_role` and this one does not. That
requires reading the change in context, which is the thing this review is
supposed to do and a linter cannot.

`must_match` is "author" so it matches authorization/authorisation/authz.
