package io.jenkins.plugins.aipreview;

import static org.junit.Assert.assertEquals;
import static org.junit.Assert.assertFalse;

import org.junit.Rule;
import org.junit.Test;
import org.jvnet.hudson.test.JenkinsRule;
import org.jvnet.hudson.test.SnippetizerTester;

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
        step.setSandbox(Boolean.TRUE);
        step.setPostComments(false);
        step.setJobs(6);
        step.setGithubTokenCredentialsId("gh-token");

        AiPrReviewStep out = new SnippetizerTester(r).configRoundTrip(step);

        assertEquals("claude", out.getTool());
        assertEquals("bedrock", out.getEndpoint());
        assertEquals("us.anthropic.claude-sonnet-4-5-20250929-v1:0", out.getModel());
        assertEquals("us-east-1", out.getAwsRegion());
        assertEquals("unstable", out.getGate());
        assertEquals(Boolean.TRUE, out.getSandbox());
        assertFalse(out.isPostComments());
        assertEquals(Integer.valueOf(6), out.getJobs());
        assertEquals("gh-token", out.getGithubTokenCredentialsId());
    }
}
