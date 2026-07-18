package io.jenkins.plugins.aipreview;

import com.cloudbees.plugins.credentials.CredentialsProvider;
import hudson.AbortException;
import hudson.EnvVars;
import hudson.FilePath;
import hudson.Launcher;
import hudson.model.Result;
import hudson.model.Run;
import hudson.model.TaskListener;
import hudson.util.Secret;
import io.jenkins.plugins.aipreview.scm.PrContext;
import io.jenkins.plugins.aipreview.scm.PrContextResolver;
import java.io.IOException;
import java.io.PrintStream;
import java.util.ArrayList;
import java.util.List;
import org.jenkinsci.plugins.plaincredentials.StringCredentials;
import org.jenkinsci.plugins.workflow.steps.StepContext;
import org.jenkinsci.plugins.workflow.steps.SynchronousNonBlockingStepExecution;

/**
 * Runs the bundled review engine on the build node: resolve effective config,
 * extract the engine, inject credentials as environment (never argv), launch
 * the engine (sandboxed by default), and map its exit code onto the build
 * result. Non-blocking so it does not tie up an executor while the AI runs.
 */
class AiPrReviewStepExecution extends SynchronousNonBlockingStepExecution<Void> {

    private static final long serialVersionUID = 1L;

    private final transient AiPrReviewStep step;

    AiPrReviewStepExecution(StepContext context, AiPrReviewStep step) {
        super(context);
        this.step = step;
    }

    @Override
    protected Void run() throws Exception {
        StepContext ctx = getContext();
        Run<?, ?> run = ctx.get(Run.class);
        FilePath workspace = ctx.get(FilePath.class);
        Launcher launcher = ctx.get(Launcher.class);
        TaskListener listener = ctx.get(TaskListener.class);
        EnvVars env = ctx.get(EnvVars.class);
        if (run == null || workspace == null || launcher == null || listener == null || env == null) {
            throw new AbortException("aiPrReview requires a node { } context with a workspace.");
        }
        PrintStream log = listener.getLogger();

        if (!launcher.isUnix()) {
            throw new AbortException("aiPrReview requires a Linux/Unix agent (the engine is bash-based).");
        }

        AiPrReviewGlobalConfiguration cfg = AiPrReviewGlobalConfiguration.get();

        String tool = orGlobal(step.getTool(), cfg == null ? null : cfg.getTool(), "claude");
        String endpointRaw = orGlobal(step.getEndpoint(), cfg == null ? null : cfg.getEndpoint(), "direct");
        EndpointMode endpoint = parseEndpoint(endpointRaw);
        Boolean sandboxParam = step.getSandbox();
        boolean sandbox = sandboxParam != null ? sandboxParam : (cfg == null || cfg.isSandbox());
        String gate = orGlobal(step.getGate(), cfg == null ? null : cfg.getGate(), "none");
        String model = orGlobal(step.getModel(), cfg == null ? null : cfg.getModel(), null);
        String reviewImage = orGlobal(
                step.getReviewImage(),
                cfg == null ? null : cfg.getReviewImage(),
                "ghcr.io/navapbc/ai-reusable-workflows/ai-pr-review:latest");

        // ── Resolve PR context ────────────────────────────────────────────────
        String prNumber = step.getPr();
        String baseRef = step.getAgainst();
        if (prNumber == null || baseRef == null) {
            PrContext discovered = PrContextResolver.resolveAll(env);
            if (discovered != null) {
                if (prNumber == null) {
                    prNumber = discovered.getNumber();
                }
                if (baseRef == null) {
                    baseRef = "origin/" + discovered.getBaseRef();
                }
            }
        }
        if (baseRef == null || baseRef.isEmpty()) {
            throw new AbortException("aiPrReview could not determine the PR base ref. Run on a multibranch PR "
                    + "build, or set the 'against' (and 'pr') parameters explicitly.");
        }
        if (step.isPostComments() && (prNumber == null || prNumber.isEmpty())) {
            throw new AbortException("aiPrReview: posting comments requires a PR number. Run on a multibranch "
                    + "PR build, or set the 'pr' parameter.");
        }

        // ── Build the engine environment ──────────────────────────────────────
        EnvVars runEnv = new EnvVars(env);
        runEnv.put("CI", "true");
        runEnv.put("NO_COLOR", "1");
        runEnv.put("AI_REVIEW_TOOL", tool);
        runEnv.put("AI_REVIEW_PROVIDER", endpoint.provider());
        putIfSet(runEnv, "AI_REVIEW_MODEL", model);

        // Credentials → env only (never argv, never logged).
        String anthropicCredId =
                orGlobal(step.getAnthropicApiKeyCredentialsId(), cfg == null ? null : cfg.getAnthropicApiKeyCredentialsId(), null);
        String openaiCredId =
                orGlobal(step.getOpenaiApiKeyCredentialsId(), cfg == null ? null : cfg.getOpenaiApiKeyCredentialsId(), null);
        String githubCredId =
                orGlobal(step.getGithubTokenCredentialsId(), cfg == null ? null : cfg.getGithubTokenCredentialsId(), null);

        if (endpoint == EndpointMode.DIRECT || endpoint == EndpointMode.CUSTOM) {
            if ("claude".equals(tool)) {
                putSecret(runEnv, "ANTHROPIC_API_KEY", anthropicCredId, run);
            } else if ("codex".equals(tool)) {
                putSecret(runEnv, "OPENAI_API_KEY", openaiCredId, run);
            }
        }
        // The GitHub token is needed for the post phase (and copilot's model auth).
        putSecret(runEnv, "GITHUB_TOKEN", githubCredId, run);
        putSecret(runEnv, "GH_TOKEN", githubCredId, run);

        // Endpoint specifics.
        if (endpoint == EndpointMode.BEDROCK) {
            putIfSet(runEnv, "AWS_REGION", orGlobal(step.getAwsRegion(), cfg == null ? null : cfg.getAwsRegion(), null));
        } else if (endpoint == EndpointMode.VERTEX) {
            putIfSet(runEnv, "ANTHROPIC_VERTEX_PROJECT_ID",
                    orGlobal(step.getVertexProjectId(), cfg == null ? null : cfg.getVertexProjectId(), null));
            putIfSet(runEnv, "CLOUD_ML_REGION",
                    orGlobal(step.getVertexRegion(), cfg == null ? null : cfg.getVertexRegion(), null));
        }
        putIfSet(runEnv, "ANTHROPIC_BASE_URL",
                orGlobal(step.getAnthropicBaseUrl(), cfg == null ? null : cfg.getAnthropicBaseUrl(), null));
        putIfSet(runEnv, "OPENAI_BASE_URL",
                orGlobal(step.getOpenaiBaseUrl(), cfg == null ? null : cfg.getOpenaiBaseUrl(), null));
        putIfSet(runEnv, "GH_HOST", ghHost(orGlobal(step.getGithubServerUrl(), cfg == null ? null : cfg.getGithubServerUrl(), null)));

        // Tuning + adjudication (all active).
        putIfSet(runEnv, "AI_ADJUDICATION",
                orGlobal(step.getAdjudication(), cfg == null ? null : cfg.getAdjudication(), null));
        putIfSet(runEnv, "AI_ADJUDICATION_MODEL",
                orGlobal(step.getAdjudicationModel(), cfg == null ? null : cfg.getAdjudicationModel(), null));
        putIfSet(runEnv, "AI_REVIEW_JOBS", step.getJobs() == null ? null : String.valueOf(step.getJobs()));
        putIfSet(runEnv, "AI_REVIEW_BATCH_BY", step.getBatchBy());
        putIfSet(runEnv, "AI_REVIEW_BATCH_MIN_FILES",
                step.getBatchMinFiles() == null ? null : String.valueOf(step.getBatchMinFiles()));
        putIfSet(runEnv, "AI_REVIEW_CONTEXT_BUDGET",
                step.getContextBudget() == null ? null : String.valueOf(step.getContextBudget()));
        putIfSet(runEnv, "AI_REVIEW_SANDBOX_IMAGE", reviewImage);
        putIfSet(runEnv, "AI_REVIEW_EXTRA_ALLOWED_HOSTS", step.getExtraAllowedHosts());

        // ── Locate the engine (bundled, or a workspace override for dev/test) ──
        FilePath engineHome;
        FilePath tmpRoot = workspace.child(".ai-pr-review@tmp");
        boolean extracted = false;
        if (step.getEngineOverridePath() != null && !step.getEngineOverridePath().isEmpty()) {
            engineHome = workspace.child(step.getEngineOverridePath());
            log.println("[aiPrReview] Using engine override at " + engineHome.getRemote());
        } else {
            engineHome = tmpRoot.child("engine");
            EngineExtractor.extract(engineHome);
            extracted = true;
            log.println("[aiPrReview] Extracted review engine " + EngineExtractor.version());
        }

        try {
            // ── Optional base-ref fetch ────────────────────────────────────────
            if (step.isFetchBase()) {
                String bareBase = baseRef.startsWith("origin/") ? baseRef.substring("origin/".length()) : baseRef;
                launcher.launch()
                        .cmds("git", "fetch", "--no-tags", "origin",
                                "+refs/heads/" + bareBase + ":refs/remotes/origin/" + bareBase)
                        .envs(runEnv)
                        .pwd(workspace)
                        .quiet(true)
                        .stdout(listener)
                        .join();
            }

            // ── Build the engine command ───────────────────────────────────────
            List<String> cmd = new ArrayList<>();
            String entry;
            if (sandbox) {
                entry = engineHome.child("lib/sandbox/sandbox.sh").getRemote();
            } else {
                entry = engineHome.child("bin/ai-pr-review").getRemote();
            }
            cmd.add("bash");
            cmd.add(entry);
            cmd.add("--against");
            cmd.add(baseRef);
            if (prNumber != null && !prNumber.isEmpty()) {
                cmd.add("--pr");
                cmd.add(prNumber);
            }
            if (step.isPostComments()) {
                cmd.add("--post-comments");
            }
            if (step.isDryRun()) {
                cmd.add("--dry-run");
            }
            // Pass --gate to the engine when the plugin's gate policy is active,
            // so a non-APPROVE result exits non-zero and applyResult() can map
            // it to UNSTABLE/FAILURE. gate=none leaves the engine advisory.
            if (!"none".equalsIgnoreCase(gate)) {
                cmd.add("--gate");
            }
            // The engine writes findings JSON here; the sandbox wrapper copies it out.
            FilePath findings = workspace.child(".ai-pr-review@tmp/findings.json");
            if (sandbox) {
                runEnv.put("AI_REVIEW_HOST_JSON_OUT", findings.getRemote());
            } else {
                cmd.add("--json-out");
                cmd.add(findings.getRemote());
            }

            log.println("[aiPrReview] Running " + (sandbox ? "sandboxed" : "direct") + " review "
                    + "(tool=" + tool + ", endpoint=" + endpoint.provider() + ", gate=" + gate + ")");

            int rc = launcher.launch()
                    .cmds(cmd)
                    .envs(runEnv)
                    .pwd(workspace)
                    .quiet(true) // env/cmdline echo suppressed; secrets are env-only regardless
                    .stdout(listener)
                    .stderr(listener.getLogger())
                    .join();

            applyResult(rc, gate, run, log);
            return null;
        } finally {
            if (extracted) {
                try {
                    tmpRoot.deleteRecursive();
                } catch (IOException | InterruptedException e) {
                    log.println("[aiPrReview] warning: could not clean up extracted engine: " + e.getMessage());
                }
            }
        }
    }

    /**
     * Map the engine exit code onto the build. The engine already applies
     * {@code --gate} semantics internally, but the plugin owns the
     * none/unstable/failure policy, so it drives the result here:
     * <ul>
     *   <li>0 → success</li>
     *   <li>2 → config error → fail the step (AbortException)</li>
     *   <li>non-zero + gate=failure → fail; gate=unstable → mark UNSTABLE;
     *       gate=none → warn only</li>
     * </ul>
     */
    private void applyResult(int rc, String gate, Run<?, ?> run, PrintStream log) throws AbortException {
        if (rc == 0) {
            return;
        }
        if (rc == 2) {
            throw new AbortException("aiPrReview: configuration error (engine exit 2). See the log above.");
        }
        switch (gate == null ? "none" : gate) {
            case "failure":
                throw new AbortException("aiPrReview: review did not pass and gate=failure (engine exit " + rc + ").");
            case "unstable":
                log.println("[aiPrReview] review did not pass; marking build UNSTABLE (gate=unstable).");
                run.setResult(Result.UNSTABLE);
                return;
            default:
                log.println("[aiPrReview] review did not pass (engine exit " + rc + "); advisory, not failing the build.");
        }
    }

    // Pass --gate to the engine only when the plugin's gate policy is not "none".
    // (The engine's own gate flag lets it short-circuit posting on failure.)

    private static EndpointMode parseEndpoint(String raw) throws AbortException {
        if (raw == null || raw.isEmpty() || "direct".equalsIgnoreCase(raw) || "api".equalsIgnoreCase(raw)) {
            return EndpointMode.DIRECT;
        }
        try {
            return EndpointMode.valueOf(raw.toUpperCase(java.util.Locale.ROOT));
        } catch (IllegalArgumentException e) {
            throw new AbortException("aiPrReview: endpoint must be direct | bedrock | vertex | custom (got '" + raw + "').");
        }
    }

    private static String orGlobal(String stepValue, String globalValue, String fallback) {
        if (stepValue != null && !stepValue.isEmpty()) {
            return stepValue;
        }
        if (globalValue != null && !globalValue.isEmpty()) {
            return globalValue;
        }
        return fallback;
    }

    private static void putIfSet(EnvVars env, String key, String value) {
        if (value != null && !value.isEmpty()) {
            env.put(key, value);
        }
    }

    private static String ghHost(String serverUrl) {
        if (serverUrl == null || serverUrl.isEmpty()) {
            return null;
        }
        // GH_HOST wants a bare hostname, not a URL.
        String host = serverUrl.replaceFirst("^https?://", "");
        int slash = host.indexOf('/');
        return slash >= 0 ? host.substring(0, slash) : host;
    }

    private void putSecret(EnvVars env, String key, String credentialsId, Run<?, ?> run) throws AbortException {
        if (credentialsId == null || credentialsId.isEmpty()) {
            return;
        }
        StringCredentials creds = CredentialsProvider.findCredentialById(
                credentialsId, StringCredentials.class, run);
        if (creds == null) {
            throw new AbortException("aiPrReview: no Secret-text credential found with id '" + credentialsId + "'.");
        }
        CredentialsProvider.track(run, creds);
        env.put(key, Secret.toString(creds.getSecret()));
    }
}
