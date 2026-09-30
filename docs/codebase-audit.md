# Codebase audit — run it on your laptop

Audit a whole repo (or one directory) for security and compliance issues.
Local, ad-hoc, read-only. Nothing is installed in the repo you audit.

Because an audit sends the whole scope to a model, **decide the endpoint before
you decide anything else** — Bedrock, Azure OpenAI, Vertex or your own gateway
keep it inside your boundary.

## Before you run it: where does the code go?

**An audit sends the whole scope to the model endpoint, not a diff.** That is
the difference that matters. A PR review exposes the lines someone changed; an
audit of `src/` exposes `src/`. Decide the data path first — it is a harder
question to unwind afterwards.

`--dry-run` tells you what it would use, before anything leaves the machine:

```
  Provider:       api (PUBLIC endpoint — see docs/private-endpoints.md for in-boundary options)
```

### In your boundary (recommended)

Same engine, same rubric — only the endpoint changes. Set it once in your
shell and the audit stays inside your account:

**AWS Bedrock** — Claude in your own AWS account and region:

```bash
export AI_REVIEW_TOOL=claude
export AI_REVIEW_PROVIDER=bedrock
export AWS_REGION=us-east-1                     # the region you are allowed to use
export AI_REVIEW_MODEL=us.anthropic.claude-sonnet-4-5
# credentials from your ambient AWS source: SSO, a profile, IRSA, instance role
```

**Azure OpenAI** — a deployment in your own resource:

```bash
export AI_REVIEW_TOOL=codex
export AI_REVIEW_PROVIDER=azure
export AZURE_OPENAI_ENDPOINT=https://my-resource.openai.azure.com
export AZURE_OPENAI_API_KEY=...                 # or let a gateway handle auth
export AI_REVIEW_MODEL=my-deployment            # the Azure *deployment* name
```

**Google Vertex AI**:

```bash
export AI_REVIEW_TOOL=claude
export AI_REVIEW_PROVIDER=vertex
export ANTHROPIC_VERTEX_PROJECT_ID=my-project
export CLOUD_ML_REGION=us-east5
# credentials from ambient GCP ADC
```

**A gateway you run** (LiteLLM and similar) — set `ANTHROPIC_BASE_URL` or
`OPENAI_BASE_URL` and keep `AI_REVIEW_PROVIDER=api`.

Full matrix, credential handling and least-privilege guidance:
[private-endpoints.md](private-endpoints.md).

Two things worth knowing whichever you pick. A misconfiguration is now a hard
error rather than a silent fallback — `provider=bedrock` without a region fails
before the model is called, instead of quietly using the public API. And
**in-boundary only holds if the machine is too**: running this on a laptop
means the code was already on the laptop, but the *egress* is what you are
controlling here, and this tool enforces no network boundary of its own.

### Public API

If your program permits it, this is the shortest path:

```bash
export AI_REVIEW_TOOL=claude          # or codex, or copilot
export ANTHROPIC_API_KEY=sk-...       # OPENAI_API_KEY for codex
```

If your CLI is already logged in interactively and you have no key to export,
set `AI_REVIEW_CLI_NATIVE_AUTH=1` instead — the audit then runs on that login,
against the **public** endpoint, and says so on every run. See
[when the CLI already holds the login](private-endpoints.md#when-the-cli-already-holds-the-login).
An audit sends the whole scope rather than a diff, so be deliberate about this
one.

### Copilot CLI

Copilot does not take an API key, so none of the above applies to it. Its model
auth **is a GitHub token**, and it reads one from the environment or from its
own login:

```bash
export AI_REVIEW_TOOL=copilot
# either a token in the environment...
export GITHUB_TOKEN=ghp_...        # GH_TOKEN and COPILOT_GITHUB_TOKEN also work
# ...or nothing here at all, if `copilot` is already signed in on this host
```

Three things that differ from `claude` and `codex`:

- **`AI_REVIEW_CLI_NATIVE_AUTH=1` does nothing for copilot.** That flag exists
  because the other two CLIs hard-fail without a key in the environment.
  Copilot already assumes host authentication, so there is nothing to opt into.
- **A missing token is a warning, not an error.** The run proceeds and fails
  later inside the CLI if it turns out not to be signed in. `audit --doctor`
  prints the warning under the `endpoint` row — read it, because the row itself
  still says `ok`.
- **It runs on GitHub's models**, so "public endpoint" means GitHub here rather
  than Anthropic or OpenAI. Judge that against your program's boundary
  separately from the API-key path above.

Install it with `npm install -g @github/copilot`.

**Bring your own endpoint.** Copilot can talk to a model endpoint you run
instead of GitHub's. [private-endpoints.md](private-endpoints.md#copilot-byok-bring-your-own-key)
documents this as Action inputs; locally the same settings are environment
variables:

```bash
export COPILOT_PROVIDER_BASE_URL=https://llm-gw.internal/v1
export COPILOT_PROVIDER_TYPE=anthropic      # openai | azure | anthropic
export COPILOT_PROVIDER_API_KEY=...
export COPILOT_MODEL=claude-sonnet-4-5
```

A GitHub token may still be needed for CLI entitlement even with BYOK.

## Check your setup first

```bash
audit --doctor
```

```
[security-compliance-audit] Checking what this needs...
  bash                       ok        3.2.57(1)-release
  git                        ok        2.39.5
  python3                    MISSING   brew install python, or xcode-select --install
  claude CLI                 ok        /opt/homebrew/bin/claude
  endpoint                   ok        bedrock — in your boundary
  profile                    ok        base
  repo                       ok        /Users/you/code/my-repo
  output dir                 ok        /Users/you/audits

[security-compliance-audit] ERROR: Not ready — fix the MISSING/FAILED rows above.
```

It reports **everything** that is wrong in one pass rather than stopping at the
first, because a fresh laptop usually has two or three problems at once. It
calls no model, needs no git repo (so you can check before `cd`-ing into one),
and exits `1` when something is missing and `0` when you are ready.

A public endpoint and a not-yet-chosen output directory are shown but do **not**
fail it — those are choices, not defects.

On macOS the row that usually bites is `python3`: the system `python3` is a stub
that prompts for the Xcode command line tools. `brew install python` or
`xcode-select --install` fixes it.

## Run it

Once, to get the engine:

```bash
git clone https://github.com/navapbc/ai-common-workflows ~/ai-common-workflows
```

Then, with the endpoint configured above, from the repo you want to audit:

```bash
mkdir -p ~/audits
cd ~/code/my-repo
bash ~/ai-common-workflows/engines/security-compliance-review/harness/ai-security-compliance-audit \
  --output-parent-dir ~/audits
```

That's it. It prints the report to your terminal and writes a bundle to
`~/audits/<repo>-<date>-01/` — start at its `_INDEX.md`.

**Make it a one-word command** (optional, worth the 10 seconds):

```bash
echo "alias audit='bash ~/ai-common-workflows/engines/security-compliance-review/harness/ai-security-compliance-audit'" >> ~/.zshrc
source ~/.zshrc
```

Now it's `audit` from any repo. Put the provider exports in your shell profile
next to it, so an in-boundary endpoint is the default rather than something you
remember.

## The four things you'll actually use

```bash
audit --output-parent-dir ~/audits              # whole repo
audit --output-parent-dir ~/audits terraform/   # one directory — much cheaper
audit --dry-run                                 # what would it cost? no AI call
audit --output-parent-dir ~/audits --profile base,cms-ars   # CMS ARS / NIST 800-53
```

Worth folding the output directory into the alias so you never type it:

```bash
alias audit='bash ~/ai-common-workflows/engines/security-compliance-review/harness/ai-security-compliance-audit --output-parent-dir ~/audits'
```

**Check cost before a big run.** `--dry-run` tells you how many model calls to
expect, and `--list-files` shows exactly what's in scope:

```
$ audit --dry-run
  Scope:          repository root
  Files:          98
  Batches:        4 (concurrency 4)
  Profile:        base
  Adjudication:   self
  Expected calls: ~4 first-pass
```

A directory is usually the right scope. `audit terraform/` on a large repo is a
couple of calls; `audit` on the same repo can be dozens.

## Judging against a compliance framework

`--profile` is an **ordered list of rubric sources**, and the shared floor is an
explicit member of it. The first entry must be `base` or `none`:

```bash
audit --output-parent-dir ~/audits --profile base              # the default — floor only
audit --output-parent-dir ~/audits --profile base,cms-ars      # floor + CMS ARS 5.1 / NIST 800-53
audit --output-parent-dir ~/audits --profile base,cms-ars,./my-overlay
```

Sources layer in order and each only ever *adds* to what precedes it, so the
last entry wins a genuine conflict. `base` is the default, so you can leave
`--profile` off entirely.

A bare `--profile cms-ars` is a **configuration error**, not a shortcut —
omitting the floor is a quiet way to audit against citations for checks you no
longer have, so it has to be deliberate:

```
ERROR: AI_REVIEW_PROFILE must start with 'base' or 'none' (got 'cms-ars').
```

`none,<your-profile>` is the escape hatch if your program supplies the entire
rubric itself. It must then include a `codebase-audit.md`, since that file
carries the report's output contract.

A profile may also ship a `codebase-audit.md` of its own — layered on top of
the base audit instructions, never replacing them — if your framework needs
audit-specific guidance beyond the compliance checks.

Full detail, including how to write a profile: [profiles.md](profiles.md).

## It asks before it spends

A full-repo audit is the most expensive thing here by a wide margin — roughly
one model call per batch, each carrying the rubric plus the files in its batch.
So it shows you the plan and waits:

```
[security-compliance-audit] This audit will send code to a model and consume tokens.
  Scope:          repository root
  Files:          412
  Batches:        4 (concurrency 4)
  Expected calls: ~4 first-pass
  Endpoint:       api (PUBLIC — the whole scope leaves your machine)
  Report:         /home/you/audits

  --dry-run shows this plan without spending anything.
  Proceed? [y/N]
```

Anything but `y` aborts and sends nothing. Skip it with `--yes` (or
`-y`, or `AI_AUDIT_ASSUME_YES=1`) once you know what a run costs you.

**Non-interactive runs must pass `--yes`.** When stdin is not a TTY the audit
refuses rather than prompting into the void — a scripted run should not be able
to spend by accident — and the refusal names the file and batch count it would
have used. `--dry-run`, `--list-files` and `--list-batches` never prompt.

## Going faster on a big repo

Batches run concurrently; `--jobs` sets how many at once (default 4, same knob
as `AI_REVIEW_JOBS`):

```bash
audit --output-parent-dir ~/audits --jobs 8      # 8 batches in flight
audit --output-parent-dir ~/audits --jobs 1      # fully serial
```

Batch *planning* is single-threaded and deterministic, so the set of reports and
the `_INDEX.md` are identical regardless of `--jobs` — only execution fans out.
The practical ceiling is your provider's rate limit; too high invites HTTP 429s.
`--dry-run` shows the batch count and concurrency before you commit.

## Where the report goes

`--output-parent-dir` is **required** for a real run. Point it at a directory
that already exists — the audit will not create it, because a typo that
silently creates a deep path is how a report ends up somewhere nobody looks
again.

```bash
mkdir -p ~/audits
audit --output-parent-dir ~/audits
```

Each run gets its own subdirectory, so runs never overwrite each other:

```
~/audits/
└── my-repo-20260917-01/          ← <repo>-<YYYYMMDD>-<NN>
    ├── _INDEX.md                 ← start here
    ├── report.md                 the auditor's narrative, including the posture summary
    ├── findings.json             machine-readable, same schema as the PR review
    ├── src__api.md               one doc per directory ('/' becomes '__')
    └── infra.md
```

The run number is allocated by scanning the parent for existing
`<repo>-<date>-*` directories and taking the highest plus one, starting at
`01`. It is per repo *and* per day, since the date already distinguishes days —
so a second audit today is `-02`, and tomorrow's first is `-01` again.

### Reading it

Open `_INDEX.md`. It is **findings-first**, so you never hunt through clean
directories:

- A **directories-with-findings** table at the top, worst first (critical, then
  high, medium, low), each linking straight to that directory's findings.
- A suggested triage order — criticals today, highs in security-sensitive
  directories next, and a note that a recurring Medium across many files is
  usually one systemic gap rather than N tickets.
- Clean directories collapsed into a `<details>` list at the bottom, present
  for completeness and out of the way.
- A ✅ note instead of the table when nothing was found.

Every finding is a `####` heading, so you can list just the docs worth opening:

```bash
cd ~/audits/my-repo-20260917-01 && grep -rl '^#### ' .
```

The bundle is generated from the merged findings, so it is identical whether
the audit ran as one call or fanned out across eight — a report whose shape
depends on `--jobs` is one you cannot compare against last week's.

### Picking a long audit back up

A large repo takes a while, and an interrupted run leaves a partial bundle.
`--resume` continues the newest bundle for this repo instead of starting a new
one:

```bash
audit --output-parent-dir ~/audits --resume
```

Directories that already have a report are skipped, and their findings are
carried into the regenerated `_INDEX.md` — so resuming never discards the
segment it was meant to preserve. The narrative is appended under a
`## Resumed segment` divider rather than replaced.

```
[security-compliance-audit] Resuming /home/you/audits/my-repo-20260917-01
[security-compliance-audit]   380 file(s) already covered by an existing report; 32 remaining.
```

Resume works at **directory** granularity, matching the shape of the reports.
It deliberately does not work per batch: packing coalesces directories into at
most `--jobs` bins, so "already done" would mean something different at
`--jobs 4` than at `--jobs 8`.

If nothing is left, it says so and leaves the bundle alone. If there is no
existing bundle, it starts a fresh one and tells you. To re-audit a directory
you have since fixed, delete its doc and resume:

```bash
rm ~/audits/my-repo-20260917-01/src__api.md
audit --output-parent-dir ~/audits --resume
```

### Other output options

```bash
audit --output-parent-dir ~/audits --md-out ~/latest.md    # an extra copy, exact path
audit --output-parent-dir ~/audits --json-out ~/f.json     # same, for a script
audit --json-only > findings.json                          # no bundle at all
```

`--json-only` needs no output directory, and neither do `--dry-run`,
`--list-files` or `--list-batches` — inspecting scope and cost should not
require deciding where a report goes.

## What you get

Findings grouped by file, each with a severity (`CRITICAL` / `HIGH` /
`MEDIUM` / `LOW`), a file and line, and a suggested fix — the same severities
and format as the PR review, so the two are comparable. Plus a **posture**
paragraph: the two or three sentences of judgment you can't get from a finding
list.

## Trimming scope and cost

```bash
audit --exclude 'vendor/*' --exclude '*_test.go'   # skip noise
audit --include '*.tf'                             # only Terraform
audit --max-file-bytes 100000                      # skip big generated files
audit --no-adjudicate                              # cheaper, noisier first pass
audit --jobs 8                                     # more parallelism
```

Already skipped for you: untracked files, anything in `.gitignore`, binaries,
and files over 256 KB. Each skip is printed so you know what wasn't examined.

## Things worth knowing

- **It audits your working tree**, including uncommitted changes. That's
  deliberate — it's a local tool, so it looks at what you have.
- **It never writes to the audited repo**, never posts anywhere, never fails
  your build. It needs no GitHub token.
- **It's advisory.** There's no `--gate`; findings are a second opinion, not a
  verdict. For blocking CI, use the
  [PR review action](security-compliance-review.md) instead.
- **Not for CI.** A full-repo audit costs roughly one model call per batch
  every run, which is fine by hand and expensive on every push. It warns if it
  detects CI, and there's deliberately no GitHub Action for it.
- **The endpoint is per-invocation, not baked in.** Nothing remembers your
  provider between runs, so an audit run without the exports goes to the
  public API. Put them in your shell profile, and check the `Provider:` line
  in `--dry-run` when it matters.

## If something goes wrong

| Message | Fix |
|---|---|
| anything at all, on a new machine | Run `audit --doctor` first — it names every missing piece in one pass |
| `AI_REVIEW_TOOL must be set` | `export AI_REVIEW_TOOL=claude` |
| `provider=bedrock requires AWS_REGION` | `export AWS_REGION=…` — it fails rather than falling back to the public API |
| `provider=azure requires AZURE_OPENAI_ENDPOINT` | Set the resource endpoint; `AI_REVIEW_MODEL` is the deployment name |
| `provider=vertex requires …PROJECT_ID` | Set `ANTHROPIC_VERTEX_PROJECT_ID` and `CLOUD_ML_REGION` |
| `Not a git repository` | Run it from the repo root |
| `No files in scope` | Check the path, `--include`/`--exclude`, `--max-file-bytes` |
| `--output-parent-dir is required` | Pass an existing directory, or `--json-only` to write nothing |
| `stdin is not a TTY` | Add `--yes` for a scripted run |
| `--resume needs --output-parent-dir` | Resume has to know which bundle to continue |
| `--output-parent-dir '…' does not exist` | `mkdir -p` it first — the audit will not create it |
| `must start with 'base' or 'none'` | Prefix the list: `--profile base,cms-ars` |
| `--profile 'x' is not a known profile` | After `base`, use `cms-ars` or a directory path — see [profiles.md](profiles.md) |
| `--gate is not supported by the audit` | By design — use the PR review action for gating |

Full flag list: `audit --help`, or the
[engine README](../engines/security-compliance-review/README.md).
