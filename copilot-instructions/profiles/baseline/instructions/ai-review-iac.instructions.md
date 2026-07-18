---
applyTo: "**/*.tf,**/*.tfvars,**/*.tf.json,**/*.bicep,**/*.bicepparam,**/*.hcl,**/*.template.json,**/*.template.yaml,**/*.template.yml,**/Pulumi.yaml,**/Chart.yaml,**/values.yaml,**/cdk.json,**/kustomization.yaml"
---

# AI Review — Infrastructure-as-Code (Copilot code review, baseline)

When reviewing changes to infrastructure-as-code files, apply the `compliance`
perspective (see `ai-review-security.instructions.md` for the comment format
and severity ladder) with heightened attention to the cloud-security
best-practice areas below. This is the framework-neutral baseline: reference
control *themes* (CIS Benchmarks, NIST CSF Functions) rather than a specific
agency catalog. (For CMS ARS 5.1 / NIST 800-53 control IDs, use the `cms-ars`
profile.)

## High-yield checks for IaC

These findings appear most frequently in IaC reviews; prioritize them and emit
`compliance` comments using the template in the security instructions.

### Critical-severity flags

- Inbound security group / NACL rules allowing `0.0.0.0/0` or `::/0` on
  TCP 22 (SSH), TCP 3389 (RDP), or protocol `-1` / `all`. *(Network exposure.)*
- IAM policy with `"Action": "*"` AND `"Resource": "*"` AND no scoping
  `Condition` block. *(Least privilege.)*
- `aws_db_instance` with `publicly_accessible = true`. *(Public exposure.)*
- `aws_s3_bucket_public_access_block` missing or with any of the four
  settings (`block_public_acls`, `block_public_policy`, `ignore_public_acls`,
  `restrict_public_buckets`) set to `false`. *(Public exposure.)*
- Hardcoded password literals on RDS / ElastiCache / MSK / database
  resources. *(Secrets management.)*

### High-severity flags

- `storage_encrypted = false` (or omitted) on RDS, EBS, EFS. *(Encryption at rest.)*
- `aws_cloudtrail` with `is_multi_region_trail = false` or
  `enable_log_file_validation = false`. *(Audit logging.)*
- IAM users / roles attached to `AdministratorAccess` or equivalent. *(Least privilege.)*
- `deletion_protection = false` on RDS / Aurora / DynamoDB **in production**
  (infer from `Environment` tag, workspace name, or absence of a `dev`
  indicator). *(Resilience.)*
- Lambda runtimes on the deprecation list: `nodejs14.x`, `nodejs12.x`,
  `python3.7`, `python3.8`, `java8`, `java8.al2`, `go1.x`, `dotnetcore3.1`,
  `dotnet5.0`, `dotnet6`, `ruby2.7`. *(Flaw remediation.)*
- Kubernetes containers with `runAsNonRoot: false`, `runAsUser: 0`,
  `privileged: true`, or `allowPrivilegeEscalation: true` (or absent).
  *(Hardening.)*

### Medium-severity flags

- Public-facing ALB / API Gateway without an associated
  `aws_wafv2_web_acl_association`. *(DoS / edge protection.)*
- Two or more required tags missing (the required set is `Environment`,
  `Owner` or `Team`, `Project`, `CostCenter`). *(Inventory / baselines.)*
- `aws_cloudwatch_log_group` without `retention_in_days` set. *(Log management.)*
- KMS-encrypted resources (`storage_encrypted = true`) without an explicit
  `kms_key_id` — uses default managed key rather than a customer-managed key.
  *(Key management.)*

### Low-severity flags

- One required tag missing. *(Inventory.)*
- Container images tagged `latest` rather than a pinned digest or version.
  *(Hardening.)*
- Terraform module sources without a pinned `version =` constraint.
  *(Supply chain.)*
- Lambda functions without `tracing_config { mode = "Active" }`. *(Observability.)*

## Environment-aware relaxations

Apply production-strictness by default. Relax to LOW only when context is
unambiguous (clear `Environment = "dev"` tag, workspace named `dev`, etc.):

- `deletion_protection = false` → LOW in dev environments
- `skip_final_snapshot = true` → LOW in dev environments
- `force_destroy = true` on S3 → LOW in dev environments
- Missing WAF on ALB → LOW for documented internal-only endpoints

## Comment formatting reminders

All comments on IaC files must:

1. Use the `compliance(<severity>):` Conventional Comments label.
2. Reference the control theme (CIS area or NIST CSF Function) in plain terms;
   do not invent a specific catalog control ID.
3. Provide a `` ```suggestion `` block when the fix replaces lines at the
   comment's location, OR a `` ```hcl `` / `` ```yaml `` block when the fix
   requires adding a new resource. Never put non-applicable code into a
   `` ```suggestion `` fence.
4. Reference the specific resource (`resource_type.resource_name`) being
   discussed where it isn't already obvious from the file/line context.
