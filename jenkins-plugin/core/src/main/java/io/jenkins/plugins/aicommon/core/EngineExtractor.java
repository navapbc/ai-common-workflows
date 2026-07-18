package io.jenkins.plugins.aicommon.core;

import hudson.FilePath;
import java.io.IOException;
import java.io.InputStream;

/**
 * Unpacks a bundled workflow engine onto the build's node.
 *
 * <p>This lives in the shared core plugin, but the engine zip itself is bundled
 * by each per-workflow plugin (see that plugin's maven-antrun step). A Jenkins
 * plugin can only read resources from plugins it depends on — not the reverse —
 * so callers must pass their own {@link ClassLoader} and resource paths;
 * loading via {@code EngineExtractor.class}'s loader (core's) would not see the
 * caller's bundled zip.
 *
 * <p>{@link FilePath#unzipFrom} runs on whatever node owns the {@code FilePath},
 * so this works for remote agents. {@code java.util.zip} does not preserve the
 * executable bit, so the shell scripts are chmod'd after extraction — and the
 * engine is invoked as {@code bash <script>} regardless, as belt and braces.
 */
public final class EngineExtractor {

    private EngineExtractor() {}

    /**
     * Extract the engine zip found at {@code zipResource} on {@code loader} into
     * {@code dest} and return the {@code entrypoint} path. {@code dest} is
     * emptied first so a stale extraction never lingers.
     *
     * @param dest       target directory on the build node
     * @param loader     the caller's classloader (the one whose plugin bundles the zip)
     * @param zipResource absolute resource path of the engine zip, e.g.
     *                    {@code /io/jenkins/plugins/aipreview/ai-review-engine.zip}
     * @param entrypoint relative path of the executable entrypoint, e.g. {@code bin/ai-pr-review}
     */
    public static FilePath extract(FilePath dest, ClassLoader loader, String zipResource, String entrypoint)
            throws IOException, InterruptedException {
        dest.deleteRecursive();
        dest.mkdirs();
        try (InputStream in = loader.getResourceAsStream(relative(zipResource))) {
            if (in == null) {
                throw new IOException("bundled engine not found on the plugin classpath: " + zipResource);
            }
            dest.unzipFrom(in);
        }
        // Ant's zip task does not preserve Unix exec bits, so restore them.
        // The entrypoint has no .sh extension, so chmod it explicitly alongside
        // the library scripts.
        for (FilePath sh : dest.list("**/*.sh")) {
            sh.chmod(0755);
        }
        FilePath entry = dest.child(entrypoint);
        if (!entry.exists()) {
            throw new IOException("extracted engine is missing " + entrypoint);
        }
        entry.chmod(0755);
        return entry;
    }

    /** The engine version stamped into the bundle at build time, or "unknown". */
    public static String version(ClassLoader loader, String versionResource) {
        try (InputStream in = loader.getResourceAsStream(relative(versionResource))) {
            if (in == null) {
                return "unknown";
            }
            return new String(in.readAllBytes(), java.nio.charset.StandardCharsets.UTF_8).trim();
        } catch (IOException e) {
            return "unknown";
        }
    }

    /**
     * {@link ClassLoader#getResourceAsStream} expects a path with no leading
     * slash, whereas {@link Class#getResourceAsStream} accepts a leading-slash
     * absolute form. Accept the absolute form callers naturally write and strip
     * the leading slash for the classloader.
     */
    private static String relative(String resource) {
        return resource.startsWith("/") ? resource.substring(1) : resource;
    }
}
