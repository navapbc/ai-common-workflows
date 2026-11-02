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
import io.jenkins.plugins.aicommon.core.EndpointMode;
import io.jenkins.plugins.aicommon.core.EngineExtractor;
import io.jenkins.plugins.aicommon.core.scm.PrContext;
import io.jenkins.plugins.aicommon.core.scm.PrContextResolver;
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
 * the engine, and map its exit code onto the build result. Non-blocking so it
 * does not tie up an executor while the AI runs.
 */
class AiPrReviewStepExecution extends SynchronousNonBlockingStepExecution<Void> {

    private static final long serialVersionUID = 1L;

    // The engine is bundled into THIS plugin's hpi (see the maven-antrun step in
    // this module's pom); the shared EngineExtractor loads it via this plugin's
    // classloader and these paths.
    private static final String ENGINE_RESOURCE = "/io/jenkins/plugins/aipreview/ai-review-engine.zip";
    private static final String VERSION_RESOURCE = "/io/jenkins/plugins/aipreview/engine-version.txt";
    private static final String ENTRYPOINT = "security-compliance-review/harness/ai-security-compliance-review";

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
        String gate = orGlobal(step.getGate(), cfg == null ? null : cfg.getGate(), "none");
        String model = orGlobal(step.getModel(), cfg == null ? null : cfg.getModel(), null);
        String profile = orGlobal(step.getProfile(), cfg == null ? null : cfg.getProfile(), null);

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
        putIfSet(runEnv, "AI_REVIEW_PROFILE", profile);

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
        } else if (endpoint == EndpointMode.AZURE) {
            // Azure OpenAI is OpenAI-compatible: the engine reads OPENAI_API_KEY
            // and the OpenAI base URL (set below) pointed at the deployment.
            putSecret(runEnv, "OPENAI_API_KEY", openaiCredId, run);
        }
        // The SCM token is deliberately NOT placed in runEnv: the AI phase reads
        // untrusted PR content, so the token that can write to the repo is kept
        // out of that process's environment (and its /proc/<pid>/environ). It
        // lives only in postEnv, used by the separate post phase below.
        // Exception: copilot's model auth *is* a GitHub token, so it must be
        // present during copilot's AI phase.
        if ("copilot".equals(tool)) {
            putSecret(runEnv, "GITHUB_TOKEN", githubCredId, run);
            putSecret(runEnv, "GH_TOKEN", githubCredId, run);
            // copilot BYOK: point the CLI at your own model endpoint (model auth
            // via the provider key, read directly by the CLI in the AI phase).
            putIfSet(runEnv, "COPILOT_PROVIDER_BASE_URL",
                    orGlobal(step.getCopilotProviderBaseUrl(), cfg == null ? null : cfg.getCopilotProviderBaseUrl(), null));
            putIfSet(runEnv, "COPILOT_PROVIDER_TYPE",
                    orGlobal(step.getCopilotProviderType(), cfg == null ? null : cfg.getCopilotProviderType(), null));
            putIfSet(runEnv, "COPILOT_MODEL",
                    orGlobal(step.getCopilotModel(), cfg == null ? null : cfg.getCopilotModel(), null));
            putSecret(runEnv, "COPILOT_PROVIDER_API_KEY",
                    orGlobal(step.getCopilotProviderApiKeyCredentialsId(),
                            cfg == null ? null : cfg.getCopilotProviderApiKeyCredentialsId(), null),
                    run);
        }

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

        // Posting shape. Read only by the post phase, but set here so the one
        // env map stays the single description of the run; neither is a secret.
        // maxComments is left unset when null so the engine default applies,
        // while postWhenClean is always explicit — a step parameter should win
        // over an AI_REVIEW_POST_WHEN_CLEAN inherited from the job environment,
        // and "false" is a value rather than an absence.
        putIfSet(runEnv, "AI_REVIEW_MAX_COMMENTS",
                step.getMaxComments() == null ? null : String.valueOf(step.getMaxComments()));
        runEnv.put("AI_REVIEW_POST_WHEN_CLEAN", String.valueOf(step.isPostWhenClean()));

        // ── Locate the engine (bundled, or a workspace override for dev/test) ──
        FilePath engineHome;
        FilePath tmpRoot = workspace.child(".ai-security-compliance-review@tmp");
        boolean extracted = false;
        if (step.getEngineOverridePath() != null && !step.getEngineOverridePath().isEmpty()) {
            engineHome = workspace.child(step.getEngineOverridePath());
            log.println("[aiPrReview] Using engine override at " + engineHome.getRemote());
        } else {
            engineHome = tmpRoot.child("engine");
            ClassLoader loader = getClass().getClassLoader();
            EngineExtractor.extract(engineHome, loader, ENGINE_RESOURCE, ENTRYPOINT);
            extracted = true;
            log.println("[aiPrReview] Extracted review engine " + EngineExtractor.version(loader, VERSION_RESOURCE));
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

            tmpRoot.mkdirs(); // holds the findings JSON handed from AI phase to post phase
            String entry = engineHome.child(ENTRYPOINT).getRemote();
            FilePath findings = tmpRoot.child("findings.json");

            // ── AI phase: review with no SCM token in scope, write findings ────
            log.println("[aiPrReview] Running review "
                    + "(tool=" + tool + ", endpoint=" + endpoint.provider() + ", gate=" + gate + ")");
            List<String> aiCmd = new ArrayList<>();
            aiCmd.add("bash");
            aiCmd.add(entry);
            aiCmd.add("--against");
            aiCmd.add(baseRef);
            aiCmd.add("--json-out");
            aiCmd.add(findings.getRemote());
            if (step.isDryRun()) {
                aiCmd.add("--dry-run");
            }
            int aiRc = launcher.launch()
                    .cmds(aiCmd)
                    .envs(runEnv)
                    .pwd(workspace)
                    .quiet(true) // secrets are env-only regardless
                    .stdout(listener)
                    .stderr(listener.getLogger())
                    .join();
            if (aiRc == 2) {
                throw new AbortException("aiPrReview: configuration error (engine exit 2). See the log above.");
            }
            if (aiRc != 0) {
                throw new AbortException("aiPrReview: the review phase failed (engine exit " + aiRc + ").");
            }
            if (step.isDryRun()) {
                return null;
            }

            // ── Post phase: the only launch that holds the SCM token ───────────
            if (step.isPostComments()) {
                EnvVars postEnv = new EnvVars(runEnv);
                putSecret(postEnv, "GITHUB_TOKEN", githubCredId, run);
                putSecret(postEnv, "GH_TOKEN", githubCredId, run);
                int postRc = launcher.launch()
                        .cmds("bash", entry, "--post-only", "--pr", prNumber,
                                "--json-in", findings.getRemote())
                        .envs(postEnv)
                        .pwd(workspace)
                        .quiet(true)
                        .stdout(listener)
                        .stderr(listener.getLogger())
                        .join();
                if (postRc != 0) {
                    throw new AbortException("aiPrReview: posting the review failed (engine exit " + postRc + ").");
                }
            }

            // ── Result + gate (derived from the findings JSON) ─────────────────
            applyResult(readReviewAction(findings), gate, run, log);
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
     * Read the {@code review_action} verdict from the engine's findings JSON.
     *
     * <p>This is a safety-critical read: the verdict drives the gate, so it
     * must never fail open. A findings file that exists but cannot be parsed
     * (truncated write, engine malfunction) aborts the step rather than
     * reporting APPROVE. Only a genuinely absent file — the engine exits 0
     * without writing when the diff is empty — counts as APPROVE, matching
     * what {@code ci::gate_result} reports on the GitHub Actions side.
     *
     * <p>Parsed as JSON rather than regex-matched: a regex would take the
     * first {@code "review_action"} occurrence anywhere in the document,
     * including inside a finding's own description text.
     */
    private String readReviewAction(FilePath findings) throws IOException, InterruptedException, AbortException {
        if (!findings.exists()) {
            return "APPROVE"; // no diff to review → nothing to gate on
        }
        String raw = findings.readToString();
        String action;
        try {
            action = net.sf.json.JSONObject.fromObject(raw).optString("review_action", null);
        } catch (RuntimeException e) {
            throw new AbortException("aiPrReview: the findings JSON at " + findings.getRemote()
                    + " is not parseable (" + e.getMessage() + "). Refusing to assume APPROVE.");
        }
        if (action == null || action.isEmpty()) {
            throw new AbortException("aiPrReview: the findings JSON at " + findings.getRemote()
                    + " has no 'review_action'. Refusing to assume APPROVE.");
        }
        if (!"APPROVE".equals(action) && !"COMMENT".equals(action) && !"REQUEST_CHANGES".equals(action)) {
            throw new AbortException("aiPrReview: unrecognized review_action '" + action
                    + "' in the findings JSON. Refusing to assume APPROVE.");
        }
        return action;
    }

    /**
     * Map the review verdict onto the build, per the plugin's gate policy:
     * <ul>
     *   <li>APPROVE → success</li>
     *   <li>otherwise: gate=failure → fail (AbortException); gate=unstable →
     *       mark UNSTABLE; gate=none → advisory, log only</li>
     * </ul>
     */
    private void applyResult(String result, String gate, Run<?, ?> run, PrintStream log) throws AbortException {
        log.println("[aiPrReview] result: " + result);
        if ("APPROVE".equals(result)) {
            return;
        }
        switch (gate == null ? "none" : gate) {
            case "failure":
                throw new AbortException("aiPrReview: review result is " + result + " and gate=failure.");
            case "unstable":
                log.println("[aiPrReview] result is " + result + "; marking build UNSTABLE (gate=unstable).");
                run.setResult(Result.UNSTABLE);
                return;
            default:
                log.println("[aiPrReview] result is " + result + "; advisory, not failing the build.");
        }
    }

    private static EndpointMode parseEndpoint(String raw) throws AbortException {
        if (raw == null || raw.isEmpty() || "direct".equalsIgnoreCase(raw) || "api".equalsIgnoreCase(raw)) {
            return EndpointMode.DIRECT;
        }
        try {
            return EndpointMode.valueOf(raw.toUpperCase(java.util.Locale.ROOT));
        } catch (IllegalArgumentException e) {
            throw new AbortException(
                    "aiPrReview: endpoint must be direct | bedrock | vertex | azure | custom (got '" + raw + "').");
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
