# Private & self-hosted LLM endpoints

The review works against the vendor public APIs or a private endpoint. Choose a
private endpoint when your PR diffs must not leave your network boundary.

## Compute placement — read this first

**An in-boundary LLM only keeps your code in-boundary if the review runs
in-boundary too.** The checkout, the diff, and the AI call all execute on
whatever machine runs the job. If you point at Bedrock inside your AWS
accreditation boundary but run on a GitHub-hosted runner, your code is being
read on GitHub's shared infrastructure — outside the boundary you were trying
to keep.

So, when the endpoint is in-boundary, run the review on in-boundary compute:

- **GitHub Actions:** a self-hosted runner in your VPC, or GitHub Actions
  backed by **AWS CodeBuild**. Set `runs-on: [self-hosted, linux, x64]` (or your
  labels). Bedrock is then reachable via a VPC endpoint, and traffic never
  traverses the public internet.
- **Jenkins:** agents in your VPC — in-boundary by nature. This is a reason to
  prefer the Jenkins plugin for strict environments.

Decide deliberately; don't let a copy-pasted `runs-on: ubuntu-latest` make the
call for you.

## Amazon Bedrock (claude or codex)

```yaml
permissions: { contents: read, pull-requests: write, id-token: write }
jobs:
  review:
    runs-on: [self-hosted, linux, x64] # in your VPC; or ubuntu-latest if acceptable
    steps:
      - uses: actions/checkout@v7
        with: { ref: "${{ github.event.pull_request.head.sha }}" }
      - uses: aws-actions/configure-aws-credentials@v4
        with:
          role-to-assume: arn:aws:iam::123456789012:role/ai-pr-review
          aws-region: us-east-1
      - uses: navapbc/ai-common-workflows/workflows/security-compliance-review@<commit-sha> # v1.0.0
        with:
          provider: bedrock
          aws-region: us-east-1
          model: us.anthropic.claude-sonnet-4-5-20250929-v1:0
```

**Least privilege (imperative):** the IAM role should allow only
`bedrock:InvokeModel` (+ `bedrock:InvokeModelWithResponseStream`) on the
specific model ARN(s) — never `bedrock:*`. Assume it via OIDC (no long-lived
keys) with a trust policy that pins your repo/ref. Full policy example in
[security.md](security.md#the-llm-credential-bedrock--vertex).

On self-hosted runners without instance-role credentials, provide them via
OIDC (`configure-aws-credentials`) or the standard AWS env vars.

### Bedrock with `codex`

If your program allows the **Codex** CLI (not `claude`), set `ai-tool: codex` —
the engine selects Codex's built-in `amazon-bedrock` provider, which
authenticates with the same AWS credentials and calls Bedrock **directly** (no
gateway). `model` (a Bedrock model ID) is **required** for codex.

```yaml
      - uses: navapbc/ai-common-workflows/workflows/security-compliance-review@<commit-sha> # v1.0.0
        with:
          ai-tool: codex
          provider: bedrock
          aws-region: us-east-1
          model: us.anthropic.claude-sonnet-4-5-20250929-v1:0   # a Bedrock model ID
```

The IAM scope is identical to the claude case. (Codex's built-in Bedrock
provider does not accept a custom `base_url`; VPC-interface-endpoint routing is
handled by AWS networking, not Codex config.)

Expect a benign startup warning — `Model metadata for '<model id>' not found.
Defaulting to fallback metadata` — because Codex doesn't ship metadata (context
window, etc.) for Bedrock model IDs. The review still runs; very large diffs
may batch more conservatively than with a natively-known model.

**Jenkins:** ambient agent credentials (instance profile / IRSA) are used
directly, or wrap the step. Works the same for `claude` and `codex`:

```groovy
withCredentials([aws(credentialsId: 'aws-bedrock', ...)]) {
  aiSecurityComplianceReview(tool: 'claude', endpoint: 'bedrock', awsRegion: 'us-east-1',
             model: 'us.anthropic.claude-sonnet-4-5-20250929-v1:0')
  // or tool: 'codex' with a Bedrock model id — same endpoint/region/creds.
}
```

## Google Vertex AI (claude)

```yaml
      - uses: google-github-actions/auth@v2
        with:
          workload_identity_provider: projects/…/providers/…
          service_account: ai-pr-review@project.iam.gserviceaccount.com
      - uses: navapbc/ai-common-workflows/workflows/security-compliance-review@<commit-sha> # v1.0.0
        with:
          provider: vertex
          vertex-project-id: my-gcp-project
          vertex-region: us-east5
          model: claude-sonnet-4-5@20250929
```

Auth uses ambient Google Application Default Credentials. Grant the
workload-identity service account only the **Vertex AI User** role (or a
custom role with just `aiplatform.endpoints.predict`), scoped to the project —
not Editor/Owner.

## Azure OpenAI (codex)

Azure serves **OpenAI** models, not Claude, so `provider=azure` drives the
`codex` tool. The engine builds the OpenAI-compatible base URL from your
resource endpoint, the deployment name (`model`), and the API version:

```yaml
      - uses: navapbc/ai-common-workflows/workflows/security-compliance-review@<commit-sha> # v1.0.0
        with:
          ai-tool: codex
          provider: azure
          azure-openai-endpoint: https://my-resource.openai.azure.com
          azure-openai-api-key: ${{ secrets.AZURE_OPENAI_API_KEY }}
          azure-openai-api-version: "2024-10-21" # optional; this is the default
          model: my-gpt-deployment            # the Azure *deployment* name
```

The derived endpoint is
`https://<resource>.openai.azure.com/openai/deployments/<deployment>?api-version=<version>`.
If you would rather pass the full URL yourself, set `openai-base-url` directly
and it is used as-is. Keep your Azure resource in the region/boundary you need;
as with Bedrock, in-boundary only holds if the review also runs on in-boundary
compute.

**Least privilege:** issue a key (or use a managed identity via a gateway)
scoped to the one deployment, and prefer a Private Endpoint / firewall so the
resource is not publicly reachable.

**Jenkins:** set the endpoint to `azure`, point the OpenAI base URL at the full
Azure deployment URL, and supply the key as an OpenAI Secret-text credential:

```groovy
aiSecurityComplianceReview(tool: 'codex', endpoint: 'azure',
           model: 'my-gpt-deployment',
           openaiBaseUrl: 'https://my-resource.openai.azure.com/openai/deployments/my-gpt-deployment?api-version=2024-10-21',
           openaiApiKeyCredentialsId: 'azure-openai-key')
```

## Copilot BYOK (bring your own key)

The **Copilot** CLI supports BYOK: it talks **directly** to an endpoint you
specify, rather than GitHub's hosted models. Configure it with the
`copilot-provider-*` inputs (the engine passes them through as
`COPILOT_PROVIDER_BASE_URL` / `_TYPE` / `_API_KEY` and `COPILOT_MODEL`):

```yaml
      - uses: navapbc/ai-common-workflows/workflows/security-compliance-review@<commit-sha> # v1.0.0
        with:
          ai-tool: copilot
          copilot-provider-base-url: https://llm-gw.internal/v1
          copilot-provider-type: anthropic        # openai | azure | anthropic
          copilot-provider-api-key: ${{ secrets.GATEWAY_TOKEN }}
          copilot-model: claude-sonnet-4-5
```

Because requests go straight to `copilot-provider-base-url`, pointing it at an
in-boundary endpoint keeps code in your boundary. Copilot has **no native
Bedrock type** (`copilot-provider-type` is only `openai`/`azure`/`anthropic`),
so to reach **Bedrock** front it with an in-boundary Anthropic- or
OpenAI-compatible gateway (e.g. LiteLLM or AWS's Bedrock Access Gateway) and set
the type accordingly. Note the copilot CLI may still need a GitHub token for CLI
entitlement even under BYOK.

**Jenkins:** the same values are step params (`copilotProviderBaseUrl`,
`copilotProviderType`, `copilotModel`) plus a Secret-text credential for the key:

```groovy
aiSecurityComplianceReview(tool: 'copilot',
           copilotProviderBaseUrl: 'https://llm-gw.internal/v1',
           copilotProviderType: 'anthropic',
           copilotProviderApiKeyCredentialsId: 'copilot-byok-key',
           copilotModel: 'claude-sonnet-4-5',
           githubTokenCredentialsId: 'gh-pr-review')
```

## Custom gateway / proxy (claude or codex)

For a LiteLLM / gateway deployment that speaks the Anthropic or OpenAI API:

```yaml
      - uses: navapbc/ai-common-workflows/workflows/security-compliance-review@<commit-sha> # v1.0.0
        with:
          ai-tool: claude
          anthropic-base-url: https://llm-gw.internal/v1
          anthropic-api-key: ${{ secrets.GATEWAY_TOKEN }}
```

For `codex`, use `openai-base-url` and `openai-api-key`. Make sure the
runner's egress policy permits your gateway host (see
[security.md](security.md)).
