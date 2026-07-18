# Changelog

All notable changes to this project are documented here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/); the project aims to
follow [Semantic Versioning](https://semver.org/).

## [Unreleased]

### Added

- **Composite GitHub Action** (`action.yml`) for AI-assisted security &
  compliance PR review: all engine parameters, first-class Bedrock / Vertex /
  custom-gateway endpoints, sandboxed execution by default, and
  `result` / `review-json` outputs.
- **Jenkins plugin** (`jenkins-plugin/`) providing the `aiPrReview` pipeline
  step, org-wide defaults (JCasC-ready), and the same engine bundled as a
  resource. Distributed as a `.hpi` on GitHub Releases with a SHA-256 checksum.
- **Shared review engine** (`engine/`): relocatable bash engine with parallel
  fan-out, self / independent adjudication, an SCM seam, and a Docker sandbox
  (internal network + allowlist proxy) enforcing default-deny egress.
- **Copilot instruction files** (`copilot-instructions/`): four prefixed,
  `applyTo`-scoped files plus a subscription workflow that opens update PRs to
  subscriber repos.
- Documentation set, test suites (bats, pytest, JenkinsRule), and CI
  (static checks, engine tests, live sandbox e2e, plugin build/release,
  review-image build + scan).

[Unreleased]: https://github.com/navapbc/ai-reusable-workflows/commits/main
