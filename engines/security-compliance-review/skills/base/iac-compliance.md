# IaC Compliance Perspective

A framework-neutral infrastructure-as-code security review. It applies
widely-recognized cloud security best practices — **CIS Benchmarks**, the
**NIST Cybersecurity Framework (CSF)**, and **OWASP** guidance — to the changes
in a pull request. This is the compliance floor: it always applies,
regardless of which `profile` is selected.

A profile may layer additional, framework-specific checks on top of this
(e.g. `cms-ars` adds CMS ARS 5.1 / NIST SP 800-53 Rev 5 control-ID citations
and CMS/HIPAA-specific checks). When it does, that addition is included
immediately after this perspective in the prompt and takes precedence over
this file on any conflict — see [docs/profiles.md](../../../../docs/profiles.md).

Apply it to the PR diff; the output contract (report format, JSON block, result
marker) is defined in the PR-review instructions that accompany this perspective
in the same prompt.

---

## Step 1 — Collect Changes

Review the PR diff between the base ref and HEAD:

```bash
git diff "$AI_REVIEW_AGAINST" HEAD --unified=5      # full content
git diff "$AI_REVIEW_AGAINST" HEAD --name-only      # list of changed paths
```

(When `AI_REVIEW_SCOPE_PATHS` is set, restrict to those files — see the
PR-review instructions.)

If none of the changed files are recognisable IaC, this perspective does not
apply — note that in the report and move on.

**Recognised IaC file patterns:**
- Terraform: `.tf`, `.tfvars`, `.tf.json`
- CloudFormation: `*.template.json`, `*.template.yaml`
- Bicep: `*.bicep`, `*.bicepparam`
- Pulumi: `Pulumi.yaml`, `Pulumi.*.yaml`
- Ansible: `*.yml`/`*.yaml` under `roles/` or `playbooks/`
- Kubernetes: any YAML containing both `apiVersion:` and `kind:`
- Helm: `Chart.yaml`, `values.yaml`, `templates/`
- CDK: `cdk.json`, `app.py`/`app.ts` when paired with `cdk.json`
- Terragrunt / Packer: `*.hcl`

---

## Step 2 — Detect IaC Type and Load Targeted Context

Identify which IaC tool(s) and cloud(s) are in use from file extensions and
directory structure; that determines which checks apply. Load only what you
need to assess the diff (limit: the `AI_REVIEW_CONTEXT_BUDGET` ceiling, default
15 files): variable/values files, backend/provider config, referenced modules,
and existing IAM/security-group/network rules the diff modifies. Do **not** load
lock files, provider plugins, generated plans, or documentation.

---

## Step 3 — Baseline Control Checks

Apply the checks below to the diff and loaded context. Skip categories with no
plausible attack surface in the change (e.g., skip encryption-at-rest if only a
DNS record changed) and say what you skipped and why. Each check cites the
general control theme (CIS / NIST CSF Function) rather than a specific catalog
ID.

### Identity & Access (NIST CSF: PROTECT / PR.AC — least privilege)
- IAM policies with wildcard actions (`"Action": "*"`) or unscoped
  `"Resource": "*"` without a `Condition`
- Roles granted `AdministratorAccess` or equivalent broad managed policies
- `sts:AssumeRole` allowed without `Condition` constraints
- S3 bucket policies granting `s3:*` to `"Principal": "*"` (public write)
- Shared/generic account names (`admin`, `root`, `shared`) in new resources
- Human IAM users with static access keys instead of roles / federation

### Network Exposure (CIS: network; NIST CSF: PR.AC-5 / PR.PT-4)
- Security groups or NACLs allowing inbound `0.0.0.0/0` or `::/0` on:
  - SSH (22), RDP (3389), or all traffic (`-1`) — Critical
  - Database ports (3306, 5432, 27017, 6379, 9200/9300, 9042) — High
- Public-facing management endpoints / bastions without IP restriction
- Datastores reachable from the internet (`publicly_accessible = true` on RDS,
  public OpenSearch/Elasticsearch, EC2/LB in public subnets without reason)
- Containers with `hostNetwork: true` / `network_mode = "host"`

### Data Protection (CIS: encryption; NIST CSF: PR.DS — data-at-rest/in-transit)
- Storage without encryption at rest: S3 (`server_side_encryption_configuration`
  absent), EBS (`encrypted = false`), RDS (`storage_encrypted = false`), EFS,
  SNS/SQS, Secrets Manager
- Prefer customer-managed KMS keys over provider defaults for sensitive data
  (infer sensitivity from names: `pii`, `data`, `backup`, `audit`, `secret`)
- Transport without TLS: LB listeners on port 80 without HTTPS redirect,
  HTTP API Gateway stages, node-to-node encryption disabled
- Hardcoded passwords/secrets in resources (`password =`, `master_password =`);
  secrets not sourced from a secret manager / parameter store
- KMS key rotation disabled (`enable_key_rotation = false`)

### Logging & Monitoring (CIS: logging; NIST CSF: DETECT / DE.AE, DE.CM)
- Audit/flow logging disabled: CloudTrail off or single-region, VPC Flow Logs
  absent, EKS control-plane logging off, access logging off on sensitive buckets
- Log destinations without encryption or a retention period
- No alarms/anomaly detection provisioned alongside new sensitive resources
- **Sensitive-data-in-logs risk:** access/APM logging enabled on routes or
  payloads that carry identifiers in URLs/bodies without a redaction layer, and
  log sinks with weaker access controls than the source

### Configuration Hygiene (CIS: config; NIST CSF: PR.IP — baselines)
- Containers running as root (`runAsNonRoot: false`/absent, `runAsUser: 0`),
  `privileged: true`, `allowPrivilegeEscalation: true`, `hostPID`/`hostIPC`
- Container images tagged `latest` rather than a pinned digest/version
- `deletion_protection = false` / `force_destroy = true` on production
  datastores; `skip_final_snapshot = true`
- Modules used without pinned `version` constraints
- Missing ownership/inventory tags (`Environment`, `Owner`, `Project`)

### Resilience & Integrity (NIST CSF: RECOVER / RC, PROTECT / PR.DS-6)
- Backups disabled: RDS `backup_retention_period = 0`, DynamoDB PITR off,
  EBS not in a backup plan
- State/artifact buckets without object versioning
- Deprecated/end-of-life runtimes (e.g. `nodejs14.x`, `python3.7/3.8`,
  `ruby2.7`, `java8`, `go1.x`, `dotnetcore3.1`)
- No image scanning on push for ECR/registries

---

## Severity Definitions

| Severity | Criteria |
|---|---|
| **Critical** | Public exposure of management ports (SSH/RDP); IAM wildcard with no conditions; unencrypted sensitive datastores; all S3 public-access blocks disabled; publicly accessible databases |
| **High** | Admin IAM policies; open database ports to the internet; encryption at rest disabled; audit logging disabled; hardcoded secrets; deprecated runtimes; deletion protection off in production |
| **Medium** | Missing private connectivity (VPC endpoints); default KMS key instead of CMK; log retention unset; monitoring gaps; tagging gaps (2+ required tags) |
| **Low** | Minor tagging gaps; `latest` image tag; module without pinned version; missing name/description on non-critical resources |
| **Informational** | (Do not report) |

Report all findings assessed as **low severity or above**. In the report, list
which categories were skipped as not applicable to this diff, and why.

---

## Notes for Reviewers

- **Scope:** the diff and targeted context only — not a full plan execution or a
  deployed-infrastructure scan. Note where dynamic (`var.*`/`data.*`) values
  prevent a full assessment.
- **Not a tool replacement:** complements but does not replace `checkov`,
  `tfsec`, `cfn-lint`, `kube-score`, or a CSPM. Run those in CI too.
- **Bound to a specific framework?** Use the `cms-ars` profile for CMS ARS 5.1 /
  NIST 800-53 Rev 5 control mapping (layered on top of this file, not instead
  of it), or add a profile under `skills/profiles/` (see docs/profiles.md).
