package io.jenkins.plugins.aipreview;

import static org.junit.Assert.assertTrue;

import hudson.FilePath;
import java.io.File;
import org.junit.Rule;
import org.junit.Test;
import org.junit.rules.TemporaryFolder;

/** The bundled engine zip unpacks with its entrypoint present and executable. */
public class EngineExtractorTest {

    @Rule
    public TemporaryFolder tmp = new TemporaryFolder();

    @Test
    public void extractsEntrypointAndLib() throws Exception {
        FilePath dest = new FilePath(new File(tmp.getRoot(), "engine"));
        FilePath entry = EngineExtractor.extract(dest);

        assertTrue("entrypoint exists", entry.exists());
        assertTrue("entrypoint is executable", (entry.mode() & 0100) != 0);
        assertTrue("core lib present", dest.child("lib/core.sh").exists());
        assertTrue("sandbox present", dest.child("lib/sandbox/sandbox.sh").exists());
        assertTrue("skills present", dest.child("skills/pr-review.md").exists());
    }
}
