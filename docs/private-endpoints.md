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

## Amazon Bedrock (claude)

```yaml
permissions: { contents: read, pull-requests: write, id-token: write }
jobs:
  review:
    runs-on: [self-hosted, linux, x64] # in your VPC; or ubuntu-latest if acceptable
    steps:
      - uses: actions/checkout@v4
        with: { ref: "${{ github.event.pull_request.head.sha }}" }
      - uses: aws-actions/configure-aws-credentials@v4
        with:
          role-to-assume: arn:aws:iam::123456789012:role/ai-pr-review
          aws-region: us-east-1
      - uses: navapbc/ai-reusable-workflows@<commit-sha> # v1.0.0
        with:
          provider: bedrock
          aws-region: us-east-1
          model: us.anthropic.claude-sonnet-4-5-20250929-v1:0
```

The sandbox allowlist for Bedrock is derived automatically:
`bedrock-runtime.<region>.amazonaws.com` plus regional STS. On self-hosted
runners without instance-role credentials, provide them via OIDC
(`configure-aws-credentials`) or the standard AWS env vars.

**Jenkins:** ambient agent credentials (instance profile / IRSA) are used
directly, or wrap the step:

```groovy
withCredentials([aws(credentialsId: 'aws-bedrock', ...)]) {
  aiPrReview(tool: 'claude', endpoint: 'bedrock', awsRegion: 'us-east-1',
             model: 'us.anthropic.claude-sonnet-4-5-20250929-v1:0')
}
```

## Google Vertex AI (claude)

```yaml
      - uses: google-github-actions/auth@v2
        with:
          workload_identity_provider: projects/…/providers/…
          service_account: ai-pr-review@project.iam.gserviceaccount.com
      - uses: navapbc/ai-reusable-workflows@<commit-sha> # v1.0.0
        with:
          provider: vertex
          vertex-project-id: my-gcp-project
          vertex-region: us-east5
          model: claude-sonnet-4-5@20250929
```

Allowlist: `aiplatform.googleapis.com`, the regional Vertex host, and
`oauth2.googleapis.com`. Auth uses ambient Google Application Default
Credentials.

## Custom gateway / proxy (claude or codex)

For a LiteLLM / gateway deployment that speaks the Anthropic or OpenAI API:

```yaml
      - uses: navapbc/ai-reusable-workflows@<commit-sha> # v1.0.0
        with:
          ai-tool: claude
          anthropic-base-url: https://llm-gw.internal/v1
          anthropic-api-key: ${{ secrets.GATEWAY_TOKEN }}
          extra-allowed-hosts: llm-gw.internal
```

`extra-allowed-hosts` adds your gateway to the sandbox egress allowlist (the
base URL's host is added automatically; list it explicitly if it differs, e.g.
a separate auth host). For `codex`, use `openai-base-url` and `openai-api-key`.

## Mirroring the review image

In restricted networks that can't reach `ghcr.io`, mirror the review image into
your registry and pin `review-image` to the mirrored digest:

```bash
crane copy ghcr.io/navapbc/ai-reusable-workflows/ai-pr-review@sha256:… \
           registry.internal/ai-pr-review@sha256:…
```
