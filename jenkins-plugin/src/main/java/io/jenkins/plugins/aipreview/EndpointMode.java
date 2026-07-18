package io.jenkins.plugins.aipreview;

/**
 * LLM endpoint modes exposed by the plugin. Mirrors the engine's
 * {@code AI_REVIEW_PROVIDER} plus the custom-base-URL case, which the engine
 * treats as {@code api} with a base-URL override.
 */
public enum EndpointMode {
    /** Vendor public API (Anthropic / OpenAI / Copilot). */
    DIRECT,
    /** Amazon Bedrock (claude only). */
    BEDROCK,
    /** Google Vertex AI (claude only). */
    VERTEX,
    /** OpenAI/Anthropic-compatible gateway via a custom base URL. */
    CUSTOM;

    /** The engine {@code AI_REVIEW_PROVIDER} value for this mode. */
    public String provider() {
        switch (this) {
            case BEDROCK:
                return "bedrock";
            case VERTEX:
                return "vertex";
            default:
                // DIRECT and CUSTOM both use the vendor SDK path; CUSTOM only
                // differs by the base-URL env var, set separately.
                return "api";
        }
    }
}
