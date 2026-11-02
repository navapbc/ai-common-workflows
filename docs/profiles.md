# Compliance profiles

`profile` is an **ordered list of rubric sources**. The shared floor is an
explicit member of that list, not an implicit extra:

```yaml
    profile: base                        # the floor alone
    profile: base,cms-ars-5.1                # floor + CMS additions
    profile: base,cms-ars-5.1,pci-dss-4.0        # floor + CMS + PCI; PCI wins a conflict
    profile: none,my-agency-everything   # NO floor; you supply the whole rubric
```

The floor is the framework-neutral rubric in `skills/base/`: a **security**
perspective (secrets, PII/PHI, OWASP Top 10, general defects) and a
**compliance** perspective (CIS Benchmarks / NIST CSF / OWASP for IaC). A
profile layers agency- or framework-specific checks and control-ID citations on
top, so one engine serves a CMS system, another federal agency, a state agency,
or a team with no mandate.

**Sources only ever add.** Each one is appended after the ones before it and
told that it outranks everything above it, so on a genuine conflict the **last
entry wins**. A source cannot remove or weaken what is above it — it can
contradict a check, but the earlier text still reaches the model. If you need a
base check switched off, that is a signal it belongs behind a base-level
condition rather than in a profile.

**The first entry must be `base` or `none`.** That is not ceremony. Omitting
the floor is a silent, severe failure — the review still runs, still posts,
still reports a verdict, and has checked almost nothing against 1,200-odd lines
of rubric that are no longer there. `profile: cms-ars-5.1` is a natural thing to
type, so it is a configuration error rather than a quiet downgrade:

```
::error::AI_REVIEW_PROFILE must start with 'base' or 'none' (got 'cms-ars-5.1').
```

`base` must also be *first*: listed later it would outrank the overlays layered
before it, which is never what anyone means.

**`none` is the full-control escape hatch.** A program that needs to own the
entire rubric declares it, in the config, where a reviewer can see it — rather
than reaching for a per-file override that silently replaced a base file. If
you use it, your profile must supply the file carrying the output contract
(`pr-review.md` for the review, `codebase-audit.md` for the audit) or the run
fails up front with a message saying so: those files define the result marker
and the findings JSON, so without one nothing downstream can parse the output.

**`finding-adjudication.md` sits outside this list** and is always read from
`skills/base/`. It governs how findings are *judged*, not what is looked for,
so `none` must not cost a program its false-positive filter. Adjudication
behaves identically under every profile.

The review mechanics — fan-out, adjudication modes, comment format, gating —
are identical across all sources.

## Bundled sources

`base` is not a profile directory — it resolves to the engine's
`skills/base/`. The profiles below live under `skills/profiles/` and are listed
after it.

| Source | Adds | Use when |
|---|---|---|
| `base` *(required first entry, unless `none`)* | Nothing — it **is** the framework-neutral CIS / NIST CSF / OWASP floor. | Always, unless a profile is replacing the rubric wholesale |
| `cms-ars-5.1` | CMS ARS 5.1 / NIST SP 800-53 Rev 5 control-ID citations for the floor's findings, plus CMS/HIPAA-specific checks the floor doesn't cover (MFA, vulnerability/posture monitoring, WAF/DoS, malware/image provenance, pipeline integrity, and a detailed PHI/PII log-content review) | CMS systems and contractors |

## Selecting a profile

Everything defaults to `base`; add a profile after it to layer a framework-specific
overlay.

- **GitHub Action** — the `profile` input:
  ```yaml
  - uses: navapbc/ai-common-workflows/workflows/security-compliance-review@<sha>
    with:
      profile: base,cms-ars-5.1
  ```
- **Jenkins** — the `profile` step parameter (or the global default):
  ```groovy
  aiSecurityComplianceReview(profile: 'base,cms-ars-5.1')
  ```
- **Engine directly** — the `--profile` flag or the `AI_REVIEW_PROFILE`
  environment variable; the flag wins. Both entrypoints accept it.
- **Copilot instructions** — the `PROFILE` in your copy of the sync workflow
  ([`examples/workflows/copilot-instructions-sync.yml`](../examples/workflows/copilot-instructions-sync.yml)).
  Note this one is a **single value, not a list**, and its base set always
  syncs — the sync copies files rather than assembling a prompt, so it has not
  adopted the list form:
  ```yaml
  env:
    PROFILE: baseline   # or cms-ars-5.1, or your own profile
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

## Versioning a profile

A profile that implements a **versioned standard carries the revision in its
name** — `cms-ars-5.1`, not `cms-ars`. Three reasons:

- **Revisions coexist.** Programs sit on different revisions during an
  assessment cycle. Sibling directories let one repo serve both; a single
  unversioned directory cannot.
- **Provenance is answerable.** "Which revision did this judge against?" is
  answered by the config itself. The audit already records the profile string
  in its report header, and a posted review carries a `Judged against:` line,
  so the revision travels with the output rather than living in someone's head.
- **An unversioned name is a mutable pointer.** `cms-ars` meaning "whatever we
  implement today" changes what a consumer is judged against without them
  choosing — the same failure the SHA-pinning rule exists to prevent.

So there is **no `cms-ars` alias for "latest"**. An old or unversioned name
fails resolution with an error listing what is bundled. Moving revision is a
deliberate one-line edit, and that is the point.

The revision belongs in the **directory** name only. Rubric filenames are the
join key — `ai_review::rubric_block` matches a profile's file to the floor's by
identical filename — so `iac-compliance.md` must be spelled the same in every
profile. A versioned filename would break layering.

Frameworks without published revisions need no version. This applies where the
standard itself is versioned and a program can be assessed against a specific
edition.

**The floor names no revision.** `skills/base/` is framework-neutral; a
revision there would contradict whichever profile is actually loaded, and is
loaded even by programs with no relationship to that framework. Enforced by
`tests/python/test_floor_is_framework_neutral.py`. The floor may point at a
profile by name — that says where the framework lives, it does not cite it.

## Adding a profile (agency or state variant)

> Profiles are the right home for **framework- or language-specific** rules
> too, if you need them. The shared rubric deliberately has none — see
> [why there are no language-specific rubrics](security-compliance-review.md#why-there-are-no-language-specific-rubrics).
> Knowledge with a short half-life belongs near the people who will notice it
> ageing, not in a floor everyone inherits.


1. Create `skills/profiles/<name>/iac-compliance.md` (under the review engine)
   containing only your **additions** to the floor — control-ID citations for
   findings the floor already covers (a cross-reference table is enough; don't
   restate the check), plus any checks genuinely specific to your framework
   that the floor doesn't have. Start from `skills/profiles/cms-ars-5.1/iac-compliance.md`
   as a worked example of the additive shape. Do **not** copy the floor's
   checks into your file — that duplicates content that already always
   applies and risks the two drifting apart.
2. (Optional) add matching Copilot instructions under
   `copilot-instructions/profiles/<name>/instructions/ai-review-*-additions.instructions.md`
   so Copilot's native review agrees with the action/plugin. These are
   additive in the same way: the base set in `copilot-instructions/base/`
   always syncs, and your `*-additions` files layer on top. See
   [copilot-instructions.md](copilot-instructions.md).
3. Reference it after `base`: `profile: base,<name>` (Action/Jenkins) or
   `AI_REVIEW_PROFILE=base,<name>`. List several — `profile: base,cms-ars-5.1,<name>`
   — and the last one wins any conflict. Use `none,<name>` only if your profile
   is meant to replace the floor entirely.

Your profile may also ship `code-security.md`, `pr-review.md` or
`codebase-audit.md` additions, layered the same way. Keep them to deltas for
the same reason: the base always applies underneath.

**Bring-your-own without committing to this repo:** point `profile` at a
directory in *your* checkout containing an `iac-compliance.md` (or any other
rubric filename). It is treated exactly like a bundled profile's file — an
addition layered on top of the base, never a replacement — so it only needs
your organization's deltas. A path can appear in a list alongside a bundled
name: `profile: base,cms-ars-5.1,./compliance/my-overlay`. No change to this repo
required.

> Do not invent control identifiers you can't source. If your agency's catalog
> isn't public or you're unsure of an exact ID, describe the control in plain
> terms rather than citing a fabricated ID — the same rule the rubrics follow.
