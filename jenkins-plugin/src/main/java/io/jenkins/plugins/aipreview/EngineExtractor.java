package io.jenkins.plugins.aipreview;

import hudson.FilePath;
import java.io.IOException;
import java.io.InputStream;

/**
 * Unpacks the bundled review engine onto the build's node.
 *
 * <p>The engine is zipped into the plugin jar at build time (see the
 * maven-antrun bundling step in the pom). {@link FilePath#unzipFrom} runs on
 * whatever node owns the {@code FilePath}, so this works for remote agents.
 * {@code java.util.zip} does not preserve the executable bit, so the shell
 * scripts are chmod'd after extraction — and the engine is invoked as
 * {@code bash <script>} regardless, as belt and braces.
 */
final class EngineExtractor {

    static final String ENGINE_RESOURCE = "/io/jenkins/plugins/aipreview/ai-review-engine.zip";
    static final String VERSION_RESOURCE = "/io/jenkins/plugins/aipreview/engine-version.txt";

    private EngineExtractor() {}

    /**
     * Extract the bundled engine into {@code dest} and return the entrypoint
     * path. {@code dest} is emptied first so a stale extraction never lingers.
     */
    static FilePath extract(FilePath dest) throws IOException, InterruptedException {
        dest.deleteRecursive();
        dest.mkdirs();
        try (InputStream in = EngineExtractor.class.getResourceAsStream(ENGINE_RESOURCE)) {
            if (in == null) {
                throw new IOException("bundled engine not found on the plugin classpath: " + ENGINE_RESOURCE);
            }
            dest.unzipFrom(in);
        }
        // Ant's zip task does not preserve Unix exec bits, so restore them.
        // The entrypoint has no .sh extension, so chmod it explicitly alongside
        // the library scripts.
        for (FilePath sh : dest.list("**/*.sh")) {
            sh.chmod(0755);
        }
        FilePath entry = dest.child("bin/ai-pr-review");
        if (!entry.exists()) {
            throw new IOException("extracted engine is missing bin/ai-pr-review");
        }
        entry.chmod(0755);
        return entry;
    }

    /** The engine version stamped into the bundle at build time, or "unknown". */
    static String version() {
        try (InputStream in = EngineExtractor.class.getResourceAsStream(VERSION_RESOURCE)) {
            if (in == null) {
                return "unknown";
            }
            return new String(in.readAllBytes(), java.nio.charset.StandardCharsets.UTF_8).trim();
        } catch (IOException e) {
            return "unknown";
        }
    }
}
