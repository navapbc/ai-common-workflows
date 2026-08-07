package io.jenkins.plugins.aipreview;

import static org.junit.Assert.assertFalse;
import static org.junit.Assert.assertTrue;

import com.cloudbees.plugins.credentials.CredentialsScope;
import com.cloudbees.plugins.credentials.SystemCredentialsProvider;
import hudson.model.Result;
import hudson.util.Secret;
import java.nio.file.Files;
import java.nio.file.Path;
import org.jenkinsci.plugins.plaincredentials.impl.StringCredentialsImpl;
import org.jenkinsci.plugins.workflow.cps.CpsFlowDefinition;
import org.jenkinsci.plugins.workflow.job.WorkflowJob;
import org.junit.Rule;
import org.junit.Test;
import org.junit.rules.TemporaryFolder;
import org.jvnet.hudson.test.JenkinsRule;

/**
 * Drives the {@code aiSecurityComplianceReview} step against a stub engine (via
 * {@code engineOverridePath}) to verify env injection, the token-free AI phase
 * / token-holding post phase split, and gate mapping — no AI CLI, no Docker.
 * The stub records args/env to a log file outside the workspace and writes a
 * findings JSON (with a configurable {@code review_action}) so the plugin's
 * result/gate logic runs against it.
 */
public class StepExecutionSmokeTest {

    @Rule
    public JenkinsRule r = new JenkinsRule();

    @Rule
    public TemporaryFolder tmp = new TemporaryFolder();

    /**
     * Stand-in for the engine. Records args + review env to STUB_ENGINE_LOG;
     * on the AI phase (--json-out) writes {"review_action": STUB_RESULT}; on
     * --post-only just records. Embedded in a Groovy triple-single-quoted
     * string so bash {@code ${...}} isn't interpolated by Groovy.
     */
    private static final String STUB_ENGINE =
            """
            #!/usr/bin/env bash
            set -euo pipefail
            json_out=""; prev=""
            for a in "$@"; do
              [ "$prev" = "--json-out" ] && json_out="$a"
              prev="$a"
            done
            { echo "ARGS: $*"; \
              echo "AI_REVIEW_TOOL=${AI_REVIEW_TOOL:-}"; \
              echo "ANTHROPIC_API_KEY=${ANTHROPIC_API_KEY:-}"; \
              echo "GITHUB_TOKEN=${GITHUB_TOKEN:-}"; } >> "${STUB_ENGINE_LOG}"
            if [ -n "$json_out" ]; then
              printf '{"review_action":"%s","summary":"s","comments":[]}\\n' "${STUB_RESULT:-APPROVE}" > "$json_out"
            fi
            exit ${STUB_ENGINE_EXIT:-0}
            """;

    private void addSecret(String id, String value) throws Exception {
        SystemCredentialsProvider.getInstance()
                .getCredentials()
                .add(new StringCredentialsImpl(CredentialsScope.GLOBAL, id, "", Secret.fromString(value)));
        SystemCredentialsProvider.getInstance().save();
    }

    /** Pipeline that materializes the stub engine and runs the step. */
    private String pipeline(Path log, String extraEnv, String stepParams) {
        String envList = "'STUB_ENGINE_LOG=" + log.toString().replace("\\", "/") + "', "
                + "'CHANGE_ID=7', 'CHANGE_TARGET=main'"
                + (extraEnv.isEmpty() ? "" : ", " + extraEnv);
        String stub = "'''" + STUB_ENGINE + "'''";
        return ""
                + "node {\n"
                + "  writeFile file: 'engine/security-compliance-review/harness/ai-pr-review', text: " + stub + "\n"
                + "  sh 'chmod +x engine/security-compliance-review/harness/ai-pr-review'\n"
                + "  withEnv([" + envList + "]) {\n"
                + "    aiSecurityComplianceReview(engineOverridePath: 'engine', fetchBase: false, " + stepParams + ")\n"
                + "  }\n"
                + "}\n";
    }

    @Test
    public void aiPhaseRunsWithoutScmToken() throws Exception {
        addSecret("anthropic", "sk-secret-value");
        addSecret("ghtok", "gh-secret-token");

        Path log = tmp.newFile("ai.log").toPath();
        WorkflowJob job = r.createProject(WorkflowJob.class, "ai-phase");
        // post-comments false → only the AI phase runs.
        job.setDefinition(new CpsFlowDefinition(
                pipeline(log, "",
                        "tool: 'claude', postComments: false, "
                                + "anthropicApiKeyCredentialsId: 'anthropic', githubTokenCredentialsId: 'ghtok'"),
                true));

        var run = r.buildAndAssertSuccess(job);

        String logged = Files.readString(log);
        assertTrue("AI phase gets the LLM key", logged.contains("ANTHROPIC_API_KEY=sk-secret-value"));
        assertFalse("AI phase must NOT see the SCM token", logged.contains("gh-secret-token"));
        r.assertLogNotContains("gh-secret-token", run);
    }

    @Test
    public void postPhaseReceivesScmToken() throws Exception {
        addSecret("anthropic", "sk-secret-value");
        addSecret("ghtok", "gh-secret-token");

        Path log = tmp.newFile("post.log").toPath();
        WorkflowJob job = r.createProject(WorkflowJob.class, "post-phase");
        // post-comments true → AI phase then post phase; only the post phase
        // may carry the token.
        job.setDefinition(new CpsFlowDefinition(
                pipeline(log, "",
                        "tool: 'claude', postComments: true, pr: '7', "
                                + "anthropicApiKeyCredentialsId: 'anthropic', githubTokenCredentialsId: 'ghtok'"),
                true));

        r.buildAndAssertSuccess(job);

        String logged = Files.readString(log);
        // Two engine invocations (AI + post); the token appears (post phase).
        assertTrue("stub invoked twice", logged.split("ARGS:", -1).length - 1 == 2);
        assertTrue("post phase carries the SCM token", logged.contains("gh-secret-token"));
        assertTrue("post phase uses --post-only", logged.contains("--post-only"));
    }

    @Test
    public void copilotAiPhaseGetsTokenAsModelAuth() throws Exception {
        addSecret("ghtok", "gh-secret-token");

        Path log = tmp.newFile("copilot.log").toPath();
        WorkflowJob job = r.createProject(WorkflowJob.class, "copilot");
        // Copilot's model auth is a GitHub token, so it (uniquely) must be in
        // the AI phase even with posting off.
        job.setDefinition(new CpsFlowDefinition(
                pipeline(log, "", "tool: 'copilot', postComments: false, githubTokenCredentialsId: 'ghtok'"),
                true));

        r.buildAndAssertSuccess(job);
        assertTrue("copilot AI phase carries the token", Files.readString(log).contains("gh-secret-token"));
    }

    @Test
    public void gateFailureMapsToBuildFailure() throws Exception {
        Path log = tmp.newFile("failure.log").toPath();
        WorkflowJob job = r.createProject(WorkflowJob.class, "gate-failure");
        job.setDefinition(new CpsFlowDefinition(
                pipeline(log, "'STUB_RESULT=COMMENT'", "tool: 'claude', postComments: false, gate: 'failure'"),
                true));
        r.buildAndAssertStatus(Result.FAILURE, job);
    }

    @Test
    public void gateUnstableMarksUnstable() throws Exception {
        Path log = tmp.newFile("unstable.log").toPath();
        WorkflowJob job = r.createProject(WorkflowJob.class, "gate-unstable");
        job.setDefinition(new CpsFlowDefinition(
                pipeline(log, "'STUB_RESULT=COMMENT'", "tool: 'claude', postComments: false, gate: 'unstable'"),
                true));
        r.buildAndAssertStatus(Result.UNSTABLE, job);
    }

    @Test
    public void gateNoneStaysSuccessDespiteFindings() throws Exception {
        Path log = tmp.newFile("none.log").toPath();
        WorkflowJob job = r.createProject(WorkflowJob.class, "gate-none");
        job.setDefinition(new CpsFlowDefinition(
                pipeline(log, "'STUB_RESULT=COMMENT'", "tool: 'claude', postComments: false, gate: 'none'"),
                true));
        r.buildAndAssertSuccess(job);
    }

    @Test
    public void configErrorFailsTheStep() throws Exception {
        Path log = tmp.newFile("config.log").toPath();
        WorkflowJob job = r.createProject(WorkflowJob.class, "config-error");
        // Engine exit 2 = configuration error → the step fails regardless of gate.
        job.setDefinition(new CpsFlowDefinition(
                pipeline(log, "'STUB_ENGINE_EXIT=2'", "tool: 'claude', postComments: false, gate: 'none'"),
                true));
        r.buildAndAssertStatus(Result.FAILURE, job);
    }
}
