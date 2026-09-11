# Compliance profiles

The review always applies a **security** perspective (secrets, PII, OWASP Top 10,
general defects) and a **compliance** perspective — a framework-neutral IaC
security floor (CIS Benchmarks / NIST CSF / OWASP) that also always applies.
A selectable **profile** may *add* agency- or framework-specific checks and
control-ID citations on top of that floor, so the same engine serves a CMS
system, a different federal agency, a state agency, or a team with no specific
mandate, without any of them losing baseline coverage.

A profile only ever **adds to** the compliance rubric (or, for other rubric
files, may override one outright — see [How resolution works](#how-resolution-works)).
The security perspective and the review mechanics (fan-out, adjudication,
comment format, gating) are identical across profiles, and no profile can
remove or weaken the compliance floor.

## Bundled profiles

| Profile | Adds | Use when |
|---|---|---|
| `baseline` *(default)* | Nothing — no rubric additions. You get the framework-neutral CIS/NIST CSF/OWASP floor only. | You want a solid security baseline with no specific agency mandate |
| `cms-ars` | CMS ARS 5.1 / NIST SP 800-53 Rev 5 control-ID citations for the floor's findings, plus CMS/HIPAA-specific checks the floor doesn't cover (MFA, vulnerability/posture monitoring, WAF/DoS, malware/image provenance, pipeline integrity, and a detailed PHI/PII log-content review) | CMS systems and contractors |

## Selecting a profile

Everything defaults to `baseline`; set it explicitly to add a framework-specific
overlay.

- **GitHub Action** — the `profile` input:
  ```yaml
  - uses: navapbc/ai-common-workflows/workflows/security-compliance-review@<sha>
    with:
      profile: cms-ars
  ```
- **Jenkins** — the `profile` step parameter (or the global default):
  ```groovy
  aiSecurityComplianceReview(profile: 'cms-ars')
  ```
- **Engine directly** — the `AI_REVIEW_PROFILE` environment variable.
- **Copilot instructions** — the `PROFILE` in your copy of the sync workflow
  ([`examples/workflows/copilot-instructions-sync.yml`](../examples/workflows/copilot-instructions-sync.yml)):
  ```yaml
  env:
    PROFILE: baseline   # or cms-ars, or your own profile
  ```

## How resolution works

`AI_REVIEW_PROFILE` is resolved by the engine as:

1. If it is an **existing directory path**, that directory is the profile
   (bring-your-own).
2. Else if the engine's `skills/profiles/<name>/` exists, that is the profile.
3. Else the run fails with a configuration error (exit 2) listing the bundled
   profiles.

Rubric files are handled differently depending on which one they are:

- **`iac-compliance.md` (the compliance perspective) is additive.** The
  framework-neutral floor at `engines/security-compliance-review/skills/base/iac-compliance.md`
  is **always** included in the prompt. If the active profile also has its
  own `iac-compliance.md`, it is appended immediately after the floor,
  explicitly instructed to take precedence over the floor on any conflict
  (severity, citation, guidance). `baseline` has no such file, so selecting
  it (or the default) yields the floor alone; `cms-ars` has one, so selecting
  it yields floor + CMS additions.
- **`pr-review.md` and `code-security.md` are override-or-fallback**, like
  before: the engine prefers the active profile's copy of the file and falls
  back to the shared `skills/base/` copy only if the profile doesn't provide
  one. No bundled profile currently overrides these — they're identical
  across profiles — but a profile is free to if it ever needs to.

```
engines/security-compliance-review/skills/base/iac-compliance.md            ← always applied (the floor)
engines/security-compliance-review/skills/profiles/<profile>/iac-compliance.md  ← appended if present (an addition, not a replacement)

engines/security-compliance-review/skills/profiles/<profile>/<other-file>   ← used if present (a full override)
engines/security-compliance-review/skills/base/<other-file>                 ← otherwise (the framework-neutral base)
```

## Adding a profile (agency or state variant)

1. Create `skills/profiles/<name>/iac-compliance.md` (under the review engine)
   containing only your **additions** to the floor — control-ID citations for
   findings the floor already covers (a cross-reference table is enough; don't
   restate the check), plus any checks genuinely specific to your framework
   that the floor doesn't have. Start from `skills/profiles/cms-ars/iac-compliance.md`
   as a worked example of the additive shape. Do **not** copy the floor's
   checks into your file — that duplicates content that already always
   applies and risks the two drifting apart.
2. (Optional) add matching Copilot instructions under
   `copilot-instructions/profiles/<name>/instructions/ai-review-*-additions.instructions.md`
   so Copilot's native review agrees with the action/plugin. These are
   additive in the same way: the base set in `copilot-instructions/base/`
   always syncs, and your `*-additions` files layer on top. See
   [copilot-instructions.md](copilot-instructions.md).
3. Reference it: `profile: <name>` (Action/Jenkins) or `AI_REVIEW_PROFILE=<name>`.

**Bring-your-own without committing to this repo:** point `profile` at a
directory in *your* checkout containing an `iac-compliance.md`. It is treated
the same as a bundled profile's file — an addition layered on top of the
floor, not a replacement — so it only needs to contain your organization's
deltas. No change to this repo required.

> Do not invent control identifiers you can't source. If your agency's catalog
> isn't public or you're unsure of an exact ID, describe the control in plain
> terms rather than citing a fabricated ID — the same rule the rubrics follow.
