# ai-common-workflows

> **Status:** Under active development. Interfaces and behavior may change without notice.

Reusable, AI-assisted CI/CD workflows you can drop into any pipeline. This repo
is a **collection** of independent workflows that share a small set of
conventions — pin to a commit SHA, run least-privilege, keep each concern in
its own self-contained engine — so teams can adopt them one at a time.

## Workflows in this repo

| Workflow | What it does | Docs |
|---|---|---|
| **AI security & compliance review** | Security & compliance review of a pull request: inline comments for secrets, PII/PHI, OWASP Top 10, and IaC misconfigurations. Compliance checks always include a generic `baseline`; a selectable [profile](docs/profiles.md) can add a specific framework on top — CMS ARS 5.1 / NIST SP 800-53 out of the box, or bring your own. | [docs/security-compliance-review.md](docs/security-compliance-review.md) |
| **AI test classifier** | Triage of failing tests on a pull request: classifies each failure as `APPLICATION_BUG` / `TEST_BUG` / `FLAKY_FAILURE` / `ENVIRONMENT_ISSUE` — is the test wrong or the code wrong? — and posts one advisory comment with a 👍/👎 feedback ask. Diagnostic only; never edits code or tests. | [docs/test-classifier.md](docs/test-classifier.md) |

More workflows will land here over time. Each one is meant to stand alone — you
adopt only the ones you need. **Adding a workflow?** See the conventions in
[docs/adding-workflows.md](docs/adding-workflows.md).

---

## Security & supply chain

These components execute code in your CI with your repository and credentials
in scope. Before adopting, three things are imperative:

- **Least privilege.** Scope the SCM token to `contents: read` +
  `pull-requests: write` (Action) or a fine-grained PAT / GitHub App (Jenkins);
  scope Bedrock/Vertex/Azure to invoking the one model or deployment. Details in
  [docs/security.md](docs/security.md).
- **Review the engine** — it's deliberately small (a few hundred lines of bash
  plus two short Python files) — and **pin to a commit SHA**, not a mutable tag.
- **Control egress** at the runner/infrastructure layer; there is no built-in
  sandbox in this release.

Full trust model and checklist in [docs/security.md](docs/security.md).

## License

[Apache-2.0](LICENSE).
