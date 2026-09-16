# Compliance profiles

The review always applies a **security** perspective (secrets, PII, OWASP Top 10,
general defects) and a **compliance** perspective — a framework-neutral IaC
security floor (CIS Benchmarks / NIST CSF / OWASP) that also always applies.
A selectable **profile** may *add* agency- or framework-specific checks and
control-ID citations on top of that floor, so the same engine serves a CMS
system, a different federal agency, a state agency, or a team with no specific
mandate, without any of them losing baseline coverage.

A profile only ever **adds**. Every base rubric file always reaches the prompt;
a profile's copy of the same filename is appended after it, never substituted
for it. There is no override path, so **no profile can remove or weaken any
base coverage** — security or compliance. The review mechanics (fan-out,
adjudication, comment format, gating) are identical across profiles.

**Profiles compose.** `profile` takes one name or a comma-separated list, so a
program subject to two frameworks applies both:

```yaml
    profile: cms-ars,pci-dss
```

Additions layer in list order, and each one is told it outranks everything
above it — so on a genuine conflict the **last profile listed wins**.

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

Every rubric file works the same way — there is exactly one rule:

- **The base file in `skills/base/` always applies.** It is the floor, and
  nothing can displace it.
- **Each listed profile's copy of that filename is appended after it**, in list
  order, introduced as an addition and instructed to take precedence over
  everything above it on conflict. A profile that doesn't ship the file
  contributes nothing to that section.

```
engines/security-compliance-review/skills/base/<file>                     ← always applied (the floor)
engines/security-compliance-review/skills/profiles/<first>/<file>         ← appended if present
engines/security-compliance-review/skills/profiles/<second>/<file>        ← appended after that; wins conflicts
```

This applies to `iac-compliance.md`, `code-security.md`, `pr-review.md` and
`codebase-audit.md` alike. Earlier versions treated the last three as
whole-file overrides — a profile's copy replaced the base. That was removed
deliberately: an override forces a profile that wants one extra check to copy
~20 KB of rubric it then has to maintain forever, which is the drift that
per-profile standalone rubrics already caused once, and two overrides cannot be
composed because one silently wins.

The practical consequence is that a profile **cannot suppress** a base check.
It can contradict one — its section outranks the base — but the base text still
reaches the model. If you find yourself needing to turn a base check off, that
is a signal the check belongs behind a base-level condition rather than in a
profile.

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
   Combine several with a comma — `profile: cms-ars,<name>` — and the last one
   listed wins any conflict.

Your profile may also ship `code-security.md`, `pr-review.md` or
`codebase-audit.md` additions, layered the same way. Keep them to deltas for
the same reason: the base always applies underneath.

**Bring-your-own without committing to this repo:** point `profile` at a
directory in *your* checkout containing an `iac-compliance.md` (or any other
rubric filename). It is treated exactly like a bundled profile's file — an
addition layered on top of the base, never a replacement — so it only needs
your organization's deltas. A path can appear in a list alongside a bundled
name: `profile: cms-ars,./compliance/my-overlay`. No change to this repo
required.

> Do not invent control identifiers you can't source. If your agency's catalog
> isn't public or you're unsure of an exact ID, describe the control in plain
> terms rather than citing a fabricated ID — the same rule the rubrics follow.
