# Sandbox (experimental — not wired into the shipped front ends)

> **Status: experimental / roadmap. Not used by the released GitHub Action or
> Jenkins plugin.** These files are kept in-repo so the work isn't lost and so
> a future release can re-enable a built-in egress sandbox, but nothing ships
> that runs them by default.

The intent here is to run the review inside a Docker container on a routeless
`--internal` network, with a sidecar proxy (`allowlist_proxy.py`) permitting
egress only to the LLM endpoint, the checkout mounted read-only, and no SCM
token present during the AI phase.

It was dropped from the initial release for two reasons uncovered during
review:

1. **Unverified with real CLIs.** The proxy path assumes each AI CLI honors
   `HTTPS_PROXY`. If a CLI ignores it, the review fails closed (secure but
   non-functional). This was never tested with a real CLI — only a stub.
2. **Container-in-container topologies.** On sibling-container runners
   (Docker socket mounted from the host — e.g. GitHub Actions `container:`
   jobs), the read-only workspace bind mount silently maps the wrong path and
   the review sees an empty checkout. On Kubernetes/containerd agents there is
   no Docker daemon at all.

Until those are resolved (real-CLI-through-proxy smoke tests; a
topology-aware workspace hand-off; fail-loud when the checkout isn't visible),
egress control is the **consumer's infrastructure responsibility** — see
`docs/security.md`.

## Files

- `sandbox.sh` — orchestrates the internal network, proxy sidecar, review
  container, and trusted post container.
- `allowlist_proxy.py` — stdlib-only CONNECT-filtering proxy (the egress
  allowlist).
- `../../../Dockerfile` — the review image these use.
- `../../../tests/bats/sandbox.bats` — live egress tests (run manually with
  Docker; not part of the default suite or CI).

The engine's `--json-out` / `--post-only` flags remain in `harness/ai-pr-review`
as the seam a future sandbox needs; they are harmless when unused.
