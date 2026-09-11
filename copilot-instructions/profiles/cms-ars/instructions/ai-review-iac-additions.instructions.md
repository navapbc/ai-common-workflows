---
applyTo: "**/*.tf,**/*.tfvars,**/*.tf.json,**/*.bicep,**/*.bicepparam,**/*.hcl,**/*.template.json,**/*.template.yaml,**/*.template.yml,**/Pulumi.yaml,**/Chart.yaml,**/values.yaml,**/cdk.json,**/kustomization.yaml"
---

# AI Review — IaC additions (CMS ARS 5.1 / NIST 800-53)

**This supplements `ai-review-iac.instructions.md`, which always applies —
do not restate its checks.** All of that file's checks still apply exactly as
written; this file adds the control-ID citations for them, plus a few checks
it doesn't cover.

## Control-ID citations for the base checks

When one of the base file's checks fires, cite the matching NIST 800-53 Rev 5
control ID (and the CMS ARS 5.1 tailoring where it differs) instead of the
base file's plain-language theme:

| Base check | NIST / ARS control ID |
|---|---|
| Open security group / NACL on SSH / RDP / all-traffic | AC-4 |
| IAM `"Action": "*"` + `"Resource": "*"` with no `Condition` | AC-3 |
| `AdministratorAccess` or equivalent attached | AC-3 |
| `publicly_accessible = true`; S3 public-access blocks missing/disabled | AC-22 |
| Hardcoded password literals on RDS / ElastiCache / MSK | IA-5 |
| `storage_encrypted = false` on RDS / EBS / EFS | SC-12 / SC-28 |
| KMS-encrypted resource without an explicit `kms_key_id` (default key, not CMK) | SC-13 |
| CloudTrail `is_multi_region_trail = false` / `enable_log_file_validation = false` | AU-2 |
| `aws_cloudwatch_log_group` without `retention_in_days` | AU-9 |
| `deletion_protection = false` in production; container `runAsNonRoot: false` / `privileged: true` / `allowPrivilegeEscalation: true`; image tagged `latest` | CM-6 |
| Required tags missing (2+ → Medium, 1 → Low) | CM-2 |
| Terraform module source without a pinned `version =` | CM-8 |
| Deprecated Lambda runtime | SI-2 |
| Public-facing ALB / API Gateway without a WAF association | SC-5 |
| Lambda without `tracing_config { mode = "Active" }` | RA-5 |

## Additional checks (not in the base file)

### Medium severity

- VPC endpoints not used for S3, DynamoDB, or Secrets Manager when resources
  accessing those services are added — forces traffic over the public
  internet. **NIST SC-7.**
- GuardDuty not enabled (`aws_guardduty_detector` absent) while EC2, S3, or
  EKS resources are being added significantly. **NIST SI-4.**
- AWS Config recorder (`aws_config_configuration_recorder`) or Security Hub
  (`aws_securityhub_account`) absent when significant infrastructure is
  added. **NIST SI-4, RA-5.**
- IAM users without an associated MFA device or a policy requiring MFA via a
  `Condition`; Cognito user pools with `mfa_configuration = "OFF"`; SSO
  permission sets granting console access without `RequireMFA`. **NIST IA-2.**
- ECR repositories without `scan_on_push` enabled; ECS task definitions
  pulling images from public registries rather than a private ECR.
  **NIST SI-3, RA-5.**
- Audit-log retention shorter than HIPAA's six-year requirement
  (§ 164.316(b)(2)(i)) on log groups / buckets holding ePHI access-audit
  records. **NIST AU-11, HIPAA § 164.316(b).**

### High severity — PHI/PII log-content provisioning

Flag IaC that provisions logging which captures sensitive data **by
configuration**, independent of what application code logs:

- Access logging (API Gateway / ALB / NLB / CloudFront) enabled on a route
  that exposes identifiers in the path or query string (e.g.
  `/api/beneficiary/{mbi}/claims`, `?ssn=...`) with no redaction of the path
  component. **NIST AC-23, AU-11.**
- API Gateway stage with `data_trace_enabled = true` or
  `logging_level = "INFO"`/`DEBUG` on a PHI-handling API — writes full
  request/response payloads to CloudWatch. Production should be `ERROR` only
  unless paired with an explicit redaction layer.
  **NIST SI-11, AU-3, HIPAA § 164.312(b).**
- CloudWatch subscription filters forwarding logs to a downstream sink
  (Kinesis, OpenSearch, SIEM) with no redaction processor in the path — the
  sink often has weaker access controls than the source. **NIST AU-9, AC-3.**
- S3 server access logs on PHI buckets written to a target bucket lacking
  encryption, public-access blocks, or its own retention policy — access logs
  include full object keys, which often encode identifiers.
  **NIST AU-9, SC-28.**
- CloudTrail data events on PHI-holding S3 buckets / DynamoDB tables without
  scoping `data_resource` to exclude identifier-bearing keys. **NIST AU-9.**
- APM / observability agents (Datadog, New Relic, X-Ray, OTel collectors)
  provisioned to capture full span attributes or request headers on
  PHI-handling services with no attribute filter. **NIST SI-11, AC-23.**
- A single CloudWatch log group receiving both application output and
  § 164.312(b) audit events — the audit stream needs stricter retention,
  access control, and KMS scope. **NIST AU-9, AC-6.**

For these, the remediation is usually a new or modified resource (a separate
KMS-encrypted audit sink, a redaction subscription filter), so use a
`` ```hcl `` fence rather than `` ```suggestion ``.

## Comment formatting — override

Compliance comments under this profile **must** cite the NIST 800-53 Rev 5
control ID (mandatory) and the CMS ARS 5.1 tailoring when it differs. This
replaces the base file's "reference the control theme in plain terms"
instruction. If unsure of the exact ID, omit it rather than guess — do not
substitute a vague theme name.
