package io.jenkins.plugins.aipreview.scm;

import hudson.EnvVars;
import hudson.ExtensionList;
import hudson.ExtensionPoint;

/**
 * Resolves the pull-request context (number + base ref) for a build. The
 * GitHub implementation reads the branch-source {@code CHANGE_ID} /
 * {@code CHANGE_TARGET} env vars; other SCMs can contribute their own
 * resolver as an extension without this plugin depending on their plugins.
 */
public interface PrContextResolver extends ExtensionPoint {

    /**
     * @return a context if this resolver recognizes the build's environment,
     *     or {@code null} to defer to the next resolver.
     */
    PrContext resolve(EnvVars env);

    /** First non-null resolution across all registered resolvers. */
    static PrContext resolveAll(EnvVars env) {
        for (PrContextResolver r : ExtensionList.lookup(PrContextResolver.class)) {
            PrContext ctx = r.resolve(env);
            if (ctx != null && ctx.isComplete()) {
                return ctx;
            }
        }
        return null;
    }
}
