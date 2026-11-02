"""Write an audit report bundle: a findings-first index plus per-directory docs.

    python3 write_audit_report.py <run_dir> <findings.json> <meta.json> [report.md]

Produces, inside <run_dir>:

    _INDEX.md          the front page — findings-first triage view
    findings.json      the merged machine-readable findings (copied verbatim)
    report.md          the narrative output, if one was captured
    src__api.md        one doc per directory that was audited
    infra.md           (slashes in a path become __ in the filename)

Two conventions carried over deliberately from the earlier iteration of this
tool, because people built habits on them:

  - Slashes become `__`, so a directory doc is findable by name.
  - Every finding is a `#### ` heading, so `grep -rl '^#### ' <run_dir>` lists
    exactly the docs that have findings and nothing else.

The bundle is generated from the merged findings JSON rather than from each
worker's output, so it is byte-identical whether the audit ran as one call or
fanned out across eight. A report whose shape depends on `--jobs` is a report
you cannot diff against last week's.
"""

import json
import pathlib
import shutil
import sys

SEVERITIES = ("CRITICAL", "HIGH", "MEDIUM", "LOW")
RANK = {s: i for i, s in enumerate(SEVERITIES)}

# Same wording as the posted PR review. A report directory gets handed around,
# attached to tickets, and read by people who never ran the tool — so the
# caveats have to travel with it.
DISCLAIMER = """> **Advisory, not exhaustive.** AI-assisted audit. It complements — it does not
> replace — SAST, dependency/CVE scanning, and secret scanning. Findings are one
> reviewer's opinion, not a verdict, and a clean result is not evidence that the
> code is safe. Any control IDs cited are model-generated and unverified: check
> them against the authoritative catalog before using them in a compliance
> artifact."""

TRIAGE_ORDER = """## Suggested triage order

1. **Every Critical finding, in every directory** — same-day attention.
2. **High findings in security-sensitive directories** (auth, payments, IaC
   roots) — current or next sprint.
3. **High findings elsewhere** — quarter-level backlog.
4. **Medium and Low findings** — read for *patterns*. One recurring Medium
   across many files is usually a systemic gap worth a single focused fix,
   not N separate tickets."""


def _slug(directory):
    """`src/api/auth` -> `src__api__auth`; the repo root -> `_root`."""
    if directory in ("", ".", "/"):
        return "_root"
    return directory.strip("/").replace("/", "__")


def _severity(finding):
    return str(finding.get("severity", "")).strip().upper()


def _directory_of(finding):
    path = str(finding.get("path", "") or "")
    parent = str(pathlib.PurePosixPath(path).parent)
    return "" if parent == "." else parent


def group_by_directory(findings):
    """Directory -> findings, each directory's findings worst-first."""
    grouped = {}
    for f in findings:
        grouped.setdefault(_directory_of(f), []).append(f)
    for items in grouped.values():
        # Stable within a severity: the order the audit reported them.
        items.sort(key=lambda f: RANK.get(_severity(f), len(SEVERITIES)))
    return grouped


def counts(findings):
    out = {s: 0 for s in SEVERITIES}
    unknown = 0
    for f in findings:
        sev = _severity(f)
        if sev in out:
            out[sev] += 1
        else:
            unknown += 1
    return out, unknown


def _finding_md(finding):
    sev = _severity(finding) or "UNKNOWN"
    persp = str(finding.get("perspective", "security")).lower()
    path = finding.get("path", "(no path)")
    line = finding.get("line")
    loc = f"`{path}:{line}`" if line is not None else f"`{path}`"
    parts = [f"#### {sev} · {persp} · {finding.get('title', 'Finding')}", "", loc, ""]
    if finding.get("description"):
        parts += [str(finding["description"]), ""]
    summary = finding.get("suggestion_summary")
    body = finding.get("suggestion_body")
    if summary:
        parts += [f"**Suggested fix:** {summary}", ""]
    if body:
        lang = finding.get("suggestion_language") or ""
        parts += [f"```{lang}", str(body), "```", ""]
    return "\n".join(parts)


def directory_doc(directory, findings, meta):
    label = directory or "(repository root)"
    head = [
        f"# Audit — `{label}`",
        "",
        f"[← back to the index](_INDEX.md) · {meta.get('repo', 'repo')} · "
        f"{meta.get('date', '')} run {meta.get('run', '')}",
        "",
    ]
    if not findings:
        # Clean docs deliberately contain no `#### `, so the grep convention
        # below lists only the docs worth opening.
        return "\n".join(head + ["No findings in this directory.", ""])
    c, unknown = counts(findings)
    tally = ", ".join(f"{n} {s.lower()}" for s, n in c.items() if n)
    if unknown:
        tally += f", {unknown} unrecognized severity"
    head += [f"**{len(findings)} finding(s):** {tally}", "", "## Findings", ""]
    return "\n".join(head + [_finding_md(f) for f in findings])


def index_doc(grouped, meta, has_report):
    findings_all = [f for items in grouped.values() for f in items]
    total, unknown = counts(findings_all)
    with_findings = {d: i for d, i in grouped.items() if i}
    clean = sorted(d for d, i in grouped.items() if not i)

    lines = [
        f"# Codebase audit — {meta.get('repo', 'repo')}",
        "",
        f"**Date:** {meta.get('date', '')} (run {meta.get('run', '')}) &nbsp;·&nbsp; "
        f"**Scope:** {meta.get('scope', 'repository root')}",
        "",
        f"**Profile:** `{meta.get('profile', 'base')}` &nbsp;·&nbsp; "
        f"**Tool:** `{meta.get('tool', '')}` &nbsp;·&nbsp; "
        f"**Endpoint:** `{meta.get('provider', 'api')}` &nbsp;·&nbsp; "
        f"**Adjudication:** `{meta.get('adjudication', '')}`",
        "",
        f"**Files audited:** {meta.get('files', '?')} across "
        f"{len(grouped)} director{'y' if len(grouped) == 1 else 'ies'} "
        f"({len(with_findings)} with findings, {len(clean)} clean)",
        "",
        DISCLAIMER,
        "",
    ]

    if not findings_all:
        lines += [
            "## ✅ No findings",
            "",
            "Nothing was reported at any severity in the audited scope. That is",
            "not a clean bill of health — see the caveat above — but there is",
            "nothing here to triage.",
            "",
        ]
    else:
        tally = ", ".join(f"**{n}** {s.lower()}" for s, n in total.items() if n)
        if unknown:
            tally += f", **{unknown}** of unrecognized severity"
        lines += [
            "## Directories with findings",
            "",
            f"{len(findings_all)} finding(s): {tally}. Worst first.",
            "",
            "| Directory | Critical | High | Medium | Low | Total |",
            "|---|---:|---:|---:|---:|---:|",
        ]
        rows = []
        for directory, items in with_findings.items():
            c, _ = counts(items)
            rows.append((c, directory, items))
        # Worst-first: critical desc, then high, medium, low, then name.
        rows.sort(key=lambda r: (-r[0]["CRITICAL"], -r[0]["HIGH"],
                                 -r[0]["MEDIUM"], -r[0]["LOW"], r[1]))
        for c, directory, items in rows:
            label = directory or "(root)"
            link = f"{_slug(directory)}.md#findings"
            lines.append(
                f"| [`{label}`]({link}) | {c['CRITICAL']} | {c['HIGH']} | "
                f"{c['MEDIUM']} | {c['LOW']} | {len(items)} |"
            )
        lines += ["", TRIAGE_ORDER, ""]

    if clean:
        lines += [
            "<details>",
            f"<summary>{len(clean)} clean director{'y' if len(clean) == 1 else 'ies'}"
            " (no findings)</summary>",
            "",
        ]
        lines += [f"- [`{d or '(root)'}`]({_slug(d)}.md)" for d in clean]
        lines += ["", "</details>", ""]

    lines += ["## Files in this bundle", ""]
    if has_report:
        lines.append("- `report.md` — the auditor's full narrative, including the posture summary")
    lines += [
        "- `findings.json` — machine-readable findings, same schema as the PR review",
        "- one `.md` per directory above (`/` becomes `__` in the filename)",
        "",
        "List only the docs that contain findings:",
        "",
        "```bash",
        "grep -rl '^#### ' .",
        "```",
        "",
    ]
    return "\n".join(lines)


def main(argv):
    if len(argv) not in (4, 5):
        print(
            "usage: write_audit_report.py <run_dir> <findings.json> <meta.json> [report.md]",
            file=sys.stderr,
        )
        return 2

    run_dir = pathlib.Path(argv[1])
    findings_path = pathlib.Path(argv[2])
    meta_path = pathlib.Path(argv[3])
    report_path = pathlib.Path(argv[4]) if len(argv) == 5 else None

    try:
        data = json.loads(findings_path.read_text())
        meta = json.loads(meta_path.read_text())
    except (OSError, ValueError) as exc:
        print(f"write_audit_report: cannot read inputs: {exc}", file=sys.stderr)
        return 2

    findings = data.get("comments") or []
    if not isinstance(findings, list):
        print("write_audit_report: comments is not a list", file=sys.stderr)
        return 2

    run_dir.mkdir(parents=True, exist_ok=True)

    # Every audited directory gets a doc, including the clean ones: the index
    # links to them, and "audited and clean" is a different statement from
    # "not audited".
    grouped = group_by_directory(findings)
    for directory in meta.get("directories", []):
        grouped.setdefault(directory, [])

    for directory, items in grouped.items():
        (run_dir / f"{_slug(directory)}.md").write_text(
            directory_doc(directory, items, meta)
        )

    shutil.copyfile(findings_path, run_dir / "findings.json")
    has_report = False
    if report_path and report_path.exists() and report_path.stat().st_size:
        shutil.copyfile(report_path, run_dir / "report.md")
        has_report = True

    (run_dir / "_INDEX.md").write_text(index_doc(grouped, meta, has_report))
    print(str(run_dir / "_INDEX.md"))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
