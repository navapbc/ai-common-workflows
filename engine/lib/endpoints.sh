#!/usr/bin/env bash
# engine/lib/endpoints.sh
#
# LLM endpoint configuration for the AI PR-review engine. Maps the
# AI_REVIEW_PROVIDER selection onto the environment variables each AI CLI
# expects, validates that the required configuration is present, and prints
# one audit line per run stating which endpoint the review will use.
#
# Providers:
#   api      (default) The tool vendor's public API. Requires the matching
#            API key (ANTHROPIC_API_KEY / OPENAI_API_KEY); copilot
#            authenticates through its own GitHub token flow.
#   bedrock  AWS Bedrock (claude only). Sets CLAUDE_CODE_USE_BEDROCK=1;
#            requires AWS_REGION and an AWS credential source. AI_REVIEW_MODEL
#            should be a Bedrock model ID or inference-profile ARN.
#   vertex   Google Vertex AI (claude only). Sets CLAUDE_CODE_USE_VERTEX=1;
#            requires ANTHROPIC_VERTEX_PROJECT_ID and CLOUD_ML_REGION; auth
#            via ambient Google Application Default Credentials.
#   azure    Azure OpenAI Service (codex only). Azure serves OpenAI models,
#            so it drives the OpenAI-compatible CLI: requires
#            AZURE_OPENAI_ENDPOINT and AI_REVIEW_MODEL (the deployment name).
#            AZURE_OPENAI_API_KEY supplies the key; AZURE_OPENAI_API_VERSION
#            selects the REST API version. The engine derives OPENAI_BASE_URL /
#            OPENAI_API_KEY from these unless they are already set.
#
# Independent of the provider, ANTHROPIC_BASE_URL and OPENAI_BASE_URL pass
# through untouched — that is how gateway/proxy deployments (LiteLLM etc.)
# point the CLIs at a custom endpoint.
#
# Secrets are never printed. The audit line names the tool, provider, region,
# model, and whether a base-URL override is in effect — nothing more.

set -euo pipefail

if [[ "${_AI_REVIEW_ENDPOINTS_LOADED:-0}" == "1" ]]; then
  return 0
fi
_AI_REVIEW_ENDPOINTS_LOADED=1

# ai_review::configure_endpoint
# Reads:  AI_REVIEW_TOOL_RESOLVED (set by ai_review::resolve_tool),
#         AI_REVIEW_PROVIDER, AI_REVIEW_MODEL, provider-specific env.
# Exports the CLI-specific env vars and prints the audit line. Exits 2 on
# invalid/missing configuration.
ai_review::configure_endpoint() {
  local provider
  provider="$(printf '%s' "${AI_REVIEW_PROVIDER:-api}" | tr '[:upper:]' '[:lower:]')"

  case "${provider}" in
    api | bedrock | vertex | azure) ;;
    *)
      ai_review::err "AI_REVIEW_PROVIDER='${AI_REVIEW_PROVIDER}' is not a recognized value."
      ai_review::log "  Valid values: api | bedrock | vertex | azure"
      exit 2
      ;;
  esac

  # Provider/tool compatibility. Bedrock and Vertex host Claude; Azure serves
  # OpenAI models via the codex CLI. Each rejects the wrong tool up front.
  case "${provider}" in
    bedrock | vertex)
      if [[ "${AI_REVIEW_TOOL_RESOLVED}" != "claude" ]]; then
        ai_review::err "AI_REVIEW_PROVIDER=${provider} is only supported with AI_REVIEW_TOOL=claude."
        ai_review::log "  The ${AI_REVIEW_TOOL_RESOLVED} CLI has no ${provider} backend."
        ai_review::log "  For codex on Azure OpenAI, use AI_REVIEW_PROVIDER=azure, or point OPENAI_BASE_URL at a gateway."
        exit 2
      fi
      ;;
    azure)
      if [[ "${AI_REVIEW_TOOL_RESOLVED}" != "codex" ]]; then
        ai_review::err "AI_REVIEW_PROVIDER=azure is only supported with AI_REVIEW_TOOL=codex (Azure OpenAI serves OpenAI models)."
        ai_review::log "  For claude, use AI_REVIEW_PROVIDER=bedrock|vertex, or ANTHROPIC_BASE_URL for a gateway."
        exit 2
      fi
      ;;
  esac

  local region="-" base_url="(default)"

  case "${provider}" in
    bedrock)
      export CLAUDE_CODE_USE_BEDROCK=1
      if [[ -z "${AWS_REGION:-}" && -z "${AWS_DEFAULT_REGION:-}" ]]; then
        ai_review::err "provider=bedrock requires AWS_REGION (or AWS_DEFAULT_REGION) to be set."
        exit 2
      fi
      region="${AWS_REGION:-${AWS_DEFAULT_REGION}}"
      if [[ -z "${AI_REVIEW_MODEL:-}" ]]; then
        ai_review::warn "provider=bedrock with no AI_REVIEW_MODEL — the claude CLI's default Bedrock model will be used. Set the model input to a Bedrock model ID to pin it."
      fi
      # Detect a usable credential source; warn (not fail) when none is
      # visible — an instance role may still satisfy the SDK at runtime.
      if [[ -z "${AWS_ACCESS_KEY_ID:-}" && -z "${AWS_PROFILE:-}" &&
        -z "${AWS_WEB_IDENTITY_TOKEN_FILE:-}" &&
        -z "${AWS_CONTAINER_CREDENTIALS_RELATIVE_URI:-}" &&
        -z "${AWS_CONTAINER_CREDENTIALS_FULL_URI:-}" ]]; then
        ai_review::warn "No AWS credential source detected in the environment (env keys, profile, web identity, or container credentials). Bedrock calls will fail unless the host provides an instance role."
      fi
      ;;
    vertex)
      export CLAUDE_CODE_USE_VERTEX=1
      if [[ -z "${ANTHROPIC_VERTEX_PROJECT_ID:-}" ]]; then
        ai_review::err "provider=vertex requires ANTHROPIC_VERTEX_PROJECT_ID to be set."
        exit 2
      fi
      if [[ -z "${CLOUD_ML_REGION:-}" ]]; then
        ai_review::err "provider=vertex requires CLOUD_ML_REGION to be set (e.g. us-east5)."
        exit 2
      fi
      region="${CLOUD_ML_REGION}"
      ;;
    azure)
      # Azure OpenAI, reached through the OpenAI-compatible CLI. Derive
      # OPENAI_BASE_URL / OPENAI_API_KEY from the Azure-specific inputs unless
      # the caller already set the OpenAI vars directly.
      if [[ -z "${AZURE_OPENAI_ENDPOINT:-}" && -z "${OPENAI_BASE_URL:-}" ]]; then
        ai_review::err "provider=azure requires AZURE_OPENAI_ENDPOINT (e.g. https://my-resource.openai.azure.com)."
        exit 2
      fi
      if [[ -z "${AI_REVIEW_MODEL:-}" ]]; then
        ai_review::err "provider=azure requires AI_REVIEW_MODEL to be set to the Azure deployment name."
        exit 2
      fi
      local api_version="${AZURE_OPENAI_API_VERSION:-2024-10-21}"
      # Build the deployment URL only if the caller has not supplied one.
      if [[ -z "${OPENAI_BASE_URL:-}" ]]; then
        export OPENAI_BASE_URL="${AZURE_OPENAI_ENDPOINT%/}/openai/deployments/${AI_REVIEW_MODEL}?api-version=${api_version}"
      fi
      if [[ -z "${OPENAI_API_KEY:-}" && -n "${AZURE_OPENAI_API_KEY:-}" ]]; then
        export OPENAI_API_KEY="${AZURE_OPENAI_API_KEY}"
      fi
      if [[ -z "${OPENAI_API_KEY:-}" ]]; then
        ai_review::warn "provider=azure with no AZURE_OPENAI_API_KEY/OPENAI_API_KEY — assuming the endpoint handles auth."
      fi
      # The resource region is encoded in the endpoint host; the audit line's
      # base_url (printed below for codex) already shows it and the api-version.
      ;;
    api)
      case "${AI_REVIEW_TOOL_RESOLVED}" in
        claude)
          if [[ -z "${ANTHROPIC_API_KEY:-}" && -z "${ANTHROPIC_AUTH_TOKEN:-}" ]]; then
            if [[ -n "${ANTHROPIC_BASE_URL:-}" ]]; then
              ai_review::warn "ANTHROPIC_BASE_URL is set but no ANTHROPIC_API_KEY/ANTHROPIC_AUTH_TOKEN — assuming the gateway handles auth."
            else
              ai_review::err "AI_REVIEW_TOOL=claude with provider=api requires ANTHROPIC_API_KEY."
              ai_review::log "  Or set AI_REVIEW_PROVIDER=bedrock|vertex, or ANTHROPIC_BASE_URL for a gateway."
              exit 2
            fi
          fi
          ;;
        codex)
          if [[ -z "${OPENAI_API_KEY:-}" ]]; then
            if [[ -n "${OPENAI_BASE_URL:-}" ]]; then
              ai_review::warn "OPENAI_BASE_URL is set but no OPENAI_API_KEY — assuming the gateway handles auth."
            else
              ai_review::err "AI_REVIEW_TOOL=codex requires OPENAI_API_KEY."
              ai_review::log "  Or set OPENAI_BASE_URL for an OpenAI-compatible gateway."
              exit 2
            fi
          fi
          ;;
        copilot)
          if [[ -z "${GITHUB_TOKEN:-}" && -z "${GH_TOKEN:-}" && -z "${COPILOT_GITHUB_TOKEN:-}" ]]; then
            ai_review::warn "AI_REVIEW_TOOL=copilot with no GitHub token in the environment — the copilot CLI must already be authenticated on this host."
          fi
          ;;
      esac
      ;;
  esac

  # Base-URL overrides pass through for any provider; report their presence
  # (never the value's credentials, though a URL itself is not a secret).
  case "${AI_REVIEW_TOOL_RESOLVED}" in
    claude) [[ -n "${ANTHROPIC_BASE_URL:-}" ]] && base_url="${ANTHROPIC_BASE_URL}" ;;
    codex) [[ -n "${OPENAI_BASE_URL:-}" ]] && base_url="${OPENAI_BASE_URL}" ;;
  esac

  ai_review::info "Endpoint: tool=${AI_REVIEW_TOOL_RESOLVED} provider=${provider} region=${region} model=${AI_REVIEW_MODEL:-"(tool default)"} base_url=${base_url}"
}
