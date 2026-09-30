# IaC Compliance Perspective — CMS ARS 5.1 / NIST 800-53 additions

**This is an addition to the framework-neutral baseline compliance
perspective (`skills/base/iac-compliance.md`), not a replacement for it.**
The baseline perspective always applies and already runs Steps 1–2 (collect
the diff, detect IaC type, load targeted context) and its own control
checks (IAM least privilege, network exposure, encryption, logging,
configuration hygiene, resilience) before this section — do not repeat that
work. This file adds:

1. **NIST SP 800-53 Rev 5 / CMS ARS 5.1 control-ID citations** for those same
   baseline findings — cite the ID below *instead of* (not in addition to)
   the baseline's generic theme name for a finding.
2. **CMS/HIPAA-specific checks** the baseline perspective does not cover at
   all: multi-factor authentication, vulnerability/posture monitoring,
   DoS/WAF protection, malware and image-provenance discipline, pipeline
   source integrity, and a detailed PHI/PII log-content review.

**Precedence:** where this file's severity or guidance differs from the
baseline for the same finding, use this file's — it is the more specific of
the two. Never report the same underlying finding twice (once under a
baseline theme and once under a NIST/ARS ID) — merge into one comment citing
the NIST/ARS ID.

For each control reference below: **NIST SP 800-53 Rev 5 ID** | **CMS ARS 5.1
family** — both use identical control identifiers, since ARS is a tailored
overlay of NIST 800-53.

---

## Control-ID cross-reference for baseline findings

When the baseline perspective's checks apply, cite the matching control ID
below instead of the generic theme name:

| Baseline category | NIST / ARS control ID |
|---|---|
| IAM wildcard actions/resources, admin policies, `sts:AssumeRole` without `Condition`, S3 public-write policies | AC-3 |
| Shared/generic account names, IAM account provisioning hygiene | AC-2 |
| Public-facing management endpoints / bastions without IP restriction | AC-17 |
| Public S3 access blocks, `publicly_accessible` datastores | AC-22 |
| Open security groups/NACLs (SSH/RDP/all-traffic/DB ports), `hostNetwork` | AC-4 |
| Audit/flow logging disabled (CloudTrail/VPC Flow Logs/EKS/RDS/CloudFront) | AU-2 / AU-3 |
| Log destination encryption, log retention | AU-9 |
| Tagging gaps, hardcoded AMI/IP | CM-2 |
| Deletion protection, force-destroy, container root/privileged, `latest` image tags | CM-6 |
| Unused open ports | CM-7 |
| Missing Name/description tags, unpinned module versions | CM-8 |
| Backups disabled, no PITR, no backup plan | CP-9 |
| Hardcoded passwords/secrets, KMS key rotation disabled | IA-5 |
| Encryption at rest (S3/EBS/RDS/EFS/SNS/SQS/Secrets Manager), CMK vs default key | SC-12 / SC-13 / SC-28 |
| Transport TLS (LB/API GW/OpenSearch/MSK/RDS) | SC-8 |
| Deprecated runtimes | SI-2 |
| State/artifact bucket versioning | SI-7 |
| No image scanning on push for ECR/registries | SI-3 / RA-5 |

---

## CMS/HIPAA-specific additions (not covered by baseline)

Apply these in addition to the cross-referenced findings above.

### IA-2 | Multi-Factor Authentication
- IAM user resources without an associated `aws_iam_virtual_mfa_device` or a
  policy requiring MFA via a `Condition` block
- Cognito user pools without MFA enabled (`mfa_configuration = "OFF"`)
- AWS SSO / IAM Identity Center permission sets granting console access
  without a `RequireMFA` condition

### RA-5 / SI-4 | Vulnerability and Posture Monitoring
- Amazon Inspector not enabled for new EC2 or container workloads
- GuardDuty not enabled (flag if `aws_guardduty_detector` is absent while EC2,
  S3, or EKS resources are being added significantly)
- AWS Config rules not present when significant infrastructure is added
  (`aws_config_configuration_recorder` absent)
- Security Hub not enabled (`aws_securityhub_account` absent)
- CloudWatch alarms not created alongside new security-sensitive resources
  (RDS, EKS, ECS, Lambda added without corresponding alarms/dashboards)

### SC-5 | Denial of Service Protection
- Application Load Balancers or API Gateways without an associated WAF web ACL
  (`aws_wafv2_web_acl_association` missing when public-facing ALB/API GW is added)
- CloudFront distributions without AWS Shield or WAF association for public endpoints

### SC-7 | Boundary Protection
- VPC endpoints not used for S3, DynamoDB, or Secrets Manager when resources
  accessing these services are being added (flag absence as Medium — forces
  traffic over public internet)
- Security groups using `cidr_blocks = ["0.0.0.0/0"]` on egress rules for
  sensitive workloads
- Internet-facing ALBs in private subnets (misconfiguration)
- `associate_public_ip_address = true` on EC2 instances in private subnets

### SI-3 | Malware Protection
- ECS task definitions referencing images from public registries without a
  documented approval process (images not from a private ECR registry)

### SI-7 | Software, Firmware, and Information Integrity (pipeline addendum)
- CodePipeline or CodeBuild projects without source integrity checks

### AU-11 / SI-11 / AC-23 | Log content discipline (PHI/PII leak prevention at the IaC layer)

The application-code side of this concern lives in the security
perspective's § 3A.1 (Logging Hygiene). At the IaC layer, the equivalent
risk is provisioning logging infrastructure that **captures sensitive
data by configuration** — independent of what the application code chooses
to log. HIPAA **§ 164.502(b)** (Minimum Necessary) applies to logs as
much as to APIs: a log sink that records full request bodies on a
PHI-handling service is a HIPAA control failure even if no individual
developer "wrote" the leak. Flag the following:

- **API Gateway / ALB / NLB / CloudFront access logging** enabled on a
  route that exposes identifiers in the path or query string (`/api/
  beneficiary/{mbi}/claims`, `?ssn=...`, `?mbi=...`). Access logs capture
  the full request URI by default. Required mitigations: opaque IDs in
  URLs (preferred); or `access_log_settings` / `logging_config` configured
  to redact / omit the path component; or move the access-log destination
  to a stricter sink (see below). **NIST AC-23, AU-11.**
- **API Gateway stage logging at `INFO` / `DEBUG`** (`data_trace_enabled
  = true`, `logging_level = "INFO"` and above) on PHI-handling APIs — the
  full request and response payload is written to CloudWatch Logs. Allow
  only `ERROR` in production unless paired with an explicit redaction
  layer. **NIST SI-11, AU-3, HIPAA § 164.312(b).**
- **Lambda functions** without `LOG_LEVEL` pinned, or with environment
  variables like `DEBUG=true`, on PHI-handling functions — Lambda's
  default `print()` capture sends everything to CloudWatch. **NIST AU-3.**
- **CloudWatch Logs Insights / subscription filters** that forward logs
  to a downstream sink (Kinesis, OpenSearch, third-party SIEM, Splunk,
  Datadog) **without** a redaction processor in the path. The downstream
  sink often has weaker access controls than the original log group.
  **NIST AU-9, AC-3.**
- **S3 server access logs** on PHI buckets written to a target bucket
  that itself lacks: encryption (`server_side_encryption_configuration`),
  public-access blocks, and an Object Lock / retention policy distinct
  from the source bucket's. Access logs include full object keys —
  which often encode patient/beneficiary identifiers. **NIST AU-9, SC-28.**
- **VPC Flow Logs / Route 53 Resolver Query Logs** routed to a shared
  log bucket without separate access controls when traffic includes
  PHI-bearing internal services (DNS query logs leak service names that
  may include MBI hashes; flow logs leak source/dest pairs useful for
  re-identification). **NIST AU-9, AC-23.**
- **CloudTrail data events** enabled on S3 buckets / DynamoDB tables /
  Lambda functions that hold PHI without scoping `data_resource` to
  exclude object-key / partition-key fields that carry identifiers.
  CloudTrail records the resource ARN, which for S3 includes the object
  key. **NIST AU-9, HIPAA § 164.312(b).**
- **APM / observability provisioning** (Datadog, New Relic, X-Ray,
  OpenTelemetry collectors) configured with sampling that captures full
  span attributes / request headers on PHI-handling services. Flag the
  IaC resource that wires up the agent without an attribute filter or
  scrubber. **NIST SI-11, AC-23.**
- **Audit-log retention shorter than HIPAA's 6-year requirement**
  (§ 164.316(b)(2)(i)) on log groups / S3 buckets storing access-audit
  records for ePHI systems. **NIST AU-11, HIPAA § 164.316(b).**
- **Co-mingled application logs and audit logs** — a single CloudWatch
  log group receiving both application output and § 164.312(b) audit
  events. The audit stream needs stricter retention, access control, and
  KMS scope than the application stream. **NIST AU-9, AC-6.**

For each finding, cite the AU- / SI- / AC-family control ID (and the CMS
ARS 5.1 tailoring when it differs) and recommend the structural fix —
typically a separate, KMS-encrypted, access-controlled audit-sink
resource plus a redaction layer (subscription filter or Firehose
transform) on the application-log path. The remediation should be a
new / modified IaC resource, so use the `` ```hcl `` (or appropriate)
fence rather than `` ```suggestion ``.

---

## Severity Definitions (CMS/HIPAA additions only)

The baseline perspective's severity table already covers the
cross-referenced findings above. These apply to the CMS/HIPAA-specific
additions:

| Severity | Criteria |
|---|---|
| **Critical** | Unencrypted PHI/PII datastores; PHI identifiers captured in access logs with no redaction |
| **High** | No MFA on IAM users/console access; CMS/HIPAA log-content violations (§ 164.312(b), § 164.502(b)) |
| **Medium** | Missing VPC endpoints (SC-7); WAF absent on public endpoints (SC-5); Inspector/GuardDuty/Config/Security Hub absent (RA-5); audit-log retention shorter than HIPAA's 6-year requirement |
| **Low** | Pipeline source-integrity checks absent (SI-7 addendum) |
| **Informational** | (Do not report) |

Report all findings assessed as **low severity or above**; do not report
informational findings. The report format, JSON block, and result marker are
defined in the PR-review instructions — this perspective feeds findings into
that shared contract. In the report, list which controls were skipped as not
applicable to this diff, and why.

---

## Notes for Reviewers

- **Scope awareness:** This review covers the diff and targeted context only.
  It is not a full Terraform plan execution or a deployed-infrastructure scan.
  Dynamic values resolved at plan/apply time (e.g., from `var.*` or `data.*`
  that are not in loaded context) cannot be fully assessed — note limitations.
- **Multi-account/environment context:** If workspace or environment cannot be
  determined, apply the stricter production-level checks and note the assumption.
- **Not a plan replacement:** This review complements but does not replace
  `terraform plan`, `cfn-lint`, `checkov`, `tfsec`, or `kube-score`. Run those
  tools in CI alongside this review.
- **CMS ARS applicability:** ARS 5.1 applies to CMS systems and contractors.
  For non-CMS projects, the underlying NIST 800-53 Rev 5 controls still apply;
  the ARS column simply indicates the CMS tailoring.
