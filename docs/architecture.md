# Architecture

One engine, two front ends, plus a set of Copilot instruction files.

```
                         ┌───────────────────────────┐
   GitHub Action ───────▶│                           │
   (action.yml)          │      engine/  (bash)      │──▶ AI CLI (claude/codex/copilot)
                         │  bin/ai-pr-review         │      via api / bedrock / vertex / gateway
   Jenkins plugin ──────▶│  lib/core.sh              │
   (bundles engine zip)  │  lib/endpoints.sh         │──▶ SCM (gh api) — post phase only
                         │  lib/scm/github.sh        │
                         │  skills/*.md              │
                          └───────────────────────────┘
   (lib/sandbox/ is experimental and not wired into either front end)
```

## The engine is the single source of truth

All review logic lives in [`engine/`](../engine/README.md). The composite
action references it in place; the Jenkins plugin zips it into the `.hpi` at
build time and unpacks it onto the agent. Neither front end reaches into engine
internals — they call `bin/ai-pr-review` with flags and environment, per the
contract in the engine README. Changing review behavior means changing the
engine, once.

The engine is **relocatable**: it resolves its own paths from `ENGINE_HOME`
(its own location), never from the working directory, so it runs identically
whether checked out or extracted from a plugin.

## Phases and the trust boundary

A review is three phases, split as a process boundary so the untrusted middle
phase can be isolated:

1. **Collect** (trusted): PR context from CI env; diff from local git.
2. **Review** (untrusted input): the AI reads the diff and emits findings JSON.
3. **Post** (trusted, deterministic): `lib/scm/github.sh` turns findings JSON
   into a GitHub review via `gh api`. No AI.

The `--json-out` / `--post-only` flags express this split at the engine level,
so the AI phase and the posting phase *can* run as separate processes. Today
both front ends run the whole engine in one native invocation — so the SCM
token is present during the AI phase — but the seam is deliberately preserved:
a future egress sandbox, or a token-stripped AI phase, will use it to isolate
phase 2 from phase 3. The experimental sandbox lives in `engine/lib/sandbox/`
(see its README) and is not shipped.

## The SCM seam

Everything SCM-specific is behind `lib/scm/<name>.sh`, selected by
`AI_REVIEW_SCM` (default `github`). A new backend (Bitbucket, GitLab)
implements the same three functions — `scm::pr_base_ref`, `scm::discover_pr`,
`scm::post_review` — and nothing else in the engine changes.

## Fan-out and adjudication

For large diffs the engine splits the changed files into batches
(`lib/core.sh` planning/packing), reviews them concurrently, and merges the
per-batch findings JSON (`lib/fold_review_json.py`, deduplicating by
path/line/perspective and taking the worst-case action). Adjudication is an
optional extra pass — self-critique folded into the prompt, or an independent
fresh-agent review of the merged findings — that can only confirm, downgrade,
or drop findings, never add them.
