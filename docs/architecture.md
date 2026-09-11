# Architecture

Three shippable layers: portable **skills** (per workflow), a mostly-shared
**harness** that runs them (`engines/_common` + a thin per-workflow
entrypoint), and thin **adapters** per CI (GitHub Action, Jenkins plugin,
Copilot instructions). Adding a workflow adds skills + a thin entrypoint +
adapters; the generic harness is written once and never copied (see
[adding-workflows.md](adding-workflows.md)).

```
   ADAPTERS (per workflow × CI)          ENGINES (skills + harness)
   workflows/<name>/action.yml ────────▶ engines/<name>/            (per workflow)
      (sources workflows/_shared/lib)      harness/<entrypoint>  ── thin runner
   Jenkins plugin <name> (.hpi) ───────▶   skills/base/*.md      ── the rubric
     depends on ai-common-core (.hpi),     skills/profiles/<p>/  ── framework overrides
     bundles the engine zip                      │ sources
   copilot-instructions/ (skills          engines/_common/           (shared, once)
     re-expressed; can't run the           harness/core.sh  ──▶ AI CLI (claude/codex/copilot)
     harness)                              endpoints.sh          via api/bedrock/vertex/azure/gateway
                                           scm/github.sh    ──▶ SCM (gh api) — post phase only
                                           sandbox/  (experimental, not shipped)
```

Workflows today: **security-compliance-review** (`harness/ai-pr-review`) and
**test-classifier** (`harness/ai-test-classifier`).

The **compliance profile** (`AI_REVIEW_PROFILE`, default `baseline`) selects
additions under the engine's `skills/profiles/` to the always-applied
compliance floor in `skills/base/iac-compliance.md`; other rubric files
resolve from the profile first, then fall back to `skills/base/`. See
[profiles.md](profiles.md).

## The engine is the single source of truth

All of a workflow's logic lives in `engines/<name>/` plus the shared runtime
in [`engines/_common/`](../engines/_common/CONTRACT.md). The composite action
references it in place; the Jenkins plugin zips the workflow engine together
with `_common` into the `.hpi` at build time and unpacks it onto the agent.
No front end reaches into engine internals — they call the entrypoint with
flags and environment, per the engine README. Changing workflow behavior
means changing its engine, once; changing runtime behavior (dispatch,
markers, fan-out, endpoints) means changing `_common`, once, for every
workflow.

The engines are **relocatable**: every script resolves its paths from
`ENGINE_HOME` (its own location), never from the working directory, so the
`engines/` tree runs identically whether checked out or extracted from a
plugin — as long as `_common` stays a sibling of the workflow engines.

## Phases and the trust boundary

A review is three phases, split as a process boundary so the untrusted middle
phase can be isolated:

1. **Collect** (trusted): PR context from CI env; diff from local git —
   `base...HEAD` via the resolved merge base, so only what this branch
   changed is reviewed. This step fetches the base ref and may hold the
   SCM token; no AI runs in it.
2. **Review** (untrusted input): the AI reads the diff and emits findings JSON.
   **The SCM token is not in this phase's environment.**
3. **Post** (trusted, deterministic): `engines/_common/scm/github.sh` turns findings JSON
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

The experimental egress sandbox lives in `engines/_common/sandbox/` (see its
README) and is not shipped.

## The SCM seam

Everything SCM-specific is behind `engines/_common/scm/<name>.sh`, selected by
`AI_REVIEW_SCM` (default `github`). A new backend (Bitbucket, GitLab)
implements the same three functions — `scm::pr_base_ref`, `scm::discover_pr`,
`scm::post_review` — and nothing else in the engine changes.

## Fan-out and adjudication

For large diffs the engine splits the changed files into batches
(`engines/_common/harness/core.sh` planning/packing), reviews them concurrently, and merges the
per-batch findings JSON (`engines/_common/harness/fold_review_json.py`, deduplicating by
path/line/perspective and taking the worst-case action). Adjudication is an
optional extra pass — self-critique folded into the prompt, or an independent
fresh-agent review of the merged findings — that can only confirm, downgrade,
or drop findings, never add them.
