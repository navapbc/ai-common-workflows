# AI PR Review — Jenkins plugin

Adds a single `aiPrReview` pipeline step that runs the same AI security &
compliance review engine as the [GitHub Action](../docs/github-action.md), on
your Jenkins agents. Supports Claude, Codex, and Copilot on the public API or a
private endpoint (Bedrock, Vertex, or a custom gateway).

The plugin is a thin wrapper: it bundles the shared `engine/` (a snapshot,
zipped at build time), extracts it onto the agent at runtime, and runs it.
There is one source of truth for review logic across the Action and the plugin.

## Install

1. Download `ai-pr-review.hpi` from the
   [latest release](https://github.com/navapbc/ai-reusable-workflows/releases)
   and **verify its SHA-256 against the checksum in the release notes**
   (`sha256sum ai-pr-review.hpi`).
2. Manage Jenkins → Plugins → Advanced settings → Deploy Plugin → upload the
   `.hpi` → restart Jenkins.

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

For **Bedrock**, don't create a plugin credential — the engine uses ambient AWS
credentials on the agent (instance profile / IRSA), scoped by an IAM policy
that allows only `bedrock:InvokeModel` on your model ARN(s) (see
[docs/security.md](../docs/security.md)). Or wrap the step:

```groovy
withCredentials([aws(credentialsId: 'aws-bedrock', ...)]) {
  aiPrReview(tool: 'claude', endpoint: 'bedrock', awsRegion: 'us-east-1')
}
```

## Global configuration

Manage Jenkins → System → **AI PR Review** sets org-wide defaults (tool,
endpoint, model, region, gate, credential IDs). Any default set here is used
whenever the matching step parameter is omitted, so the common Jenkinsfile case
is a bare `aiPrReview()`. The section is JCasC-compatible:

```yaml
unclassified:
  aiPrReview:
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
stage('AI PR Review') {
  when { changeRequest() }
  steps { aiPrReview() }
}
```

Public API with explicit credential, gating as unstable:

```groovy
aiPrReview tool: 'claude',
           anthropicApiKeyCredentialsId: 'anthropic-key',
           githubTokenCredentialsId: 'gh-pr-review',
           gate: 'unstable'
```

Bedrock (in-VPC agent, ambient AWS creds):

```groovy
aiPrReview tool: 'claude', endpoint: 'bedrock',
           awsRegion: 'us-east-1',
           model: 'us.anthropic.claude-sonnet-4-5-20250929-v1:0',
           githubTokenCredentialsId: 'gh-pr-review'
```

Custom gateway (LiteLLM/proxy):

```groovy
aiPrReview tool: 'claude', endpoint: 'custom',
           anthropicBaseUrl: 'https://llm-gw.internal/v1',
           githubTokenCredentialsId: 'gh-pr-review'
```

GitHub Enterprise:

```groovy
aiPrReview githubServerUrl: 'github.mycorp.com',
           githubTokenCredentialsId: 'ghe-pr-review'
```

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
mvn hpi:run          # scratch Jenkins at http://localhost:8080/jenkins
mvn verify           # compile + tests (JenkinsRule)
```

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
