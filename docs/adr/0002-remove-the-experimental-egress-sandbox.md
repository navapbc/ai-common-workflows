# ADR 0002: Remove the experimental egress sandbox

- **Status:** Accepted — 2026-10-01.
- **Supersedes:** the "kept in-repo so the work isn't lost" position in the
  former `engines/_common/sandbox/README.md`.

## Context

An earlier design ran the AI phase inside a Docker container on a routeless
`--internal` network, with a sidecar CONNECT proxy permitting egress only to
the LLM endpoint, the checkout mounted read-only, and the SCM token absent.
About 580 lines: `sandbox.sh`, `allowlist_proxy.py`, a `Dockerfile`, a bats
suite and a pytest module.

It never shipped. Two defects found in review, both of the kind only found by
trying:

1. **Unverified against real CLIs.** The proxy assumes every AI CLI honours
   `HTTPS_PROXY`. It was exercised only against a stub. A CLI that ignores the
   variable fails closed — secure and non-functional.
2. **Container-in-container breaks the workspace silently.** On sibling-
   container runners (Docker socket mounted from the host, such as GitHub
   Actions `container:` jobs) the read-only workspace bind mount maps the wrong
   path and the review sees an empty checkout. It does not fail; it reports
   nothing wrong. On Kubernetes/containerd agents there is no Docker daemon at
   all.

The code was kept in the tree so the work would not be lost. That decision is
what this record reverses.

## Decision

**Delete it in full** — code, image, tests, and every documentation reference.
Sandboxing will be revisited later and will start from scratch.

Egress control and sandboxing are the **consumer's infrastructure
responsibility**, stated plainly wherever the subject comes up, with no
qualifier implying a built-in boundary is partially present or imminent.

The `--json-out` / `--post-only` pair **stays**. It was described as "the seam
the sandboxed flow uses", which undersold it: both shipped front ends use it to
keep the SCM token out of the phase that reads untrusted PR content. It is a
process boundary, not a network one, and the docs now say which.

## Rejected alternatives

**Keep it, clearly marked experimental.** This is what we had, and the week's
evidence is against it. Unbuilt, unread code does not stay honest: the
`Dockerfile` pointed at a release workflow that had never existed in this
layout, and floated all three agentic CLI installs on `latest` for weeks after
the same pins were fixed everywhere else — found only by someone auditing a
different question. A directory nothing executes is where stale claims go to
survive.

**Keep it behind a feature flag.** Worse. A flag implies the path is supported
enough to turn on, and the two defects above mean the honest flag description
is "may silently review an empty checkout".

**Keep the proxy, drop the container orchestration.** The proxy is the part
that works and is self-contained. Rejected because its value is entirely in
being the only route out of a routeless network — on a normal runner it is an
`HTTPS_PROXY` a process can simply not use.

## Consequences

- There is no partial implementation to point at, so the documentation claim
  and the code now agree. `CLAUDE.md` has said "don't claim a network boundary
  the tool doesn't enforce" for some time; the directory sitting there was the
  main thing undermining it.
- Dependabot's `docker` ecosystem entry goes with the `Dockerfile`, as does the
  half of `tests/python/test_cli_pin_hygiene.py` that checked the image's
  `ARG …=latest` defaults. If a `Dockerfile` returns it needs that equality
  check against `ci.sh` again — "pinned in two places that disagree" was the
  failure worth catching, not "pinned".
- `tests/bats/sandbox.bats` was the repo's only Docker-dependent suite and the
  only one excluded from CI. Nothing is now excluded.
- `tests/python/test_no_built_in_sandbox.py` holds the claim: the tree is
  absent and no shipped document promises a boundary. It is deliberately easy
  to delete — a future attempt should remove it in the same change that adds
  working code and honest docs, which is the point.

## What a future attempt has to prove first

Not a design constraint on the next attempt, but the evidence that was missing
from this one:

1. A real-CLI-through-proxy smoke test for each supported CLI, not a stub.
2. A topology-aware workspace hand-off that **fails loudly** when the checkout
   is not visible, rather than reviewing nothing.
3. A story for agents with no Docker daemon.
