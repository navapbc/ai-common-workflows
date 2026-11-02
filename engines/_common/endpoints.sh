#!/usr/bin/env bash
# engines/_common/endpoints.sh
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
#   bedrock  AWS Bedrock (claude or codex). Requires AWS_REGION and an AWS
#            credential source. For claude: sets CLAUDE_CODE_USE_BEDROCK=1 and
#            AI_REVIEW_MODEL should be a Bedrock model ID (optional; the CLI has
#            a default). For codex: selects the codex CLI's built-in
#            amazon-bedrock provider (AWS-cred auth, direct to Bedrock) and
#            AI_REVIEW_MODEL (a Bedrock model ID) is required.
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
# copilot BYOK: the copilot CLI reads COPILOT_PROVIDER_BASE_URL,
# COPILOT_PROVIDER_TYPE (openai|azure|anthropic), COPILOT_PROVIDER_API_KEY, and
# COPILOT_MODEL directly. The engine passes these through untouched (provider
# stays api); point the base URL at an in-boundary endpoint to keep code in
# your boundary. copilot has no native Bedrock type — front Bedrock with an
# in-boundary Anthropic/OpenAI-compatible gateway.
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

# ai_review::cli_native_auth
# True when the operator has declared that the AI CLI carries its own login and
# no API key belongs in the environment.
#
# Deliberately a plain env check with no probing of the CLI's credential store.
# Reading someone's stored session to decide whether to proceed would make the
# public-endpoint decision implicitly, which is exactly the decision that has to
# stay the operator's.
ai_review::cli_native_auth() {
  [[ "${AI_REVIEW_CLI_NATIVE_AUTH:-0}" == "1" ]] || return 1

  # Refused in CI, whatever the operator set. A pipeline has no interactive
  # login, so on a hosted runner this only replaces a clear "missing key" error
  # with a confusing CLI failure later.
  #
  # On a SELF-HOSTED runner it is worse than confusing. A runner whose home
  # directory carries a persisted login would quietly use that login against
  # the public API — the exact boundary violation this check exists to prevent,
  # on the infrastructure most likely to belong to a program that cares. The
  # variable cannot be reached through either action.yml, but a job-level env:
  # in a consumer's own workflow propagates into composite steps, so "not an
  # input" is not by itself a guarantee.
  if ai_review::in_ci; then
    if [[ "${_AI_REVIEW_CLI_NATIVE_AUTH_CI_WARNED:-0}" != "1" ]]; then
      _AI_REVIEW_CLI_NATIVE_AUTH_CI_WARNED=1
      ai_review::warn "AI_REVIEW_CLI_NATIVE_AUTH=1 is ignored in CI — it is for local runs only."
      ai_review::warn "  Give the pipeline a real credential, or set AI_REVIEW_PROVIDER for an in-boundary endpoint."
    fi
    return 1
  fi
  return 0
}

# ai_review::warn_cli_native_auth
# One message for every tool, so the two call sites cannot drift apart on how
# loudly they say "public endpoint".
ai_review::warn_cli_native_auth() {
  ai_review::warn "AI_REVIEW_CLI_NATIVE_AUTH=1 — no API key in the environment; using the ${AI_REVIEW_TOOL_RESOLVED} CLI's own login."
  ai_review::warn "  Traffic goes to the PUBLIC endpoint. If this run has to stay inside a boundary,"
  ai_review::warn "  unset it and set AI_REVIEW_PROVIDER=bedrock|vertex|azure instead."
}

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

  # Provider/tool compatibility. Bedrock hosts Claude (claude) and, via the
  # codex CLI's built-in amazon-bedrock provider, OpenAI-compatible use (codex).
  # Vertex is Claude-only; Azure OpenAI is codex-only. Each rejects the wrong
  # tool up front.
  case "${provider}" in
    bedrock)
      if [[ "${AI_REVIEW_TOOL_RESOLVED}" != "claude" && "${AI_REVIEW_TOOL_RESOLVED}" != "codex" ]]; then
        ai_review::err "AI_REVIEW_PROVIDER=bedrock is only supported with AI_REVIEW_TOOL=claude or codex."
        ai_review::log "  The ${AI_REVIEW_TOOL_RESOLVED} CLI has no Bedrock backend."
        ai_review::log "  For copilot, front Bedrock with an in-boundary gateway and use copilot BYOK (COPILOT_PROVIDER_BASE_URL)."
        exit 2
      fi
      ;;
    vertex)
      if [[ "${AI_REVIEW_TOOL_RESOLVED}" != "claude" ]]; then
        ai_review::err "AI_REVIEW_PROVIDER=vertex is only supported with AI_REVIEW_TOOL=claude."
        ai_review::log "  The ${AI_REVIEW_TOOL_RESOLVED} CLI has no Vertex backend."
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
      if [[ -z "${AWS_REGION:-}" && -z "${AWS_DEFAULT_REGION:-}" ]]; then
        ai_review::err "provider=bedrock requires AWS_REGION (or AWS_DEFAULT_REGION) to be set."
        exit 2
      fi
      region="${AWS_REGION:-${AWS_DEFAULT_REGION}}"
      export AWS_REGION="${region}"
      if [[ "${AI_REVIEW_TOOL_RESOLVED}" == "claude" ]]; then
        export CLAUDE_CODE_USE_BEDROCK=1
        if [[ -z "${AI_REVIEW_MODEL:-}" ]]; then
          ai_review::warn "provider=bedrock with no AI_REVIEW_MODEL — the claude CLI's default Bedrock model will be used. Set the model input to a Bedrock model ID to pin it."
        fi
      else
        # codex: select its built-in amazon-bedrock provider (AWS-cred auth,
        # direct to Bedrock). core.sh reads this to add the codex -c overrides.
        export AI_REVIEW_CODEX_MODEL_PROVIDER="amazon-bedrock"
        if [[ -z "${AI_REVIEW_MODEL:-}" ]]; then
          ai_review::err "provider=bedrock with AI_REVIEW_TOOL=codex requires AI_REVIEW_MODEL to be a Bedrock model ID."
          exit 2
        fi
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
      #
      # Azure resolves the model from this URL PATH, not from the CLI's model
      # flag — which makes a per-pass model override a special case here and
      # nowhere else. Record what the URL was built from so the independent
      # adjudication pass can rebuild it for a different deployment
      # (ai_review::adjudicate). Without this, AI_ADJUDICATION_MODEL was
      # silently ignored under provider=azure: the flag changed, the URL did
      # not, and the "second opinion" came from the first-pass deployment.
      if [[ -z "${OPENAI_BASE_URL:-}" ]]; then
        export OPENAI_BASE_URL="${AZURE_OPENAI_ENDPOINT%/}/openai/deployments/${AI_REVIEW_MODEL}?api-version=${api_version}"
        export AI_REVIEW_AZURE_URL_TEMPLATE="${AZURE_OPENAI_ENDPOINT%/}/openai/deployments/{MODEL}?api-version=${api_version}"
      elif [[ -n "${AI_ADJUDICATION_MODEL:-}" ]] && [[ "$(ai_review::adjudication_mode)" == "independent" ]]; then
        # A caller-supplied OPENAI_BASE_URL is opaque: we cannot know where the
        # deployment name sits in it, so we cannot swap it. Fail now rather
        # than after the first pass has been paid for and the adjudication
        # quietly re-runs the same deployment.
        ai_review::err "provider=azure with a custom OPENAI_BASE_URL cannot honor AI_ADJUDICATION_MODEL:"
        ai_review::err "  Azure resolves the deployment from the URL path, and a caller-supplied URL"
        ai_review::err "  cannot be rewritten safely. Either drop AI_ADJUDICATION_MODEL (adjudication"
        ai_review::err "  then runs on the same deployment), or set AZURE_OPENAI_ENDPOINT and let the"
        ai_review::err "  engine build the URL so it can swap the deployment for the second pass."
        exit 2
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
      # A CLI can hold its own login: `claude` and `codex` both authenticate
      # interactively, and then no key exists in the environment at all. The
      # credential check below cannot see that, so it refuses a configuration
      # that works — which is the normal local setup for anyone running the
      # audit or the corpus on their own machine.
      #
      # Opting out is EXPLICIT and never inferred. Auto-detecting a usable CLI
      # login would recreate the failure this check exists to prevent: someone
      # who meant to run in-boundary, forgot AI_REVIEW_PROVIDER, and silently
      # sent the diff to the public API on a personal login. An operator has to
      # say they accept that, and gets told what they accepted.
      case "${AI_REVIEW_TOOL_RESOLVED}" in
        claude)
          if [[ -z "${ANTHROPIC_API_KEY:-}" && -z "${ANTHROPIC_AUTH_TOKEN:-}" ]]; then
            if [[ -n "${ANTHROPIC_BASE_URL:-}" ]]; then
              ai_review::warn "ANTHROPIC_BASE_URL is set but no ANTHROPIC_API_KEY/ANTHROPIC_AUTH_TOKEN — assuming the gateway handles auth."
            elif ai_review::cli_native_auth; then
              ai_review::warn_cli_native_auth
            else
              ai_review::err "AI_REVIEW_TOOL=claude with provider=api requires ANTHROPIC_API_KEY."
              ai_review::log "  Or set AI_REVIEW_PROVIDER=bedrock|vertex, or ANTHROPIC_BASE_URL for a gateway."
              ai_review::log "  If the claude CLI is already logged in and you accept the PUBLIC endpoint,"
              ai_review::log "  set AI_REVIEW_CLI_NATIVE_AUTH=1 to use that login."
              exit 2
            fi
          fi
          ;;
        codex)
          if [[ -z "${OPENAI_API_KEY:-}" ]]; then
            if [[ -n "${OPENAI_BASE_URL:-}" ]]; then
              ai_review::warn "OPENAI_BASE_URL is set but no OPENAI_API_KEY — assuming the gateway handles auth."
            elif ai_review::cli_native_auth; then
              ai_review::warn_cli_native_auth
            else
              ai_review::err "AI_REVIEW_TOOL=codex requires OPENAI_API_KEY."
              ai_review::log "  Or set OPENAI_BASE_URL for an OpenAI-compatible gateway."
              ai_review::log "  If the codex CLI is already logged in and you accept the PUBLIC endpoint,"
              ai_review::log "  set AI_REVIEW_CLI_NATIVE_AUTH=1 to use that login."
              exit 2
            fi
          fi
          ;;
        copilot)
          # CI front ends may export BYOK vars as empty strings (an unset
          # Action input renders as ""). The copilot CLI reads these directly,
          # so make set-but-empty equivalent to unset before it runs.
          local _byok_var
          for _byok_var in COPILOT_PROVIDER_BASE_URL COPILOT_PROVIDER_TYPE \
            COPILOT_PROVIDER_API_KEY COPILOT_MODEL; do
            if [[ -z "${!_byok_var:-}" ]]; then
              unset "${_byok_var}"
            fi
          done
          if [[ -n "${COPILOT_PROVIDER_BASE_URL:-}" ]]; then
            # BYOK: the copilot CLI talks directly to this endpoint. Model auth
            # is the provider key; a GitHub token may still be needed for CLI
            # entitlement, so leave that check as a soft note below.
            if [[ -z "${COPILOT_PROVIDER_API_KEY:-}" ]]; then
              ai_review::warn "copilot BYOK: COPILOT_PROVIDER_BASE_URL set with no COPILOT_PROVIDER_API_KEY — assuming the endpoint handles auth."
            fi
          fi
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
    copilot) [[ -n "${COPILOT_PROVIDER_BASE_URL:-}" ]] && base_url="${COPILOT_PROVIDER_BASE_URL}" ;;
  esac

  ai_review::info "Endpoint: tool=${AI_REVIEW_TOOL_RESOLVED} provider=${provider} region=${region} model=${AI_REVIEW_MODEL:-"(tool default)"} base_url=${base_url}"
}
