---
applyTo: "**/auth/**,**/authn/**,**/authz/**,**/middleware/**,**/sessions/**,**/login/**,**/oauth/**,**/saml/**,**/jwt/**,**/permissions/**,**/rbac/**,**/acl/**"
---

# AI Review — Auth additions (CMS ARS 5.1 / NIST 800-53)

**This supplements `ai-review-auth.instructions.md`, which always applies —
do not restate its checks.** All of that file's OWASP-based checks still
apply. This file adds the FIPS posture required for federal / FedRAMP /
FISMA / HIPAA workloads and the CMS-identifier leak checks.

## Cryptographic algorithm choice — override

The base file allows any strong modern KDF or algorithm. For CMS / federal
workloads this is **narrower**, and this section takes precedence:

- **Password hashing must use PBKDF2 with HMAC-SHA-256 (or stronger)** per
  NIST SP 800-132 — the only FIPS 140-3-approved password-based KDF.
  `bcrypt`, `scrypt`, and `argon2` are **not** FIPS-approved and must **not**
  be recommended for these systems, even though the base file lists them as
  acceptable. Require a random per-credential salt (≥ 128 bits).
  **NIST IA-5(1), SC-13.**
- **JWT signing** must use a FIPS 186-5-approved algorithm (RS/PS/ES
  256/384/512 or EdDSA). **NIST SC-13.**
- **Symmetric encryption** must use a FIPS-approved mode — AES-GCM or
  AES-CCM. ChaCha20-Poly1305, acceptable under the base file, is not
  FIPS-approved. Non-FIPS modes (ECB, CBC-without-MAC) and algorithms (RC4,
  DES, 3DES, Blowfish) remain prohibited. **NIST SC-13.**
- **TLS**: certificate verification disabled (`verify=False`,
  `rejectUnauthorized: false`) or TLS < 1.2. **NIST SC-8, SC-13.**

## Additional check — CMS identifiers in auth paths

In addition to the base file's generic PII-in-auth-path check, flag
**CMS-specific identifiers (MBI, HICN, CCN, NPI)** appearing in JWT claims,
session payloads, audit logs, error messages, or URL paths. Beneficiary
identifiers get embedded in `sub` / `preferred_username` / custom claims
rather than an opaque internal ID; audit middleware logs full
request/response bodies; URL paths like `/api/beneficiary/{mbi}/claims`
expose the identifier in access logs, browser history, referrer headers, and
APM traces. Use opaque internal IDs in URLs; resolve to MBI server-side.

Severity follows the PHI ladder in
`ai-review-security-additions.instructions.md` (Critical when real, Medium
when likely synthetic) rather than the base file's flat Medium.
**NIST AU-3, AU-9, IA-4, SI-11; HIPAA § 164.312(b).**
