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
 * Drives the {@code aiPrReview} step against a stub engine (via
 * {@code engineOverridePath}) to verify env injection, credential handling,
 * and gate mapping — no AI CLI, no Docker. The stub records args/env to a log
 * file outside the workspace so the test can assert on it after the build.
 */
public class StepExecutionSmokeTest {

    @Rule
    public JenkinsRule r = new JenkinsRule();

    @Rule
    public TemporaryFolder tmp = new TemporaryFolder();

    /** A tiny stand-in for the engine: append args + review env to STUB_ENGINE_LOG. */
    private static final String STUB_ENGINE =
            "#!/usr/bin/env bash\\n"
                    + "set -euo pipefail\\n"
                    + "{ echo \\\"ARGS: $*\\\"; "
                    + "echo \\\"AI_REVIEW_TOOL=${AI_REVIEW_TOOL:-}\\\"; "
                    + "echo \\\"AI_REVIEW_PROVIDER=${AI_REVIEW_PROVIDER:-}\\\"; "
                    + "echo \\\"ANTHROPIC_API_KEY=${ANTHROPIC_API_KEY:-}\\\"; "
                    + "echo \\\"AWS_REGION=${AWS_REGION:-}\\\"; } >> \\\"${STUB_ENGINE_LOG}\\\"\\n"
                    + "exit ${STUB_ENGINE_EXIT:-0}\\n";

    /**
     * Pipeline that materializes the stub engine into the workspace (as both
     * the direct and sandbox entrypoints) and runs the step with the given
     * extra env entries and step parameters.
     */
    private String pipeline(Path log, String extraEnv, String stepParams) {
        String envList = "'STUB_ENGINE_LOG=" + log.toString().replace("\\", "/") + "', "
                + "'CHANGE_ID=7', 'CHANGE_TARGET=main'"
                + (extraEnv.isEmpty() ? "" : ", " + extraEnv);
        return ""
                + "node {\n"
                + "  writeFile file: 'engine/bin/ai-pr-review', text: \"" + STUB_ENGINE + "\"\n"
                + "  writeFile file: 'engine/lib/sandbox/sandbox.sh', text: \"" + STUB_ENGINE + "\"\n"
                + "  sh 'chmod +x engine/bin/ai-pr-review engine/lib/sandbox/sandbox.sh'\n"
                + "  withEnv([" + envList + "]) {\n"
                + "    aiPrReview(engineOverridePath: 'engine', fetchBase: false, postComments: false, " + stepParams + ")\n"
                + "  }\n"
                + "}\n";
    }

    @Test
    public void injectsEnvAndCredentialsDirectMode() throws Exception {
        SystemCredentialsProvider.getInstance()
                .getCredentials()
                .add(new StringCredentialsImpl(
                        CredentialsScope.GLOBAL, "anthropic", "", Secret.fromString("sk-secret-value")));
        SystemCredentialsProvider.getInstance().save();

        Path log = tmp.newFile("direct.log").toPath();
        WorkflowJob job = r.createProject(WorkflowJob.class, "direct");
        job.setDefinition(new CpsFlowDefinition(
                pipeline(log, "", "sandbox: false, tool: 'claude', anthropicApiKeyCredentialsId: 'anthropic'"),
                true));

        var run = r.buildAndAssertSuccess(job);

        String logged = Files.readString(log);
        assertTrue("tool passed via env", logged.contains("AI_REVIEW_TOOL=claude"));
        assertTrue("api key injected via env", logged.contains("ANTHROPIC_API_KEY=sk-secret-value"));
        assertTrue("engine ran against origin/main", logged.contains("--against origin/main"));
        r.assertLogNotContains("sk-secret-value", run);
    }

    @Test
    public void gateFailureMapsToBuildFailure() throws Exception {
        Path log = tmp.newFile("failure.log").toPath();
        WorkflowJob job = r.createProject(WorkflowJob.class, "gate-failure");
        job.setDefinition(new CpsFlowDefinition(
                pipeline(log, "'STUB_ENGINE_EXIT=1'", "sandbox: false, tool: 'claude', gate: 'failure'"),
                true));
        r.buildAndAssertStatus(Result.FAILURE, job);
    }

    @Test
    public void gateUnstableMarksUnstable() throws Exception {
        Path log = tmp.newFile("unstable.log").toPath();
        WorkflowJob job = r.createProject(WorkflowJob.class, "gate-unstable");
        job.setDefinition(new CpsFlowDefinition(
                pipeline(log, "'STUB_ENGINE_EXIT=1'", "sandbox: false, tool: 'claude', gate: 'unstable'"),
                true));
        r.buildAndAssertStatus(Result.UNSTABLE, job);
    }

    @Test
    public void gateNoneStaysSuccessDespiteFindings() throws Exception {
        Path log = tmp.newFile("none.log").toPath();
        WorkflowJob job = r.createProject(WorkflowJob.class, "gate-none");
        job.setDefinition(new CpsFlowDefinition(
                pipeline(log, "", "sandbox: false, tool: 'claude', gate: 'none'"),
                true));
        r.buildAndAssertSuccess(job);
        assertFalse("no --gate passed when gate=none", Files.readString(log).contains("--gate"));
    }
}
