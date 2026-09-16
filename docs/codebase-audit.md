# Codebase audit — run it on your laptop

Audit a whole repo (or one directory) for security and compliance issues.
Local, ad-hoc, read-only. Nothing is installed in the repo you audit.

## Run it

Three lines, once:

```bash
git clone https://github.com/navapbc/ai-common-workflows ~/ai-common-workflows
export AI_REVIEW_TOOL=claude          # or codex, or copilot
export ANTHROPIC_API_KEY=sk-...       # OPENAI_API_KEY for codex
```

Then, from the repo you want to audit:

```bash
cd ~/code/my-repo
bash ~/ai-common-workflows/engines/security-compliance-review/harness/ai-security-compliance-audit
```

That's it. The report prints to your terminal.

**Make it a one-word command** (optional, worth the 10 seconds):

```bash
echo "alias audit='bash ~/ai-common-workflows/engines/security-compliance-review/harness/ai-security-compliance-audit'" >> ~/.zshrc
source ~/.zshrc
```

Now it's `audit` from any repo.

## The four things you'll actually use

```bash
audit                          # whole repo
audit terraform/               # just one directory — much cheaper
audit --dry-run                # what would it cost? no AI call
audit --profile cms-ars        # judge against CMS ARS 5.1 / NIST 800-53
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

## Save the output

```bash
audit --md-out audit.md                  # the readable report
audit --json-out findings.json           # machine-readable findings
audit --json-only > findings.json        # JSON only, nothing else on stdout
```

Write these **outside** the audited repo if you don't want them committed by
accident — the audit itself never creates a file in your repo.

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

## If something goes wrong

| Message | Fix |
|---|---|
| `AI_REVIEW_TOOL must be set` | `export AI_REVIEW_TOOL=claude` |
| `Not a git repository` | Run it from the repo root |
| `No files in scope` | Check the path, `--include`/`--exclude`, `--max-file-bytes` |
| `must start with 'base' or 'none'` | Prefix the list: `--profile base,cms-ars` |
| `--profile 'x' is not a known profile` | Use `cms-ars`, or a directory path |
| `--gate is not supported by the audit` | By design — use the PR review action for gating |

Full flag list: `audit --help`, or the
[engine README](../engines/security-compliance-review/README.md).
