---
applyTo: "**/auth/**,**/authn/**,**/authz/**,**/middleware/**,**/sessions/**,**/login/**,**/oauth/**,**/saml/**,**/jwt/**,**/permissions/**,**/rbac/**,**/acl/**"
---

# AI Review — Authentication & Authorization (Copilot code review, baseline)

When reviewing changes to authentication, session, authorization, or
access-control code, apply the `security` perspective (see
`ai-review-security.instructions.md` for the comment format and severity
ladder) with heightened attention to the OWASP Top 10 categories below. This is
the framework-neutral baseline; it recommends strong modern defaults without
mandating a specific agency's FIPS posture (use the `cms-ars` profile for that).

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
  - Insecure direct object references: taking an ID from the request and
    looking up a resource without verifying the caller owns it.
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
  - Password hashing using MD5, SHA-1, or any raw/unsalted hash. Use a strong
    password KDF — **argon2id**, **scrypt**, **bcrypt**, or **PBKDF2-HMAC-SHA-256**
    — with a random per-credential salt (≥ 128 bits).
  - JWT signing with the `none` algorithm allowed, or verification that
    doesn't check the signature. Use a strong asymmetric or HMAC algorithm
    (RS/PS/ES 256+ or EdDSA / HS256+).
  - Symmetric encryption with weak modes (ECB, CBC-without-MAC) or algorithms
    (RC4, DES, 3DES, Blowfish). Prefer AES-GCM or ChaCha20-Poly1305.
  - TLS certificate verification disabled (`verify=False`,
    `rejectUnauthorized: false`), or TLS < 1.2.

### Medium-severity flags

- Rate limiting absent on login, password reset, or other sensitive
  endpoints. **OWASP A04:2021.**
- MFA / 2FA bypass paths (e.g., "remember device" cookies that skip MFA
  indefinitely). **OWASP A07:2021.**
- Verbose auth-failure errors that distinguish "user not found" from "wrong
  password" (enables enumeration).
- Sensitive values (tokens, passwords, MFA codes) passed to logging calls.
  **OWASP A09:2021.**
- **Sensitive identifiers or PII (SSN, national ID, email, account number)
  embedded in JWT claims, session payloads, audit logs, error messages, or URL
  paths.** Auth code is a common leak path: identifiers get put in `sub` /
  `preferred_username` / custom claims rather than an opaque internal ID; audit
  middleware logs full request/response bodies; URL paths like
  `/api/users/{ssn}/orders` expose the identifier in access logs, browser
  history, referrer headers, and traces. Use opaque internal IDs in URLs and
  resolve server-side.

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
