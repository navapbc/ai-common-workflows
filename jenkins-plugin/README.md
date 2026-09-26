# AI Security & Compliance Review — Jenkins plugin

Adds a single `aiSecurityComplianceReview` pipeline step that runs the same AI
security & compliance review engine as the [GitHub Action](../docs/github-action.md),
on your Jenkins agents. Supports Claude, Codex, and Copilot on the public API or
a private endpoint (Bedrock, Vertex, Azure OpenAI, or a custom gateway), with a
selectable compliance `profile` — an ordered list of rubric sources starting
with `base` or `none`, e.g. `base` (the default floor) or `base,cms-ars`.

The plugin is thin: it bundles its engine + `engines/_common` (a snapshot, zipped at build
time), extracts it onto the agent at runtime, and runs it. Shared machinery
(engine extraction, endpoint mapping, PR-context resolution) lives in a separate
**`ai-common-core`** library plugin that this plugin depends on. There is one
source of truth for review logic across the Action and the plugin.

## Install

The plugin depends on the shared `ai-common-core` library plugin, so install
**both**:

1. Download `ai-security-compliance-review.hpi` **and** `ai-common-core.hpi`
   from the [latest release](https://github.com/navapbc/ai-common-workflows/releases).
2. **Verify build provenance** (requires `gh` ≥ 2.49). Each release carries a
   signed [artifact attestation](https://docs.github.com/actions/security-for-github-actions/using-artifact-attestations)
   binding the `.hpi` to this repo's release workflow and tagged commit; a
   tampered or re-uploaded asset fails this check:
   ```bash
   gh attestation verify ai-security-compliance-review.hpi -R navapbc/ai-common-workflows
   gh attestation verify ai-common-core.hpi -R navapbc/ai-common-workflows
   ```
   The `.sha256` sidecars remain for download-integrity checks
   (`sha256sum -c`), but they are not tamper-proof on their own — the
   attestation is the authenticity check.
3. Manage Jenkins → Plugins → Advanced settings → Deploy Plugin → upload **both**
   `.hpi` files → restart Jenkins. (Installing from an update center resolves the
   `ai-common-core` dependency automatically; manual upload does not. Jenkins
   itself performs no signature verification on manually uploaded plugins —
   step 2 is the verification.)

Upgrades are a deliberate admin action — never automatic. Review the changes
between releases as you would any third-party CI dependency (see
[docs/security.md](../docs/security.md)).

## Agent prerequisites

The step runs the engine natively on a **Linux/Unix agent**, which needs
`bash`, `git`, `gh`, `python3`, Node.js, and the chosen AI CLI on `PATH`, plus
network access to your LLM and SCM endpoints. A sample agent image:

```dockerfile
FROM node:22-slim
RUN apt-get update && apt-get install -y --no-install-recommends \
      git python3 gh ca-certificates && rm -rf /var/lib/apt/lists/*
RUN npm install -g @anthropic-ai/claude-code
```

There is no built-in network sandbox in this release, so **egress control is
your infrastructure's responsibility** — run the agent in a network that
restricts egress to your LLM endpoint, SCM, and the controller. See
[docs/security.md](../docs/security.md).

## Credentials — least privilege is imperative

Create **Secret text** credentials (Manage Jenkins → Credentials) and reference
them by ID:

| Credential | Used for |
|---|---|
| Anthropic API key | `tool=claude`, endpoint `direct`/`custom` |
| OpenAI API key | `tool=codex` |
| GitHub token | posting the review; Copilot model auth |

**The GitHub token must be least-privilege.** Jenkins has no ambient workflow
token, so use a **fine-grained PAT scoped to only the target repositories**
with **Pull requests: Read and write** and **Contents: Read** — nothing else.
Do **not** use a classic PAT (its `repo` scope is far broader than needed). A
**GitHub App** installation token (short-lived, per-repo) is stronger still.

The token is injected **only into the post phase**, not the AI phase: the step
runs the review with no `GITHUB_TOKEN` in its environment, then posts in a
separate process that has it — so injected PR content can't reach it. (The
`copilot` backend is the exception: its model auth is a GitHub token, so it's
present during copilot's AI phase.)

For **Bedrock**, don't create a plugin credential — the engine uses ambient AWS
credentials on the agent (instance profile / IRSA), scoped by an IAM policy
that allows only `bedrock:InvokeModel` on your model ARN(s) (see
[docs/security.md](../docs/security.md)). Or wrap the step:

```groovy
withCredentials([aws(credentialsId: 'aws-bedrock', ...)]) {
  aiSecurityComplianceReview(tool: 'claude', endpoint: 'bedrock', awsRegion: 'us-east-1')
}
```

## Global configuration

Manage Jenkins → System → **AI Security & Compliance Review** sets org-wide
defaults (tool, endpoint, model, compliance profile, region, gate, credential
IDs). Any default set here is used whenever the matching step parameter is
omitted, so the common Jenkinsfile case is a bare
`aiSecurityComplianceReview()`. The section is JCasC-compatible:

```yaml
unclassified:
  aiSecurityComplianceReview:
    tool: claude
    endpoint: bedrock
    awsRegion: us-east-1
    model: us.anthropic.claude-sonnet-4-5-20250929-v1:0
    gate: unstable
    githubTokenCredentialsId: gh-pr-review
```

## Jenkinsfile examples

Minimal (multibranch PR build, defaults from global config):

```groovy
stage('AI Security & Compliance Review') {
  when { changeRequest() }
  steps { aiSecurityComplianceReview() }
}
```

Public API with explicit credential, gating as unstable:

```groovy
aiSecurityComplianceReview tool: 'claude',
           anthropicApiKeyCredentialsId: 'anthropic-key',
           githubTokenCredentialsId: 'gh-pr-review',
           gate: 'unstable'
```

Bedrock (in-VPC agent, ambient AWS creds). Works with `tool: 'claude'` or
`tool: 'codex'` — codex uses its built-in `amazon-bedrock` provider, same
endpoint/region/creds (a Bedrock model id is required for codex):

```groovy
aiSecurityComplianceReview tool: 'claude', endpoint: 'bedrock',
           awsRegion: 'us-east-1',
           model: 'us.anthropic.claude-sonnet-4-5-20250929-v1:0',
           githubTokenCredentialsId: 'gh-pr-review'
```

Copilot BYOK (point the CLI at your own model endpoint; key as Secret-text):

```groovy
aiSecurityComplianceReview tool: 'copilot',
           copilotProviderBaseUrl: 'https://llm-gw.internal/v1',
           copilotProviderType: 'anthropic',   // openai | azure | anthropic
           copilotProviderApiKeyCredentialsId: 'copilot-byok-key',
           copilotModel: 'claude-sonnet-4-5',
           githubTokenCredentialsId: 'gh-pr-review'
```

Azure OpenAI (codex; Azure serves OpenAI models). Point the OpenAI base URL at
the full deployment URL and pass the key as an OpenAI Secret-text credential:

```groovy
aiSecurityComplianceReview tool: 'codex', endpoint: 'azure',
           model: 'my-gpt-deployment',
           openaiBaseUrl: 'https://my-resource.openai.azure.com/openai/deployments/my-gpt-deployment?api-version=2024-10-21',
           openaiApiKeyCredentialsId: 'azure-openai-key',
           githubTokenCredentialsId: 'gh-pr-review'
```

Custom gateway (LiteLLM/proxy):

```groovy
aiSecurityComplianceReview tool: 'claude', endpoint: 'custom',
           anthropicBaseUrl: 'https://llm-gw.internal/v1',
           githubTokenCredentialsId: 'gh-pr-review'
```

GitHub Enterprise:

```groovy
aiSecurityComplianceReview githubServerUrl: 'github.mycorp.com',
           githubTokenCredentialsId: 'ghe-pr-review'
```

## How much the review says

Two parameters shape what lands on the PR. Both are read by the post phase, so
neither has any effect when `postComments: false`.

```groovy
aiSecurityComplianceReview githubTokenCredentialsId: 'gh-pr-review',
           postWhenClean: true,   // acknowledge clean PRs too (default false)
           maxComments: 25        // inline comments per review (default 50)
```

`postWhenClean` — by default a review that found nothing posts nothing. The
build result already reports a clean run, so acknowledging every clean PR is a
notification whose entire content is that nothing happened, and a reviewer that
speaks on every PR is one people learn to scroll past. Turn it on where the
approval on the PR is itself the artifact — evidence per PR that outlives a
build record. Findings always post regardless, and so does a `REQUEST_CHANGES`
review carrying none.

`maxComments` — over the limit the highest-severity findings stay inline and
the rest are listed in the review body under a heading saying the limit was
reached. Nothing is dropped and the gate still accounts for every finding, so
this trades line anchoring for volume, never coverage. `0` means no limit.
Leave it unset to take the engine default.

## How gating maps to the build result

| `gate` | Non-APPROVE result | APPROVE |
|---|---|---|
| `none` (default) | build stays green; findings are advisory | green |
| `unstable` | build marked **UNSTABLE** | green |
| `failure` | build **fails** | green |

Engine exit codes: `0` pass/advisory, `1` gate-fail or runtime error, `2`
configuration error (always fails the step). Because exit `1` covers both a
gated non-APPROVE and a genuine error, treat an unexpected failure as a signal
to check the log.

## PR context

The step derives the PR number and base branch from the branch-source
`CHANGE_ID` / `CHANGE_TARGET` environment variables (set on multibranch PR
builds). Override with the `pr` and `against` parameters for other setups.

## Developing

```bash
cd jenkins-plugin
mvn verify                                   # build + test all modules (reactor)
mvn -pl security-compliance-review -am hpi:run   # scratch Jenkins at http://localhost:8080/jenkins
```

The reactor has two modules: `core` (the `ai-common-core` library plugin) and
`security-compliance-review` (this plugin). `mvn verify` from `jenkins-plugin/`
builds both; the runnable plugin is `security-compliance-review`.

Use `engineOverridePath` in a Jenkinsfile to run a working-copy engine instead
of the bundled zip while iterating on engine logic.

## Troubleshooting

- **"requires a Linux/Unix agent"** — the engine is bash-based; use a Linux agent.
- **"could not determine the PR base ref"** — run on a multibranch PR build, or
  set `pr` and `against` explicitly.
- **No such credential** — the `*CredentialsId` must reference an existing
  Secret-text credential in a scope the job can see.
- **AI CLI not found** — install it on the agent (`npm install -g …`) or bake
  it into the agent image; the plugin does not install it for you.
