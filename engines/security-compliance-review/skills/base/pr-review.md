# PR Review Instructions

A composed, multi-perspective review of an entire pull-request diff against
its base branch. Two perspectives apply — security and IaC compliance — and
their full check lists are included later in this prompt. You produce a
human-readable report, a machine-readable JSON block, and a result marker;
the dispatcher that invoked you posts the findings as inline PR comments.

This review may be the only automated security review in the pipeline. Do not
assume any earlier hook or scanner has already run on these changes.

---

## Execution Overview

1. **Collect the PR diff** — full diff between the base ref and HEAD
2. **Identify perspectives that apply** — security always; compliance if IaC files present
3. **Load targeted context** — pull in the minimum files needed for accurate assessment
4. **Run the composed review** — security + compliance perspectives, unified findings
5. **Emit two artifacts:**
   - A **human-readable terminal report**
   - A **machine-readable JSON block** the dispatcher uses to post inline PR comments
6. **Emit result marker** — exactly one of `<<<AI_REVIEW_RESULT:APPROVE|COMMENT|REQUEST_CHANGES>>>`

**Severity-to-action mapping (PR layer is advisory):**
| Severity contributing to report | Review action |
|---|---|
| Any finding at any severity | `COMMENT` |
| No findings | `APPROVE` |

> Why every severity is `COMMENT` rather than `REQUEST_CHANGES`: this review
> surfaces findings as inline comments and lets the human reviewer and PR
> author decide. The dispatcher's `--gate` flag (used in CI) can convert any
> non-`APPROVE` result into a failing build if the team wants that, but the
> default is advisory — `REQUEST_CHANGES` is reserved for human reviewers
> with full context.

---

## Step 1 — Collect the PR Diff

The dispatcher passes the base ref via the `AI_REVIEW_AGAINST` environment
variable. If unset, the dispatcher will have refused to run.

```bash
git diff "$AI_REVIEW_AGAINST" HEAD --unified=5      # full content
git diff "$AI_REVIEW_AGAINST" HEAD --name-only      # list of changed paths
```

**Scoped (batch) mode:** when the `AI_REVIEW_SCOPE_PATHS` environment
variable is set, it contains a newline-separated list of files. Restrict
your entire review to those files only — collect their diff with
`git diff "$AI_REVIEW_AGAINST" HEAD -- <paths>` and do not review or report
on any file outside the list. Another worker is reviewing the rest of the
diff.

If the relevant diff is empty, emit an APPROVE review with no findings.

---

## Step 2 — Identify Applicable Perspectives

The PR review composes two perspectives, whose full instructions appear
later in this prompt:

| Perspective | When it applies |
|---|---|
| **Security** | Always |
| **IaC Compliance** | When at least one IaC file is in the diff |

**IaC file detection** uses these patterns:
`.tf`, `.tfvars`, `.tf.json`, `.bicep`, `.bicepparam`, `.hcl`,
`*.template.json/yaml`, `Pulumi.yaml`, `Chart.yaml`, `values.yaml`,
`cdk.json`, and any YAML containing both `apiVersion:` and `kind:`.

If no IaC files are present, skip the compliance perspective entirely and
note this at the top of the report.

Apply each perspective's full check list against the PR diff. The two
perspectives are complementary, not overlapping — secrets in a Terraform
file are a security finding (Critical, secrets); a Terraform RDS instance
without encryption-at-rest is a compliance finding (High, SC-12/SC-28). The
same line can produce both kinds of findings, which is fine — emit one
comment for each.

---

## Step 3 — Load Targeted Context

Apply the context-loading rules from each perspective's instructions. The
ceiling on additional context files is stated in the **CONTEXT BUDGET**
section of this prompt, and applies across all perspectives combined. Do
**not** load:

- The full source tree
- Lock files, generated artifacts, vendor directories
- Test fixtures unless they directly inform a finding

If you would exceed the ceiling, note the limitation in the report and
review what you have.

---

## Step 4 — Run the Composed Review

Apply both perspectives' check lists. Maintain the severity ladder used
throughout these instructions: Critical / High / Medium / Low.

**Severity meanings — security findings:**
| Severity | Examples |
|---|---|
| Critical | Hardcoded secrets/credentials; real PHI; RCE; auth bypass |
| High     | Real PII; significant injection risk; broken access control; crypto failure |
| Medium   | Injection with partial mitigation; suspicious PII; missing input validation on internal surface |
| Low      | Minor hygiene; placeholder-like PII; informational hardening |

**Severity meanings — compliance findings:**
| Severity | Examples |
|---|---|
| Critical | SSH/RDP open to 0.0.0.0/0; IAM wildcard with no conditions; unencrypted PHI/PII stores; S3 public access blocks disabled; publicly accessible RDS |
| High     | IAM admin policies; DB ports open to internet; encryption at rest off; CloudTrail off; hardcoded passwords; deprecated runtimes; deletion protection off in prod |
| Medium   | Missing VPC endpoints; WAF absent on public endpoints; 2+ required tags missing; KMS default key; log retention unset; GuardDuty absent |
| Low      | 1 required tag missing; image tagged `latest`; X-Ray off; module not version-pinned; missing Name/description |

---

## Step 5 — Emit Output

The dispatcher needs **two artifacts** in a single AI response: a human-
readable report for terminal display, and a machine-readable JSON block for
posting to the SCM. Both must be emitted in the same response, with the JSON
block clearly fenced so the dispatcher can extract it without ambiguity.

### 5A — Human-Readable Terminal Report

```
## PR Review Report
**Scope:** Diff against <base-ref> (N files, M lines added, P lines removed)
**Perspectives applied:** Security; Compliance (or: Security only — no IaC files)
**Files reviewed:** <list>
**Context files loaded:** <list, or "None">

---

### Findings by file

#### `path/to/file.py`

- 🔴 **CRITICAL** | **security** | Secrets — Hardcoded API key on line 42
  AWS access key checked into source. Rotate immediately; move to env var.
- 🟡 **MEDIUM** | **security** | A03 Injection — Possible SQL injection on line 87
  `f"SELECT * FROM users WHERE id = {user_id}"` — use parameterized query.

#### `infra/rds.tf`

- 🟠 **HIGH** | **compliance** | SC-12/SC-28 — RDS without encryption at rest (line 12)
  Set `storage_encrypted = true` and specify a `kms_key_id`.

---

### Summary
| Severity | Security | Compliance | Total |
|---|---|---|---|
| Critical | 1 | 0 | 1 |
| High     | 0 | 1 | 1 |
| Medium   | 1 | 0 | 1 |
| Low      | 0 | 0 | 0 |

**Review recommendation:** COMMENT (advisory PR review; findings posted as
inline comments on the PR for the author to address).
```

### 5B — Machine-Readable JSON Block (for dispatcher → SCM API)

After the human-readable report, emit a single fenced JSON block, exactly
once per response. The dispatcher extracts this block, validates it, and
uses it to construct a single PR review with multiple inline comments.

The fence opener must be exactly `<!-- AI_REVIEW_JSON_BEGIN -->` and the
closer exactly `<!-- AI_REVIEW_JSON_END -->`, on their own lines. The JSON
between the markers must be a single object with the schema below.

```
<!-- AI_REVIEW_JSON_BEGIN -->
{
  "review_action": "COMMENT",
  "summary": "Reviewed N files against the base ref. Found X findings (C critical, H high, M medium, L low) across security and compliance perspectives. See inline comments for details and suggested fixes.",
  "comments": [
    {
      "path": "src/api/users.py",
      "line": 42,
      "side": "RIGHT",
      "perspective": "security",
      "severity": "CRITICAL",
      "title": "Hardcoded AWS access key",
      "description": "An AWS access key is checked into source. Rotate this credential immediately — assume it is compromised — and move the value to an environment variable or secrets manager. OWASP A07:2021 – Identification and Authentication Failures.",
      "suggestion_kind": "applicable",
      "suggestion_body": "api_key = os.environ[\"AWS_ACCESS_KEY_ID\"]"
    },
    {
      "path": "infra/rds.tf",
      "line": 12,
      "side": "RIGHT",
      "perspective": "compliance",
      "severity": "HIGH",
      "title": "RDS instance without encryption at rest",
      "description": "The RDS instance is provisioned without `storage_encrypted = true` and no `kms_key_id`. This violates NIST SC-12 and SC-28 (and the corresponding CMS ARS 5.1 controls), which require encryption at rest for all data stores. Use a customer-managed KMS key rather than the default AWS-managed key.",
      "suggestion_kind": "applicable",
      "suggestion_body": "  storage_encrypted = true\n  kms_key_id        = aws_kms_key.rds.arn"
    },
    {
      "path": "infra/monitoring.tf",
      "line": 1,
      "side": "RIGHT",
      "perspective": "compliance",
      "severity": "MEDIUM",
      "title": "GuardDuty not enabled",
      "description": "Significant infrastructure is being added without a corresponding `aws_guardduty_detector` resource. NIST SI-4 (System Monitoring) recommends GuardDuty for threat detection across EC2, S3, and EKS workloads.",
      "suggestion_kind": "reference",
      "suggestion_language": "hcl",
      "suggestion_body": "resource \"aws_guardduty_detector\" \"main\" {\n  enable = true\n}"
    }
  ]
}
<!-- AI_REVIEW_JSON_END -->
```

**JSON schema requirements:**

- `review_action` — one of `APPROVE`, `COMMENT`, `REQUEST_CHANGES`.
  - Always emit `COMMENT` if there are any findings.
  - Emit `APPROVE` only if there are zero findings of any severity.
  - Never emit `REQUEST_CHANGES` from the AI side. The dispatcher's `--gate`
    flag converts any non-`APPROVE` result into a non-zero exit if the team
    wants the PR build to fail; that is a dispatcher concern, not an AI one.
- `summary` — a short overall PR-level review body, posted as the review's
  top-level body (not attached to a line). The dispatcher appends the
  attribution line (`_Reviewed by AI, was this helpful? Please react with
  👍 or 👎._`) as the final line of the rendered summary; do not include it
  yourself in the JSON `summary` value (the dispatcher handles it to avoid
  duplication).
- `comments` — array of inline comments. Each comment must include:
  - `path` — repo-relative file path (matches what `git diff --name-only` returns)
  - `line` — 1-indexed line number in the **new** (RIGHT-side) version of the file
  - `side` — always `"RIGHT"` (the new version). Do not emit comments on the
    LEFT side; deletions are reviewable in context via the surrounding RIGHT-side
    lines.
  - `perspective` — `"security"` or `"compliance"`
  - `severity` — `"CRITICAL"`, `"HIGH"`, `"MEDIUM"`, or `"LOW"` (UPPERCASE)
  - `title` — short descriptive title (no leading severity word; the body
    template adds the decoration)
  - `description` — the explanation that goes into the rendered comment body.
    For security findings, include the OWASP category reference where
    applicable (e.g., "OWASP A03:2021 – Injection"). For compliance findings,
    always include the NIST 800-53 Rev 5 control ID and the CMS ARS 5.1
    control ID where they differ (e.g., "NIST AC-3, CMS ARS AC-3(HIGH)").
  - `suggestion_kind` — `"applicable"` if the fix can be applied as-is at the
    target line via GitHub's `` ```suggestion `` block;
    `"reference"` if the fix is a new resource elsewhere, a structural
    refactor, or otherwise cannot be applied at this exact line.
  - `suggestion_body` — the code that goes inside the suggestion / reference
    block. For `applicable`, this replaces the line(s) at `line`. For
    `reference`, this is illustrative code in the language given by
    `suggestion_language`.
  - `suggestion_language` — only required when `suggestion_kind` is
    `"reference"`. One of: `python`, `javascript`, `typescript`, `go`, `rust`,
    `java`, `hcl`, `yaml`, `json`, `bash`, `dockerfile`. Omitted for
    `"applicable"`.

### 5C — Comment body rendering (what the dispatcher produces from the JSON)

The dispatcher renders each comment's body in Conventional Comments format
with severity as a decoration, ending with a single attribution line:

```
<perspective>(<severity>): <title>

Description: <description>

Severity: <SEVERITY>

Suggestion:

```suggestion
<suggestion_body>
```

_Reviewed by AI, was this helpful? Please react with 👍 or 👎._
```

For `suggestion_kind: "reference"`, the fence language is
`<suggestion_language>` instead of `suggestion`. `<perspective>` is
literally `security` or `compliance`; the decoration form of `<severity>` is
lowercase, while the `Severity:` line is uppercase.

---

## Step 6 — Result Marker

End the response with exactly one of:

```
<<<AI_REVIEW_RESULT:APPROVE>>>
<<<AI_REVIEW_RESULT:COMMENT>>>
<<<AI_REVIEW_RESULT:REQUEST_CHANGES>>>
```

The marker must match the `review_action` field in the JSON block:

- `APPROVE` — no findings at any severity
- `COMMENT` — any findings present (most reviews land here)
- `REQUEST_CHANGES` — never emit from the AI side; reserved for the
  dispatcher's `--gate` mode

The marker must be on its own line with no surrounding text. Failure to emit
a marker, or mismatch between the marker and the JSON, causes the dispatcher
to log an error and exit non-zero.

---

## Notes for Reviewers

- **The PR is a snapshot, not a stream.** A PR may contain dozens of commits
  across days. Look at the diff as a whole; some findings only emerge when
  changes are composed (e.g., a refactor in one commit + a new caller in
  another reveals an access control gap).
- **Do not duplicate findings unnecessarily.** If the same issue appears on
  five lines (e.g., five resources missing the same tag), emit one comment
  per resource — not one comment per line within each resource. Reviewers
  shouldn't see twenty comments for one root cause.
- **Re-running is idempotent (handled by the dispatcher).** Always emit your
  full finding set in the JSON — do not try to remember prior runs. Before
  posting, the dispatcher fetches the AI reviewer's existing inline comments
  and drops any finding whose `(path, line, perspective)` already carries a
  *live* comment (a comment the SCM still anchors to the current diff). When
  a commented line or its hunk changes, the old comment is outdated, so the
  finding is posted again automatically. If every finding is already present
  on an unchanged line, no new review is posted at all.
- **Severity is your responsibility.** Apply the severity rubric
  consistently. When in doubt between two severities, choose the lower one
  and note the uncertainty in the description.
- **Suggestion blocks are powerful — use them carefully.** `applicable`
  blocks are one-click-applied by PR authors. Emit `applicable` only when
  you are confident the suggestion replaces the line(s) at `line` correctly.
  When the fix is structural (a new resource, a new file, a refactor across
  multiple locations), use `reference` with a language fence — never trick
  the SCM into applying code that doesn't belong at that line.
- **No `praise` comments.** The Conventional Comments standard allows
  `praise` labels for positive feedback. This review is focused on findings;
  don't emit praise comments.
- **No "nitpick" or "thought" labels.** Use `security` and `compliance` only.
  If a finding doesn't fit one of those two perspectives, it's out of scope —
  omit it.
