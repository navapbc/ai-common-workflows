# Security policy

This repository is a security reviewer, which makes two things worth saying up
front: a vulnerability in it is a vulnerability in someone's review pipeline,
and it deliberately contains credential-shaped strings that are not secrets.

## Reporting a vulnerability

**Use GitHub's private vulnerability reporting:** open the
[Security tab](https://github.com/navapbc/ai-common-workflows/security) and
choose **Report a vulnerability**. That opens a private advisory visible only
to maintainers.

Please don't open a public issue for something exploitable, and don't send it
to a maintainer's personal address — a private advisory keeps the report with
the repository rather than with whoever happened to read it.

Include what you'd want if you were fixing it: the affected surface (engine,
GitHub Action, Jenkins plugin, Copilot instructions), the version or commit
SHA, and the smallest reproduction you have.

You'll get an acknowledgement that a human has read it. This is maintained by
a small team, so treat any timeline beyond that as unpromised — if a fix
matters to you on a schedule, say so in the report.

## What versions get fixes

| | |
|---|---|
| The latest `vX.Y.Z` release | Fixed |
| Anything older | Not fixed — upgrade |

While on `0.x` there are no backports and no patch branches: a fix lands on
`main` and goes out in the next release. See
[docs/releasing.md](docs/releasing.md) for how versions are numbered.

Because the consumer-facing artifact is *source that GitHub fetches at `uses:`
time*, upgrading means moving your pinned SHA. Nothing updates on its own, by
design — [docs/security.md](docs/security.md) explains why, and
[`.github/dependabot.yml`](.github/dependabot.yml) is how we apply the same
rule to ourselves.

## In scope, and interesting

- **Anything that puts an SCM token in the AI phase.** The review runs with no
  `GITHUB_TOKEN`/`GH_TOKEN` in scope and posting happens in a separate step
  that holds the token. A path that defeats that separation is the most
  serious class of bug this repo can have. (The one documented exception is
  `copilot`, whose *model* auth is a GitHub token.)
- **Prompt injection through a diff.** The reviewer reads attacker-controlled
  content by definition — that is its job. Content in a pull request that
  steers the review toward `APPROVE`, suppresses a finding, or makes the engine
  emit findings JSON of the attacker's choosing is a real finding, and we want
  it.
- **Escaping the findings contract** — anything that turns model output into
  command execution, file writes outside the run, or a gate verdict that
  doesn't follow from the findings.
- **Secrets reaching argv, logs, or the posted review.** Credentials move by
  environment variable here; a path that leaks one into a place a reader or a
  log aggregator can see counts.
- **The Jenkins plugin's uploaded `.hpi`**, which is the only downloadable
  artifact this repo produces and the only one that lands on a machine an admin
  operates.

## Not a vulnerability here

These are documented behaviours. Reporting them is welcome as an *issue* if
you think the documentation is wrong, but they aren't advisories:

- **The fake credentials in `tests/`.** This repo has to contain
  credential-shaped strings so the reviewer has something to find and so we can
  assert it says so. `tests/corpus/09-aws-doc-example-key` holds AWS's
  *published* documentation pair on purpose, to check we don't cry wolf over
  it. See the section in [docs/security.md](docs/security.md) and the narrowly
  scoped [`.github/secret_scanning.yml`](.github/secret_scanning.yml);
  `tests/python/test_secret_fixtures.py` is the control that keeps the
  exclusions from becoming a blind spot.
- **A finding the model missed.** The review is advisory. It is not a control,
  it does not replace SAST, and a false negative is a quality problem rather
  than a vulnerability. If you have a case it should have caught, a corpus case
  is the most useful form to send it in — see
  [tests/corpus/README.md](tests/corpus/README.md).
- **No egress sandbox.** There is deliberately no network boundary around the
  AI phase. Restricting egress — and sandboxing the run at all — is the
  consumer's responsibility, and the docs don't claim otherwise. There is no
  partial implementation in the tree either; see
  [docs/adr/0002](docs/adr/0002-remove-the-experimental-egress-sandbox.md).
- **Diffs leaving your perimeter on the public API.** Expected, and the reason
  Bedrock/Vertex/Azure OpenAI and internal-gateway support exists. Choosing a
  provider is a deployment decision.
- **A consumer pinning by tag instead of SHA.** A tag can be deleted and
  re-created against different content. That's why every doc and example here
  pins a 40-character SHA and `tests/python/test_pin_hygiene.py` enforces it —
  a consumer who overrides that has accepted the risk.

## Hardening guidance

[docs/security.md](docs/security.md) is the threat model: what the review can
see, which credentials exist and where they live, least-privilege permissions
for each front end, and the limits worth knowing before you rely on it.
