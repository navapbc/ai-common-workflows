package io.jenkins.plugins.aicommon.core;

import static org.junit.Assert.assertTrue;

import hudson.FilePath;
import java.io.File;
import org.junit.Rule;
import org.junit.Test;
import org.junit.rules.TemporaryFolder;

/**
 * The engine zip unpacks with its entrypoint present and executable. The zip
 * fixture is produced at build time by this module's maven-antrun step (it zips
 * the repo's real {@code ../../engines/_common} + workflow engine into
 * {@code target/test-classes}), so the assertions below exercise the actual
 * engines layout via the generalized, classloader-parameterized extractor.
 */
public class EngineExtractorTest {

    private static final String TEST_ENGINE_ZIP = "/io/jenkins/plugins/aicommon/core/test-engine.zip";

    @Rule
    public TemporaryFolder tmp = new TemporaryFolder();

    @Test
    public void extractsEntrypointAndLib() throws Exception {
        FilePath dest = new FilePath(new File(tmp.getRoot(), "engine"));
        FilePath entry = EngineExtractor.extract(
                dest, getClass().getClassLoader(), TEST_ENGINE_ZIP, "security-compliance-review/harness/ai-security-compliance-review");

        assertTrue("entrypoint exists", entry.exists());
        assertTrue("entrypoint is executable", (entry.mode() & 0100) != 0);
        assertTrue("shared runtime present", dest.child("_common/harness/core.sh").exists());
        assertTrue("endpoints present", dest.child("_common/endpoints.sh").exists());
        assertTrue("skills present",
                dest.child("security-compliance-review/skills/base/pr-review.md").exists());
    }
}
