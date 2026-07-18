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
   **The SCM token is not in this phase's environment.**
3. **Post** (trusted, deterministic): `lib/scm/github.sh` turns findings JSON
   into a GitHub review via `gh api`. The only phase that holds the SCM token.

Both front ends implement this split with the engine's `--json-out` /
`--post-only` flags: they run the AI phase as one invocation whose environment
has **no** `GITHUB_TOKEN`/`GH_TOKEN`, then post in a second invocation that
does. So an injected agent reading the diff has no repo-write token in its
process tree (not even via `/proc/<ancestor>/environ`). Two caveats: the
`copilot` backend's model auth *is* a GitHub token, so it alone carries one in
the AI phase; and if `actions/checkout` persisted credentials, a token is in
`.git/config` regardless — check out with `persist-credentials: false` for the
strongest isolation (see [security.md](../docs/security.md)).

The experimental egress sandbox lives in `engine/lib/sandbox/` (see its
README) and is not shipped.

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
