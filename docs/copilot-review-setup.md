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

Skip this and the workflow still works: it pushes its branch, fails to open the
PR, and prints a compare URL for you to click. The run succeeds. For a PR that
appears weekly at most, that is a perfectly reasonable place to stop.

For hands-off PR creation, add a token as **`COPILOT_SYNC_TOKEN`**. The
workflow prefers it automatically when present.

### The PAT must come from a machine user

Never issue this token from a person's account. Create a dedicated GitHub
account for automation — a *machine user* — and issue the PAT from there:

1. Create the account (e.g. `acme-ci-bot`) with its own email and 2FA.
2. Give it **write** access to the repo: add it as a collaborator, or add it to
   the org and to a team with write on that repo.
3. Signed in as that account, create a **fine-grained PAT**:
   - **Repository access:** only the repo(s) running the sync
   - **Permissions:** `Pull requests: Read and write` — and nothing else
     (`Metadata: Read-only` is added automatically and is required)
4. Store it in the consuming repo as the secret **`COPILOT_SYNC_TOKEN`**.

**`Contents` is deliberately not granted.** This token never pushes anything.
`actions/checkout` persists the built-in `GITHUB_TOKEN` into `.git/config`, so
`git push` authenticates as that token under the workflow's own
`contents: write` permission. `COPILOT_SYNC_TOKEN` is read only by `gh pr list`
and `gh pr create` — both pull-request operations. Granting it `Contents: Read
and write` would let it push to any branch in the repo, `main` included, for no
gain.

If `gh pr create` fails with a 404 after tightening — `gh` may verify the head
ref before posting — add `Contents: Read-only`, never write.

Three reasons this is a requirement and not a preference. A token issued from a
person's account attributes every sync PR to them, as though they wrote it. It
carries their access to everything else they can reach, not just the repo
running the sync — far more reach than this job needs. And the automation
breaks the day their access changes, which is exactly when nobody is looking
for it. A machine user has none of those properties: the PR author is
unmistakably a bot, the token reaches only the repos you granted, and the
account outlives any individual.

**Plan for expiry.** Fine-grained PATs expire. When one lapses the run fails at
the PR step with a `gh` auth error, so it is loud rather than silent, but you
still want a calendar reminder ahead of the date. Set the longest expiry your
org policy permits.

### The other two ways, and why not

- **Enable "Allow GitHub Actions to create and approve pull requests"** — no
  credential at all, but the single toggle grants create **and approve** to
  every workflow's `GITHUB_TOKEN` in the repo. A workflow that can approve can
  satisfy a required-review rule.
- **A GitHub App** — short-lived tokens, no expiry treadmill, survives
  offboarding. Better security properties than a PAT, at the cost of a ~10-step
  setup per org. Worth it if you are rolling this out across many repos in one
  org: create one App, install it on those repos, and hold its id and private
  key as organization-level variables and secrets so each repo needs no
  credential setup of its own.

One practical difference beyond permissions: GitHub suppresses `pull_request`
CI on PRs opened by the built-in `GITHUB_TOKEN`, but not on PRs opened by a PAT
or App token. So the toggle gets you an automatic PR with no checks on it,
while a machine-user PAT gets you one that runs CI normally.

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
| `gh pr create` 404s right after tightening the PAT scope | `gh` may verify the head ref; add `Contents: Read-only` — never write (step 3) |
| PR creation worked, then started failing with a `gh` auth error | `COPILOT_SYNC_TOKEN` expired — fine-grained PATs do (step 3) |
| Run is green but no PR and no instructions on your default branch | Your copy predates the open-PR fix; a closed or merged sync PR on the branch kept matching. Take the current example (step 1) |
| Instructions synced, but reviews look generic | Copilot review isn't enabled, or isn't being requested on the PR (step 5) |

A workflow fix upstream **never reaches you automatically.** The sync only ever
writes `.github/instructions/` — it does not update your copy of
`copilot-instructions-sync.yml`. Re-copy the example (step 1) to pick up
workflow changes.
