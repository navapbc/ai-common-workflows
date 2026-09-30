---
applyTo: "**"
---

# AI Review — Security & Compliance additions (CMS ARS 5.1 / NIST 800-53)

**This supplements `ai-review-security.instructions.md`, which always
applies — do not restate its guidance.** This file adds two things for the
`cms-ars-5.1` profile:

1. **PHI-specific severity-ladder items** the base file's generic ladder
   doesn't cover.
2. **A mandatory control-ID citation requirement for compliance comments**
   that **overrides** the base file's "reference the theme generically"
   guidance — for this profile, always cite the ID.

## Additional severity-ladder items (PHI)

Apply these in addition to the base file's ladder — they don't replace it,
the base file's generic PII/secrets items still apply too.

| Severity | Also flag |
|---|---|
| **CRITICAL** | Real PHI; a new log / tracing / span / error-message statement that interpolates a PHI identifier (MBI, HICN, SSN, NPI) or a PHI-bearing object whose runtime value will be real PHI; removal or weakening of an existing log-redaction filter on a PHI/PII path |
| **HIGH** | A new structured-logging field named `body` / `request_body` / `params` / `headers` / `claims` on a PHI/PII path without an explicit redaction filter; a URL path or route added that embeds a PHI identifier (gets captured by access logs); an IaC change that provisions access logging on a PHI-exposing route without redaction, or that sets API Gateway `data_trace_enabled = true` / `logging_level = "INFO"` on a PHI-handling stage |
| **MEDIUM** | Audit-log retention below HIPAA's six-year requirement (§ 164.316(b)(2)(i)) on ePHI systems; application logs and § 164.312(b) audit logs co-mingled in a single sink; GuardDuty absent |

## Compliance comment citation — override

For this profile, compliance comments **must always** include the relevant
NIST 800-53 Rev 5 control ID(s) and the corresponding CMS ARS 5.1 control
ID(s) where they differ, e.g., `NIST AC-3, CMS ARS AC-3(HIGH)`. This replaces
the base file's "reference the theme generically" instruction for compliance
comments under this profile — do not fall back to a plain-language theme
name when a control ID applies.

If you are unsure of the exact NIST control ID, omit it rather than guess
(per the base file's rule on fabricated IDs) — do not fall back to a vague
theme name as a substitute.
