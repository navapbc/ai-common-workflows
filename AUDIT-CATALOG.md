# Security workflow audit — review catalog

Working document for the repository contents audit ("Security Workflow — Audit,
Testing, Improvements", 09/28/2026). Catalog of all security-workflow-related
files to review, enumerated from `git ls-files` at commit `6794397`.

**Scope** (per the audit doc): all documents, skills, and code relating to the
codebase-audit functionality and the security & compliance PR review (GitHub
Action front end), plus the native GitHub Copilot review (instructions and
instruction syncing). Tests are in scope at the lowest priority. The Jenkins
plugin is out of scope; the test-classifier workflow is a separate workflow and
is excluded per the doc's line-count appendix.

Total in scope: **126 files** (138 tracked outside `jenkins-plugin/`, minus 12 excluded below).

## Priority 1 — Engine (executes in the consumer's environment)

### Shared runtime (`engines/_common/`)

- [ ] engines/_common/CONTRACT.md
- [ ] engines/_common/endpoints.sh
- [ ] engines/_common/harness/core.sh
- [ ] engines/_common/harness/fold_review_json.py
- [ ] engines/_common/harness/gate_verdict.py
- [ ] engines/_common/harness/write_audit_report.py
- [ ] engines/_common/scm/github.sh
- [ ] engines/_common/scm/github_payload.py

### Review engine (`engines/security-compliance-review/`)

- [ ] engines/security-compliance-review/README.md
- [ ] engines/security-compliance-review/harness/ai-security-compliance-audit
- [ ] engines/security-compliance-review/harness/ai-security-compliance-review
- [ ] engines/security-compliance-review/skills/base/code-security.md
- [ ] engines/security-compliance-review/skills/base/codebase-audit.md
- [ ] engines/security-compliance-review/skills/base/finding-adjudication.md
- [ ] engines/security-compliance-review/skills/base/iac-compliance.md
- [ ] engines/security-compliance-review/skills/base/pr-review.md
- [ ] engines/security-compliance-review/skills/profiles/cms-ars-5.1/iac-compliance.md

## Priority 2 — GitHub Action front end

- [ ] workflows/security-compliance-review/action.yml
- [ ] workflows/_shared/lib/ci.sh

## Priority 3 — Copilot instructions and syncing

- [ ] copilot-instructions/README.md
- [ ] copilot-instructions/base/instructions/ai-review-auth.instructions.md
- [ ] copilot-instructions/base/instructions/ai-review-iac.instructions.md
- [ ] copilot-instructions/base/instructions/ai-review-scripts.instructions.md
- [ ] copilot-instructions/base/instructions/ai-review-security.instructions.md
- [ ] copilot-instructions/profiles/baseline/README.md
- [ ] copilot-instructions/profiles/cms-ars-5.1/instructions/ai-review-auth-additions.instructions.md
- [ ] copilot-instructions/profiles/cms-ars-5.1/instructions/ai-review-iac-additions.instructions.md
- [ ] copilot-instructions/profiles/cms-ars-5.1/instructions/ai-review-security-additions.instructions.md
- [ ] examples/workflows/copilot-instructions-sync.yml

## Priority 4 — Consumer examples (what adopters copy)

- [ ] examples/workflows/ai-security-compliance-review.yml
- [ ] examples/workflows/ai-security-compliance-review-azure.yml
- [ ] examples/workflows/ai-security-compliance-review-bedrock.yml
- [ ] examples/workflows/ai-security-compliance-review-gating.yml
- [ ] examples/workflows/ai-security-compliance-review-manual.yml

## Priority 5 — Documentation

- [ ] README.md
- [ ] SECURITY.md
- [ ] CLAUDE.md
- [ ] CHANGELOG.md
- [ ] docs/adding-workflows.md
- [ ] docs/architecture.md
- [ ] docs/codebase-audit.md
- [ ] docs/copilot-instructions.md
- [ ] docs/copilot-review-setup.md
- [ ] docs/github-action.md
- [ ] docs/private-endpoints.md
- [ ] docs/profiles.md
- [ ] docs/releasing.md
- [ ] docs/security-compliance-review.md
- [ ] docs/security.md
- [ ] docs/adr/README.md
- [ ] docs/adr/0001-distribute-the-audit-via-homebrew.md
- [ ] docs/adr/0002-remove-the-experimental-egress-sandbox.md

## Priority 6 — Repo config / CI

- [ ] .gitattributes
- [ ] .gitignore
- [ ] .github/CODEOWNERS
- [ ] .github/dependabot.yml
- [ ] .github/secret_scanning.yml
- [ ] .github/workflows/ci.yml
- [ ] .github/workflows/release.yml

## Priority 7 — Tests (lowest priority per the audit doc)

### Harness, lint, stubs

- [ ] tests/run.sh
- [ ] tests/lint_workflow_shell.sh
- [ ] tests/stubs/claude
- [ ] tests/stubs/codex
- [ ] tests/stubs/copilot
- [ ] tests/stubs/gh

### Bats

- [ ] tests/bats/helpers.bash
- [ ] tests/bats/audit.bats
- [ ] tests/bats/ci_shared.bats
- [ ] tests/bats/core.bats
- [ ] tests/bats/e2e.bats
- [ ] tests/bats/release.bats

### Python

- [ ] tests/python/test_action_pr_context.py
- [ ] tests/python/test_cli_pin_hygiene.py
- [ ] tests/python/test_corpus_score.py
- [ ] tests/python/test_dependabot_coverage.py
- [ ] tests/python/test_doc_links.py
- [ ] tests/python/test_entrypoint_invariants.py
- [ ] tests/python/test_example_workflows.py
- [ ] tests/python/test_floor_is_framework_neutral.py
- [ ] tests/python/test_fold_review_json.py
- [ ] tests/python/test_gate_verdict.py
- [ ] tests/python/test_github_payload.py
- [ ] tests/python/test_inline_limit_default.py
- [ ] tests/python/test_no_built_in_sandbox.py
- [ ] tests/python/test_pin_hygiene.py
- [ ] tests/python/test_profile_naming.py
- [ ] tests/python/test_release_surface.py
- [ ] tests/python/test_secret_fixtures.py

### Fixtures (security review)

- [ ] tests/fixtures/response-adjudicated-empty.txt
- [ ] tests/fixtures/response-approve.txt
- [ ] tests/fixtures/response-comment.txt

### Corpus (rubric quality fixtures)

- [ ] tests/corpus/README.md
- [ ] tests/corpus/run.sh
- [ ] tests/corpus/score.py
- [ ] tests/corpus/01-hardcoded-aws-key/case.md
- [ ] tests/corpus/01-hardcoded-aws-key/expected.json
- [ ] tests/corpus/01-hardcoded-aws-key/head/src/config.py
- [ ] tests/corpus/02-sql-injection-fstring/case.md
- [ ] tests/corpus/02-sql-injection-fstring/expected.json
- [ ] tests/corpus/02-sql-injection-fstring/base/src/users.py
- [ ] tests/corpus/02-sql-injection-fstring/head/src/users.py
- [ ] tests/corpus/03-sql-already-parameterized/case.md
- [ ] tests/corpus/03-sql-already-parameterized/expected.json
- [ ] tests/corpus/03-sql-already-parameterized/base/src/users.py
- [ ] tests/corpus/03-sql-already-parameterized/head/src/users.py
- [ ] tests/corpus/04-rds-unencrypted/case.md
- [ ] tests/corpus/04-rds-unencrypted/expected.json
- [ ] tests/corpus/04-rds-unencrypted/head/infra/rds.tf
- [ ] tests/corpus/05-rds-encrypted-cmk/case.md
- [ ] tests/corpus/05-rds-encrypted-cmk/expected.json
- [ ] tests/corpus/05-rds-encrypted-cmk/head/infra/rds.tf
- [ ] tests/corpus/06-phi-in-logs/case.md
- [ ] tests/corpus/06-phi-in-logs/expected.json
- [ ] tests/corpus/06-phi-in-logs/base/src/enroll.py
- [ ] tests/corpus/06-phi-in-logs/head/src/enroll.py
- [ ] tests/corpus/07-missing-authz/case.md
- [ ] tests/corpus/07-missing-authz/expected.json
- [ ] tests/corpus/07-missing-authz/base/src/api/claims.py
- [ ] tests/corpus/07-missing-authz/head/src/api/claims.py
- [ ] tests/corpus/08-benign-refactor/case.md
- [ ] tests/corpus/08-benign-refactor/expected.json
- [ ] tests/corpus/08-benign-refactor/base/src/totals.py
- [ ] tests/corpus/08-benign-refactor/head/src/totals.py
- [ ] tests/corpus/09-aws-doc-example-key/case.md
- [ ] tests/corpus/09-aws-doc-example-key/expected.json
- [ ] tests/corpus/09-aws-doc-example-key/head/src/example_snippet.py

## Excluded

| Files | Reason |
|---|---|
| jenkins-plugin/** (entire tree) | Jenkins plugin explicitly out of scope |
| .github/workflows/jenkins-plugin.yml | CI job that only builds the Jenkins plugin |
| engines/test-classifier/** (3 files) | Separate workflow (test classifier) |
| workflows/test-classifier/action.yml | Test-classifier front end |
| examples/workflows/ai-test-classifier.yml | Test-classifier example |
| docs/test-classifier.md | Test-classifier docs |
| tests/bats/test_classifier.bats | Test-classifier tests |
| tests/fixtures/classifier-response-*.txt (3 files) | Test-classifier fixtures |
| LICENSE | Not review material |
