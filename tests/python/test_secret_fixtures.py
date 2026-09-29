"""Credential-shaped literals stay inside the paths secret scanning ignores.

`.github/secret_scanning.yml` silences alerts for the detection corpus and the
test fixtures, because this repository is a security reviewer and those paths
exist to contain things that look like leaked secrets. An exclusion without a
compensating control is just a blind spot, so this is the control:

  1. A credential-shaped literal appearing ANYWHERE outside those paths fails —
     including in code that ships to consumers, where scanning is still on but
     a reviewer might reasonably assume "the repo is full of fake keys" and
     wave it through.
  2. A path listed in the exclusion that no longer holds such a literal fails,
     so the exclusion cannot quietly widen past what the fixtures need.

Patterns with no legitimate fixture use — Anthropic keys, GitHub tokens,
private keys — are refused everywhere, excluded paths included. Nothing in
this repo needs a real-shaped one of those, and the corpus does not currently
test for them.
"""

import fnmatch
import pathlib
import re
import subprocess

import pytest
import yaml

ROOT = pathlib.Path(__file__).resolve().parents[2]
CONFIG = ROOT / ".github" / "secret_scanning.yml"

# Shapes a fixture legitimately needs: an AWS access key id is the only one the
# corpus asserts on today.
FIXTURE_SHAPES = {
    "aws-access-key-id": re.compile(r"AKIA[0-9A-Z]{16}"),
}

# Shapes nothing here should ever contain, fixture or not.
FORBIDDEN_EVERYWHERE = {
    "anthropic-api-key": re.compile(r"sk-ant-[A-Za-z0-9_\-]{20,}"),
    "github-pat-classic": re.compile(r"ghp_[A-Za-z0-9]{36}"),
    "github-pat-fine-grained": re.compile(r"github_pat_[A-Za-z0-9_]{50,}"),
    "openai-api-key": re.compile(r"sk-[A-Za-z0-9]{32,}"),
    "private-key-block": re.compile(r"-----BEGIN [A-Z ]*PRIVATE KEY-----"),
}

# Prose may name AWS's published documentation key without being a fixture —
# the rubric and changelog discuss it by name. Those are Markdown, where a
# literal cannot be mistaken for configuration.
PROSE_SUFFIXES = {".md"}


def _tracked():
    """Files git knows about, including ones staged for the first time.

    `git ls-files` alone misses a file added in the very commit that
    introduces it, which is exactly when a pasted credential would arrive.
    `--cached --others --exclude-standard` covers tracked, staged and
    not-yet-ignored new files.
    """
    out = subprocess.run(
        ["git", "ls-files", "--cached", "--others", "--exclude-standard"],
        cwd=ROOT, capture_output=True, text=True, check=True,
    ).stdout.split()
    return sorted({ROOT / p for p in out if (ROOT / p).is_file()})


def _excluded_globs():
    return yaml.safe_load(CONFIG.read_text())["paths-ignore"]


def _is_excluded(rel, globs):
    return any(fnmatch.fnmatch(rel, g) or rel.startswith(g.rstrip("*").rstrip("/") + "/")
               for g in globs)


def _text(path):
    try:
        return path.read_text(encoding="utf-8")
    except (UnicodeDecodeError, OSError):
        return ""


TRACKED = _tracked()


def test_the_config_exists_and_lists_paths():
    # A missing or empty config would make every assertion below vacuous.
    assert CONFIG.is_file(), CONFIG
    globs = _excluded_globs()
    assert globs, "paths-ignore is empty"
    assert len(TRACKED) >= 50, len(TRACKED)


def test_fixture_shapes_stay_inside_the_excluded_paths():
    """The main control.

    A fake AWS key in engines/ or workflows/ would ship to consumers, and the
    excluded paths make it easy to assume any key in this repo is a fixture.
    """
    globs = _excluded_globs()
    offenders = []
    for p in TRACKED:
        rel = str(p.relative_to(ROOT))
        if _is_excluded(rel, globs) or p.suffix in PROSE_SUFFIXES:
            continue
        body = _text(p)
        for name, rx in FIXTURE_SHAPES.items():
            if rx.search(body):
                offenders.append(f"{rel} ({name})")
    assert not offenders, (
        "credential-shaped literal outside the secret-scanning exclusion: "
        f"{offenders}. Move the fixture under an excluded path, or if it is "
        "real, rotate it."
    )


def test_every_excluded_path_still_needs_excluding():
    """Stops the exclusion widening past what the fixtures justify.

    A glob kept after its fixtures move becomes a silent blind spot over a tree
    that no longer has a reason to be exempt.
    """
    globs = _excluded_globs()
    unjustified = []
    for g in globs:
        hits = [
            p for p in TRACKED
            if _is_excluded(str(p.relative_to(ROOT)), [g])
            and p.suffix not in PROSE_SUFFIXES
            and any(rx.search(_text(p)) for rx in FIXTURE_SHAPES.values())
        ]
        if not hits:
            unjustified.append(g)
    assert not unjustified, (
        f"excluded path(s) with no credential-shaped fixture left: {unjustified}. "
        "Drop them from .github/secret_scanning.yml rather than leaving a blind spot."
    )


@pytest.mark.parametrize("name", sorted(FORBIDDEN_EVERYWHERE))
def test_no_real_token_shapes_anywhere(name):
    """Refused even inside the excluded paths.

    Nothing here needs an Anthropic key, a GitHub PAT or a private key of any
    shape, so a match is a leak rather than a fixture — and the exclusion must
    not become the place one hides.
    """
    rx = FORBIDDEN_EVERYWHERE[name]
    hits = [str(p.relative_to(ROOT)) for p in TRACKED if rx.search(_text(p))]
    assert not hits, f"{name} shape found in: {hits}"
