---
applyTo: "**/auth/**,**/authn/**,**/authz/**,**/middleware/**,**/sessions/**,**/login/**,**/oauth/**,**/saml/**,**/jwt/**,**/permissions/**,**/rbac/**,**/acl/**"
---

# AI Review — Authentication & Authorization (Copilot code review)

When reviewing changes to authentication, session, authorization, or
access-control code, apply the `security` perspective (see
`ai-review-security.instructions.md` for the comment format and severity
ladder) with heightened attention to the OWASP Top 10 categories below.

## High-yield checks for auth code

### Critical-severity flags

- Auth bypass: any code path that returns success or sets a session without
  actually validating the supplied credential, token, signature, or claim.
- Hardcoded JWT signing secrets, OAuth client secrets, or SAML private keys.
  **OWASP A07:2021** + **A02:2021**.
- Remote Code Execution via deserialization of session data, tokens, or
  cookies. **OWASP A08:2021**.
- Direct SQL queries in the authn path constructed via string concatenation
  with user-supplied input. **OWASP A03:2021**.

### High-severity flags

- **Broken Access Control (OWASP A01:2021):**
  - New routes / endpoints / functions without an authentication check.
  - New routes that check authentication but not authorization — they verify
    the user is logged in but not that the user may access the specific
    resource. Look for missing ownership/role checks.
  - Direct object references that take an ID from the request and look up a
    resource without verifying the caller owns it.
  - Changes to role / permission logic that broaden access.
  - CORS policy changes that broaden allowed origins, especially to `*` on
    credentialed endpoints.
- **Authentication Failures (OWASP A07:2021):**
  - Session tokens generated with `Math.random()`, `rand()`, or other
    non-cryptographic RNGs; or with insufficient entropy (< 128 bits).
  - Missing session invalidation on logout, password change, or privilege
    change.
  - Password policies weakened; "remember me" tokens stored insecurely.
- **Cryptographic Failures (OWASP A02:2021):**
  - Password hashing using MD5, SHA-1, raw SHA-2, or any unsalted hash. For
    federal / FedRAMP / FISMA / HIPAA workloads, password hashing must use
    **PBKDF2 with HMAC-SHA-256 (or stronger)** per NIST SP 800-132 — the only
    FIPS 140-3-approved password-based KDF. `bcrypt`, `scrypt`, and `argon2`
    are **not** FIPS-approved and must not be recommended for these systems.
    Require a random per-credential salt (≥ 128 bits). **NIST IA-5(1), SC-13.**
  - JWT signing with the `none` algorithm allowed, or verification that
    doesn't check the signature. Use a FIPS 186-5-approved algorithm
    (RS/PS/ES 256/384/512 or EdDSA). **NIST SC-13.**
  - Symmetric encryption with non-FIPS modes (ECB, CBC-without-MAC) or
    algorithms (RC4, DES, 3DES, Blowfish). Use AES-GCM or AES-CCM. **NIST SC-13.**
  - TLS certificate verification disabled (`verify=False`,
    `rejectUnauthorized: false`), or TLS < 1.2. **NIST SC-8, SC-13.**

### Medium-severity flags

- Rate limiting absent on login, password reset, or other sensitive
  endpoints. **OWASP A04:2021.**
- MFA / 2FA bypass paths (e.g., "remember device" cookies that skip MFA
  indefinitely). **OWASP A07:2021.**
- Verbose auth-failure errors that distinguish "user not found" from "wrong
  password" (enables enumeration).
- Sensitive values (tokens, passwords, MFA codes) passed to logging calls.
  **OWASP A09:2021.**
- **CMS-specific identifiers (MBI, HICN, CCN, NPI) appearing in JWT claims,
  session payloads, audit logs, error messages, or URL paths.** Auth code is
  a common leak path: beneficiary identifiers get embedded in `sub` /
  `preferred_username` / custom claims rather than an opaque internal ID;
  audit middleware logs full request/response bodies; URL paths like
  `/api/beneficiary/{mbi}/claims` expose the identifier in access logs,
  browser history, referrer headers, and APM traces. Use opaque internal IDs
  in URLs; resolve to MBI server-side. Severity follows the PHI ladder
  (Critical when real, Medium when likely synthetic). **NIST AU-3, AU-9,
  IA-4, SI-11; HIPAA § 164.312(b).**

### Low-severity flags

- Session cookies missing `Secure`, `HttpOnly`, or `SameSite` flags.
- Auth-related TODO/FIXME comments indicating known gaps.

## Things to check carefully on every diff in this path

- **Middleware order.** Auth middleware must run before route handlers; verify
  newly added routes pass through the auth chain.
- **Decorator coverage.** If routes are protected by decorators
  (`@require_auth`, `@login_required`), verify every new route has one.
- **Permission checks at the data layer.** Even if a route checks
  `current_user.is_admin`, the data layer should verify ownership where it can.
- **Token lifetime and refresh logic.** Long-lived non-expiring tokens,
  refresh tokens that don't rotate, or stolen-token detection that doesn't
  invalidate all of a user's sessions.

## Comment formatting reminders

All comments on auth code must:

1. Use the `security(<severity>):` Conventional Comments label.
2. Cite the OWASP Top 10 category where applicable.
3. When citing a missing check, name the specific check that should be added.
4. Provide a `` ```suggestion `` block for line-level fixes, OR a language
   code-fence for structural fixes.
5. Never include the actual value of a secret in a comment body. Redact with
   `...XXXX` or similar.
