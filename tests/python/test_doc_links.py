"""Every relative link and anchor in the docs resolves.

Written after a broken one shipped: `security.md#the-llm-credential-bedrock--vertex`
lost its target when "Azure" was added to that heading, and nothing noticed —
a heading edit silently breaks every link pointing at it, in files the editor
never opened.

The check is worth having as a test rather than a script for a second reason.
My first ad-hoc version reported a *correct* link as broken, because it
collapsed runs of whitespace while GitHub maps each space to its own hyphen
(`Bedrock / Vertex / Azure` -> `bedrock--vertex--azure`). I nearly "fixed" a
working link on a bad tool's say-so. A slug implementation that is subtly wrong
is worse than no checker at all, so the slug rules are pinned by their own
tests below.
"""

import pathlib
import re
import subprocess

import pytest

ROOT = pathlib.Path(__file__).resolve().parents[2]


def _tracked_markdown():
    """Prefer git's view, so generated or ignored markdown is not scanned.

    Falls back to a walk when git is unavailable (a tarball, a sandbox without
    git) rather than erroring at import time — a collection error would read as
    "the doc tests are broken" instead of "git is missing". The
    at-least-20-files guard below still applies, so a degraded scan cannot pass
    vacuously.
    """
    try:
        out = subprocess.run(
            ["git", "ls-files", "*.md"], cwd=ROOT,
            capture_output=True, text=True, check=True,
        ).stdout.split()
        if out:
            return [ROOT / p for p in out]
    except (OSError, subprocess.CalledProcessError):
        pass
    return [
        p for p in ROOT.rglob("*.md")
        if ".git" not in p.parts and "node_modules" not in p.parts
    ]


MARKDOWN = _tracked_markdown()

# Inline code, images and bold/italic markers are stripped before slugging, the
# way a renderer sees the heading text rather than its source.
_CODE = re.compile(r"`([^`]*)`")
_LINK = re.compile(r"\[([^\]]*)\]\([^)]*\)")
# Asterisks only. Underscores are word characters that survive slugging, and
# every underscore in this repo's headings is part of an identifier
# (`COPILOT_SYNC_TOKEN`), not emphasis — GFM disables intraword `_` emphasis
# anyway. Stripping them turned a correct link into a reported failure.
_EMPHASIS = re.compile(r"\*{1,3}")
# github-slugger removes punctuation and keeps word characters, spaces and
# hyphens. Crucially it does NOT collapse runs: each remaining space becomes
# one hyphen, so "a / b" -> "a--b".
_STRIP = re.compile(r"[^\w\s-]", re.UNICODE)
_HEADING = re.compile(r"^(#{1,6})\s+(.*?)\s*#*$")
_FENCE = re.compile(r"^\s*(```|~~~)")


def slugify(text):
    """GitHub's heading slug, matching github-slugger for the cases we use."""
    text = _CODE.sub(r"\1", text)
    text = _LINK.sub(r"\1", text)
    text = _EMPHASIS.sub("", text)
    text = _STRIP.sub("", text.strip().lower())
    return text.replace(" ", "-")


def anchors(path):
    """Every anchor a link can target in this file, with duplicate suffixes.

    Headings inside fenced code blocks are not headings — CHANGELOG and the
    setup docs both contain fenced YAML and shell with '#' comments.
    """
    seen, out, in_fence = {}, set(), False
    for line in pathlib.Path(path).read_text().splitlines():
        if _FENCE.match(line):
            in_fence = not in_fence
            continue
        if in_fence:
            continue
        m = _HEADING.match(line)
        if not m:
            continue
        base = slugify(m.group(2))
        if not base:
            continue
        n = seen.get(base, 0)
        seen[base] = n + 1
        out.add(base if n == 0 else f"{base}-{n}")
    return out


# Links worth checking: relative targets, with or without an anchor, plus
# same-file anchors. External schemes are somebody else's uptime problem.
_MDLINK = re.compile(r"\[[^\]]*\]\(\s*([^)\s]+?)\s*\)")
_SKIP_SCHEME = re.compile(r"^(https?:|mailto:|#!|data:)", re.I)


def _links(path):
    text = pathlib.Path(path).read_text()
    # Strip fenced blocks: an example workflow may reference a path that does
    # not exist in this repo, and that is not a broken doc link.
    lines, out, in_fence = text.splitlines(), [], False
    for line in lines:
        if _FENCE.match(line):
            in_fence = not in_fence
            continue
        if not in_fence:
            out.append(line)
    for m in _MDLINK.finditer("\n".join(out)):
        target = m.group(1)
        if _SKIP_SCHEME.match(target):
            continue
        path_part, _, anchor = target.partition("#")
        yield path_part, anchor


def _resolve(src, path_part):
    return src if not path_part else (src.parent / path_part).resolve()


ALL_LINKS = [(f, p, a) for f in MARKDOWN for p, a in _links(f)]


def test_there_are_links_to_check():
    # A glob or regex that matched nothing would make every assertion vacuous.
    assert len(MARKDOWN) >= 20, [str(p) for p in MARKDOWN]
    assert len(ALL_LINKS) >= 50, len(ALL_LINKS)
    assert any(a for _, _, a in ALL_LINKS), "no anchored links found — regex broken?"


@pytest.mark.parametrize("path", MARKDOWN, ids=lambda p: str(p.relative_to(ROOT)))
def test_relative_link_targets_exist(path):
    missing = []
    for path_part, _ in _links(path):
        if not path_part:
            continue
        target = _resolve(path, path_part)
        if not target.exists():
            missing.append(path_part)
    assert not missing, f"{path.relative_to(ROOT)} links to missing file(s): {missing}"


@pytest.mark.parametrize("path", MARKDOWN, ids=lambda p: str(p.relative_to(ROOT)))
def test_anchors_resolve(path):
    broken = []
    for path_part, anchor in _links(path):
        if not anchor:
            continue
        target = _resolve(path, path_part)
        if not target.exists() or target.suffix != ".md":
            continue  # missing files are the other test's job
        if anchor not in anchors(target):
            broken.append(f"{path_part or path.name}#{anchor}")
    assert not broken, f"{path.relative_to(ROOT)} has broken anchor(s): {broken}"


# ── the slug rules themselves ───────────────────────────────────────────────
# Pinned because a subtly wrong slugger reports correct links as broken, which
# is how a working link gets "fixed" into a broken one.

@pytest.mark.parametrize("heading,expected", [
    ("The LLM credential (Bedrock / Vertex / Azure)",
     "the-llm-credential-bedrock--vertex--azure"),   # runs of spaces are NOT collapsed
    ("Least-privilege credentials — do this", "least-privilege-credentials--do-this"),
    ("Clean PRs stay quiet", "clean-prs-stay-quiet"),
    ("Re-running a review", "re-running-a-review"),
    ("`max-comments` and friends", "max-comments-and-friends"),   # backticks stripped
    ("**Bold** heading", "bold-heading"),
    # Underscores are identifier characters, not emphasis markers. Stripping
    # them reported a working link as broken.
    ("3. Optional — `COPILOT_SYNC_TOKEN` for hands-off PRs",
     "3-optional--copilot_sync_token-for-hands-off-prs"),
    ("AI_REVIEW_CLI_NATIVE_AUTH", "ai_review_cli_native_auth"),
    ("Run it alongside your scanners, not instead of them",
     "run-it-alongside-your-scanners-not-instead-of-them"),
])
def test_slugify_matches_github(heading, expected):
    assert slugify(heading) == expected


def test_duplicate_headings_get_numeric_suffixes(tmp_path):
    f = tmp_path / "d.md"
    f.write_text("## Added\n\n## Added\n\n## Added\n")
    assert anchors(f) == {"added", "added-1", "added-2"}


def test_headings_inside_fences_are_not_anchors(tmp_path):
    f = tmp_path / "d.md"
    f.write_text("## Real\n\n```bash\n# Not a heading\n```\n")
    assert anchors(f) == {"real"}
