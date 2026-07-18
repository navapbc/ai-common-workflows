package io.jenkins.plugins.aipreview;

import static org.junit.Assert.assertEquals;
import static org.junit.Assert.assertFalse;

import org.junit.Rule;
import org.junit.Test;
import org.jvnet.hudson.test.JenkinsRule;

/** Global defaults persist across a configuration round trip. */
public class GlobalConfigurationTest {

    @Rule
    public JenkinsRule r = new JenkinsRule();

    @Test
    public void globalConfigRoundTrips() throws Exception {
        AiPrReviewGlobalConfiguration cfg = AiPrReviewGlobalConfiguration.get();
        cfg.setTool("codex");
        cfg.setEndpoint("bedrock");
        cfg.setAwsRegion("us-west-2");
        cfg.setSandbox(false);
        cfg.setGithubTokenCredentialsId("gh-default");

        r.configRoundtrip();

        AiPrReviewGlobalConfiguration reloaded = AiPrReviewGlobalConfiguration.get();
        assertEquals("codex", reloaded.getTool());
        assertEquals("bedrock", reloaded.getEndpoint());
        assertEquals("us-west-2", reloaded.getAwsRegion());
        assertFalse(reloaded.isSandbox());
        assertEquals("gh-default", reloaded.getGithubTokenCredentialsId());
    }
}
