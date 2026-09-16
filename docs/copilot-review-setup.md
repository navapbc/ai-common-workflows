# Copilot review setup — five steps

Make GitHub Copilot's PR review apply this repo's security & compliance rubric.
Runs natively inside GitHub: no CI minutes, no LLM keys of your own.

This page is the **how**. For what the instruction files contain and why they
are split base + profile, see
[`copilot-instructions/README.md`](../copilot-instructions/README.md).

Everything below happens in **your** repo. `ai-common-workflows` needs no
knowledge of you — no subscriber list, no credentials, no access to your code.

---

## 1. Copy the sync workflow

```bash
mkdir -p .github/workflows
curl -fsSL https://raw.githubusercontent.com/navapbc/ai-common-workflows/<ref>/examples/workflows/copilot-instructions-sync.yml \
  -o .github/workflows/copilot-instructions-sync.yml
```

Or copy [`examples/workflows/copilot-instructions-sync.yml`](../examples/workflows/copilot-instructions-sync.yml)
by hand.

## 2. Set two values

In the `env:` block at the top:

| Value | Set it to |
|---|---|
| `PROFILE` | `baseline` (framework-neutral OWASP / CIS / NIST CSF) or `cms-ars` (adds NIST/ARS control-ID citations, PHI severity items, FIPS posture, CMS checks) |
| `ACW_REF` | A commit SHA of `ai-common-workflows` ([why a SHA](security.md)) |

A `PROFILE` that doesn't exist fails the run loudly, before anything is copied
— it can't silently downgrade you.

## 3. Optional — `COPILOT_SYNC_TOKEN` for hands-off PRs

Without it, the workflow pushes its branch, fails to open the PR (GitHub blocks
PR creation by the built-in `GITHUB_TOKEN` by default), and prints a compare
URL for you to click. The run still succeeds. That is a perfectly reasonable
human-in-the-loop posture.

For full automation, add a fine-grained PAT / App token scoped to **your** repo
with `Contents: Read and write` + `Pull requests: Read and write`, as
**`COPILOT_SYNC_TOKEN`**. The workflow prefers it automatically. The
"Allow GitHub Actions to create and approve pull requests" toggle stays **off**,
no workflow gains approve rights, and `pull_request` CI runs normally on the
sync PR — GitHub suppresses CI on PRs opened by the built-in token, but not on
PAT-opened ones.

## 4. Run it, merge the sync PR

Actions → **Sync AI-review Copilot instructions** → Run workflow.

You get a PR adding `.github/instructions/ai-review/` — four base files, plus
three more if `PROFILE: cms-ars`. Merge it.

From then on it runs weekly and is idempotent: no upstream change, no PR. To
upgrade, bump `ACW_REF`. To change profile, edit `PROFILE` — the next sync adds
or removes that profile's `*-additions` files and never touches the base.

## 5. Turn on Copilot review

The instructions do nothing until Copilot actually reviews your PRs. Two
requirements, both outside this repo:

**Copilot code review must be enabled** for your repository or organization,
and you need a Copilot plan that includes it.

**To review every PR automatically:** Settings → Rules → Rulesets → New branch
ruleset, then under Branch rules enable **"Automatically request Copilot code
review"**. Two optional toggles: *Review new pushes* (re-review each push, not
just the first) and *Review draft pull requests*.

Two limits worth knowing before you plan around this:

- Automatic code review requires a Copilot **Pro, Pro+, or Max** plan.
- **Rulesets are unavailable on a private repo on a free GitHub plan.** If
  Settings → Rules is missing or the API returns *"Upgrade to GitHub Pro or
  make this repository public"*, use one of: your profile → Copilot settings →
  **"Automatic Copilot code review" → Enabled** (covers PRs you open; needs
  Pro+ or Max), requesting Copilot as a reviewer per PR, or making the repo
  public / upgrading.

---

## Verify it actually works

A silent miss looks exactly like Copilot having no findings, so confirm once,
deliberately.

Copilot reads instructions from the PR's **head** branch — so the sync PR
itself, or any PR after it, is a valid test. Open a PR touching a `.tf` file
and check the review comes back in the rubric's severity format rather than as
generic Copilot suggestions.

You do not wire up which instructions apply to what — the `applyTo` frontmatter
does it:

| File | Applies to |
|---|---|
| `ai-review-security` | `**` — everything; the severity ladder and comment format |
| `ai-review-iac` | Terraform, CloudFormation, Bicep, Pulumi, Helm, K8s, CDK |
| `ai-review-auth` | auth / authn / authz / session / middleware / oauth / jwt / rbac paths |
| `ai-review-scripts` | `**/*.sh`, `**/*.bash` |

## Troubleshooting

| Symptom | Cause |
|---|---|
| `GitHub Actions is not permitted to create or approve pull requests` | Expected without `COPILOT_SYNC_TOKEN` — the branch **is** pushed; open the PR from the printed compare URL (step 3) |
| `profile '<x>' not found` | `PROFILE` names a directory that doesn't exist under `copilot-instructions/profiles/` |
| Run is green but no PR and no instructions on your default branch | Your copy predates the open-PR fix; a closed or merged sync PR on the branch kept matching. Take the current example (step 1) |
| Instructions synced, but reviews look generic | Copilot review isn't enabled, or isn't being requested on the PR (step 5) |

A workflow fix upstream **never reaches you automatically.** The sync only ever
writes `.github/instructions/` — it does not update your copy of
`copilot-instructions-sync.yml`. Re-copy the example (step 1) to pick up
workflow changes.
