package io.jenkins.plugins.aicommon.core.scm;

import hudson.EnvVars;
import hudson.Extension;

/**
 * Resolves PR context from the generic GitHub branch-source environment
 * variables {@code CHANGE_ID} (PR number) and {@code CHANGE_TARGET} (base
 * branch), which the GitHub Branch Source plugin sets on multibranch PR
 * builds. Reading the env vars rather than the plugin's API avoids a hard
 * dependency on github-branch-source.
 */
@Extension
public class GitHubPrContextResolver implements PrContextResolver {

    @Override
    public PrContext resolve(EnvVars env) {
        if (env == null) {
            return null;
        }
        String number = env.get("CHANGE_ID");
        String base = env.get("CHANGE_TARGET");
        if (number == null || number.isEmpty() || base == null || base.isEmpty()) {
            return null;
        }
        return new PrContext(number, base);
    }
}
