#!/usr/bin/env bash
#
# Shellcheck the shell EMBEDDED in workflow `run:` blocks.
#
# tests/run.sh lints the standalone libraries under workflows/_shared/lib/ and
# engines/, and nothing linted the shell inside .github/workflows/. That is
# where both release-gate bugs lived: `origin/FETCH_HEAD` (a gate that could
# never pass) and a `set -o pipefail` grep pipeline that killed the step on an
# empty match. CI catches these via actionlint, but only after a push — and a
# workflow-file change often cannot be pushed from a sandbox at all, so the
# feedback loop runs through a human.
#
# This is a SUBSET of actionlint, deliberately: shell lint only, no workflow
# schema, no expression checking. actionlint in CI remains the authority. The
# point is to catch the shell mistakes before the round trip.
#
# `${{ ... }}` expressions are replaced with a placeholder, the way actionlint
# does, because shellcheck cannot parse them.
set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/.."

if ! command -v shellcheck >/dev/null 2>&1; then
  echo "shellcheck not installed; skipping embedded-shell lint"
  exit 0
fi

tmp="$(mktemp -d)"
trap 'rm -rf "${tmp}"' EXIT

fail=0
blocks=0

for wf in .github/workflows/*.yml; do
  # Extract each `run: |` block, dedent it, and neutralise ${{ }}.
  python3 - "${wf}" "${tmp}" <<'PY'
import pathlib, re, sys

wf, out = pathlib.Path(sys.argv[1]), pathlib.Path(sys.argv[2])
text = wf.read_text()
name = wf.stem

for i, m in enumerate(re.finditer(r"^(\s+)run: \|\s*\n((?:\1  .*\n|\s*\n)+)", text, re.M)):
    indent = len(m.group(1)) + 2
    body = "".join(
        line[indent:] if line.strip() else "\n" for line in m.group(2).splitlines(True)
    )
    # actionlint substitutes expressions before handing the script to
    # shellcheck; without this every ${{ }} is a parse error.
    body = re.sub(r"\$\{\{[^}]*\}\}", "EXPR", body)
    # Workflow-provided variables are not assigned in the snippet.
    header = (
        "#!/usr/bin/env bash\n"
        "# shellcheck disable=SC2154  # workflow env vars are set by the runner\n"
    )
    (out / f"{name}.{i}.sh").write_text(header + body)
PY
done

for script in "${tmp}"/*.sh; do
  [[ -e "${script}" ]] || continue
  blocks=$((blocks + 1))
  if ! shellcheck -S style -e SC2148 "${script}"; then
    echo "  ^ in an embedded run: block of .github/workflows/$(basename "${script}" | cut -d. -f1).yml"
    fail=1
  fi
done

# A regex that matched nothing would make this pass vacuously.
if ((blocks == 0)); then
  echo "FAIL: extracted no run: blocks from .github/workflows/ — the extractor is broken"
  exit 1
fi

if ((fail == 0)); then
  echo "embedded shell clean (${blocks} run: blocks)"
fi
exit "${fail}"
