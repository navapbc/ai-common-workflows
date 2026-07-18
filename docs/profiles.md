# Compliance profiles

The review always applies a **security** perspective (secrets, PII, OWASP Top 10,
general defects). The **compliance** perspective — the control framework the IaC
and code are judged against — is a selectable **profile**, so the same engine
serves a CMS system, a different federal agency, a state agency, or a team with
no specific mandate.

A profile changes *only* the compliance rubric. The security perspective and the
review mechanics (fan-out, adjudication, comment format, gating) are identical
across profiles.

## Bundled profiles

| Profile | Framework | Use when |
|---|---|---|
| `cms-ars` *(default)* | CMS ARS 5.1 / NIST SP 800-53 Rev 5, with HIPAA log-handling checks | CMS systems and contractors |
| `baseline` | CIS Benchmarks / NIST CSF / OWASP — no agency control IDs | You want a solid security baseline with no specific mandate |

## Selecting a profile

Everything defaults to `cms-ars`; set it explicitly to change it.

- **GitHub Action** — the `profile` input:
  ```yaml
  - uses: navapbc/ai-common-workflows/workflows/security-compliance-review@<sha>
    with:
      profile: baseline
  ```
- **Jenkins** — the `profile` step parameter (or the global default):
  ```groovy
  aiSecurityComplianceReview(profile: 'baseline')
  ```
- **Engine directly** — the `AI_REVIEW_PROFILE` environment variable.
- **Copilot instructions** — the `PROFILE` in your copy of the sync workflow
  ([`examples/workflows/copilot-instructions-sync.yml`](../examples/workflows/copilot-instructions-sync.yml)):
  ```yaml
  env:
    PROFILE: cms-ars   # or baseline, or your own profile
  ```

## How resolution works

`AI_REVIEW_PROFILE` is resolved by the engine as:

1. If it is an **existing directory path**, that directory is the profile
   (bring-your-own).
2. Else if `engine/profiles/<name>/` exists, that is the profile.
3. Else the run fails with a configuration error (exit 2) listing the bundled
   profiles.

For each rubric file the prompt needs, the engine prefers the profile's copy and
falls back to the shared base:

```
engine/profiles/<profile>/<file>     ← used if present (the override)
engine/skills/<file>                 ← otherwise (the framework-neutral base)
```

Today the compliance perspective (`iac-compliance.md`) is what profiles override;
a profile may also override `pr-review.md` or `code-security.md` if it needs to.

## Adding a profile (agency or state variant)

1. Create `engine/profiles/<name>/iac-compliance.md` with your control mapping.
   Start from `engine/profiles/baseline/iac-compliance.md` (generic) or
   `engine/profiles/cms-ars/iac-compliance.md` (worked example with control IDs).
   Keep the output contract identical — only the control content changes.
2. (Optional) add matching Copilot instructions under
   `copilot-instructions/profiles/<name>/instructions/ai-review-*.instructions.md`
   so Copilot's native review agrees with the action/plugin.
3. Reference it: `profile: <name>` (Action/Jenkins) or `AI_REVIEW_PROFILE=<name>`.

**Bring-your-own without committing to this repo:** point `profile` at a
directory in *your* checkout containing an `iac-compliance.md`. The engine uses
it directly — no change to this repo required.

> Do not invent control identifiers you can't source. If your agency's catalog
> isn't public or you're unsure of an exact ID, describe the control in plain
> terms rather than citing a fabricated ID — the same rule the rubrics follow.
