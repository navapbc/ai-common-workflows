# 05 — the same database, correctly configured (NEGATIVE)

The mitigated twin of case 04: customer-managed key, rotation, backups,
deletion protection, not public.

The assertion is **no encryption finding**. If one appears, the compliance
perspective is reporting on the presence of a sensitive resource rather than on
its configuration, which would make every IaC PR noisy regardless of quality.

## Why this is `forbidden` and not `clean: true`

It was `clean: true`, and it failed every run — in both adjudication modes,
identically. The seven findings were things like a master password sourced from
a Terraform variable, no log exports, no explicit subnet or security group,
missing inventory tags, TLS not enforced, single-AZ. All real, all about
configuration, none of them the mistake this case exists to catch. The rubric
reports LOW-and-above on IaC, so a realistic `aws_db_instance` will always have
*something* to say about it.

`clean: true` therefore measured how complete the fixture is, not how good the
rubric is — and a case that fails for reasons unrelated to what it tests is one
people learn to ignore. Padding the resource until nothing could be said would
have made it unrealistic and brittle instead. The extras still show in the
`extra` column, so noise stays visible without failing the case.

`clean: true` is still right for a fixture with genuinely nothing to report —
cases 03 and 08 use it and pass.
