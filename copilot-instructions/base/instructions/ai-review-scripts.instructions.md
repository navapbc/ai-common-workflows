---
applyTo: "**/*.sh,**/*.bash"
---

# AI Review — Shell Scripts (Copilot code review)

When reviewing changes to shell scripts — especially CI and security scripts —
apply the `security` perspective (see `ai-review-security.instructions.md` for
the comment format and severity ladder) with heightened attention to issues
specific to bash. These scripts often run in CI with elevated trust: they
invoke external tools with arguments, and a vulnerability here can compromise
the pipeline.

## High-yield checks for shell scripts

### Critical-severity flags

- **Safety bypass paths.** Anything that lets a script exit 0 (report success)
  without actually doing its job — e.g. catching all errors with `|| true` /
  `|| exit 0` that masks a real failure, or removing a fail-safe default.
- **Command injection** via unquoted user-controlled values passed to external
  commands. Paths, ref names, and environment variables can all contain shell
  metacharacters.
- **Disabled `set -euo pipefail`.** A change that removes any of these flags
  from a script that had them is a critical regression.
- **Hardcoded secrets** in any script.

### High-severity flags

- **Unquoted variable expansions** that should be quoted — especially
  `${file}`, `${ref}`, anything from `$1..$N`, and anything read from
  `git diff`:
  - `[[ -f $file ]]` should be `[[ -f "${file}" ]]`
  - `cp $src $dest` should be `cp "${src}" "${dest}"`
- **`eval` of any value** derived from user input, environment, or external
  command output.
- **TOCTOU race conditions** between a `[[ -f X ]]` check and a subsequent
  file operation.
- **External command output trusted without validation** — especially parsers
  that must match an exact expected string; partial or fuzzy matching where an
  exact match is required is a regression.

### Medium-severity flags

- **Subshells that hide errors.** `$(command)` inside `set -e` does not always
  propagate the inner command's exit code; explicit checks (`|| rc=$?`) are
  required when the script needs to inspect what happened.
- **`echo` for user-controlled content** where `printf '%s\n'` would be safer
  (echo interprets backslash escapes on some platforms).
- **Missing `local`** on function-scoped variables — they bleed into the
  global scope and may collide with caller variables.
- **Pipelines that mask exit codes** where exit codes matter (`set -o
  pipefail` mitigates but explicit handling is sometimes still needed).

### Low-severity flags

- Missing or wrong shebang (`#!/bin/sh` for bash-specific syntax).
- Inconsistent `[[ ]]` vs `[ ]`.
- Long lines (> 100 cols) without wrapping.

## Comment formatting reminders

All comments on shell scripts must:

1. Use the `security(<severity>):` Conventional Comments label. (Shell-script
   findings are security-perspective, not compliance.)
2. Be specific about which line and which behavior changes. "This script is
   dangerous" is not useful; "this change removes the marker-validation exit-1
   path, letting a review with no marker silently pass" is useful.
3. Provide a `` ```suggestion `` block for line-level changes, OR a
   `` ```bash `` block for structural changes.
