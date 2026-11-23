# Security Review Summary (Priority 1)

Date: 2026-11-23  
Scope: `engines/security-compliance-review/` Priority 1 files from `AUDIT-CATALOG.md`

## Completed in this branch

- **A-011 fixed**: `pr_review::require_json` now rejects missing and malformed JSON for all markers.
- Added regression tests in `tests/python/test_review_json_required.py` for:
  - APPROVE without JSON (fails)
  - COMMENT without JSON (fails)
  - Malformed JSON block (fails)
  - Valid APPROVE fixture (passes)

## Open confirmed findings

| ID | Severity | File | Lines | Summary |
|---|---|---|---|---|
| A-012 | High | `engines/security-compliance-review/harness/ai-security-compliance-review` | 649-674 | Marker/JSON/action mismatch can bypass or misreport adjudication. |
| A-013 | High | `engines/security-compliance-review/harness/ai-security-compliance-review` | 695-704 | Independent adjudication can add/remove/escalate findings without guardrails. |
| A-014 | High | `engines/security-compliance-review/harness/ai-security-compliance-audit` | 306-309 | Tracked symlink can include outside-repo file content in audit scope. |
| A-015 | High | `engines/security-compliance-review/harness/ai-security-compliance-audit` | 398-406 | IaC detector misses advertised formats, skipping compliance checks. |
| A-016 | High | `engines/security-compliance-review/harness/ai-security-compliance-audit` | 755-785 | `--resume` can skip new/changed files and report stale completion. |
| A-017 | High | `engines/security-compliance-review/harness/ai-security-compliance-audit` | 438-445, 920-933 | Audit marker/action mismatch can pass contradictory responses. |
| A-020 | High | `ai-security-compliance-review`; `ai-security-compliance-audit` | 277-284; 306,451-457 | Delimiter/newline filename handling can corrupt worker file scope. |
| A-001 | Medium | `engines/security-compliance-review/skills/base/pr-review.md` | 33,241 | `--gate` docs conflict with actual HIGH/CRITICAL-only blocking behavior. |
| A-002 | Medium | `engines/security-compliance-review/skills/base/pr-review.md` | 162,225 | Base-profile examples cite framework controls that require a loaded profile. |
| A-003 | Medium | `engines/security-compliance-review/skills/base/pr-review.md` | 77-80 | PR-side IaC routing omits formats included by baseline. |
| A-004 | Medium | `engines/security-compliance-review/skills/base/code-security.md` | 110-113 | MBI examples conflict with stated format rules. |
| A-007 | Medium | `engines/security-compliance-review/skills/base/finding-adjudication.md` | 37-40 | Adjudication instructions assume PR diff in codebase-audit mode. |
| A-018 | Medium | `engines/security-compliance-review/harness/ai-security-compliance-audit` | 868-901, 942-950, 995-1002 | Fan-out/adjudication narrative output can be missing or stale. |
| A-019 | Medium | `engines/security-compliance-review/harness/ai-security-compliance-audit` | 732-742, 830-868, 954-960 | `--output-parent-dir` writability checked only after model invocation. |
| A-021 | Medium | `engines/security-compliance-review/harness/ai-security-compliance-audit` | 324-340 | Skipped-file reasons are not persisted in coverage/index outputs. |

## Provisional findings (authority verification pending)

- **A-005, A-006, A-008, A-009, A-010** are unresolved pending authoritative standards/service documentation checks (tracked under EX-STD-001).

## Follow-up action plan

1. **High-risk correctness fixes first (A-012, A-013, A-017):**
   - Add shared strict tuple validation for marker + `review_action` + findings cardinality.
   - Add adjudication constraints to reject introduced/escalated findings without mapping to original items.
2. **Scope and coverage hardening (A-014, A-015, A-016, A-020, A-021):**
   - Enforce in-repo regular-file checks (no outside-target symlink ingestion).
   - Move batch/path handling to NUL-safe records end-to-end.
   - Replace directory-level `--resume` skipping with per-file identity/fingerprint checks.
   - Persist skip reasons in report/index artifacts.
3. **Output and contract clarity (A-018, A-019, A-001, A-002, A-003, A-004, A-007):**
   - Persist final adjudicated narrative reliably.
   - Validate output destination before any model call.
   - Align docs/prompts/examples with actual behavior and profile rules.
4. **Close provisional items (A-005, A-006, A-008, A-009, A-010):**
   - Perform standards/API source verification and either confirm or retire each claim.

## Verification run for this branch

- `pytest -q -p no:cacheprovider tests/python/test_review_json_required.py` → **4 passed**
- `bash tests/run.sh` partially completed (`pytest` 376 passed, 1 skipped), then stopped because `bats` is not installed in this environment.
