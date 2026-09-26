package io.jenkins.plugins.aipreview;

import static org.junit.Assert.assertEquals;
import static org.junit.Assert.assertFalse;
import static org.junit.Assert.assertTrue;

import org.jenkinsci.plugins.workflow.steps.StepConfigTester;
import org.junit.Rule;
import org.junit.Test;
import org.jvnet.hudson.test.JenkinsRule;

/** The step's parameters survive a UI/snippetizer configuration round trip. */
public class ConfigRoundTripTest {

    @Rule
    public JenkinsRule r = new JenkinsRule();

    @Test
    public void stepRoundTrips() throws Exception {
        AiPrReviewStep step = new AiPrReviewStep();
        step.setTool("claude");
        step.setEndpoint("bedrock");
        step.setModel("us.anthropic.claude-sonnet-4-5-20250929-v1:0");
        step.setAwsRegion("us-east-1");
        step.setGate("unstable");
        step.setPostComments(false);
        step.setJobs(6);
        step.setMaxComments(25);
        step.setPostWhenClean(true);
        step.setGithubTokenCredentialsId("gh-token");

        AiPrReviewStep out = new StepConfigTester(r).configRoundTrip(step);

        assertEquals("claude", out.getTool());
        assertEquals("bedrock", out.getEndpoint());
        assertEquals("us.anthropic.claude-sonnet-4-5-20250929-v1:0", out.getModel());
        assertEquals("us-east-1", out.getAwsRegion());
        assertEquals("unstable", out.getGate());
        assertFalse(out.isPostComments());
        assertEquals(Integer.valueOf(6), out.getJobs());
        assertEquals(Integer.valueOf(25), out.getMaxComments());
        assertTrue(out.isPostWhenClean());
        assertEquals("gh-token", out.getGithubTokenCredentialsId());
    }
}
