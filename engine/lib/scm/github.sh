#!/usr/bin/env bash
# engine/lib/scm/github.sh
#
# GitHub SCM backend for the AI PR-review engine: PR discovery and review
# posting via the `gh` CLI. This file is the ONLY place the engine talks to
# an SCM — swapping in another backend later means providing a sibling file
# (e.g. lib/scm/bitbucket.sh) that implements the same three functions and
# selecting it with AI_REVIEW_SCM.
#
#   scm::pr_base_ref <pr>       print the PR's base branch name
#   scm::discover_pr            print "<number>\t<base>" for the current branch
#   scm::post_review <pr> <json> post one review with inline comments
#
# GitHub Enterprise works through gh's own configuration: set GH_HOST to the
# GHE hostname and GH_ENTERPRISE_TOKEN (or GH_TOKEN) for auth.
#
# In the sandboxed flow, none of this runs inside the review sandbox — the
# post phase is a separate trusted process, and it is the only phase that
# holds a GitHub token.

set -euo pipefail

if [[ "${_AI_REVIEW_SCM_GITHUB_LOADED:-0}" == "1" ]]; then
  return 0
fi
_AI_REVIEW_SCM_GITHUB_LOADED=1

scm::require_cli() {
  local why="$1"
  if ! command -v gh &>/dev/null; then
    ai_review::err "'gh' CLI is required (${why}) but is not installed."
    ai_review::log "       Install: https://cli.github.com/  Then: gh auth login"
    ai_review::log "       Or set a token via the GH_TOKEN environment variable."
    exit 1
  fi
  # A token in the environment is sufficient even when `gh auth status`
  # reports not-logged-in (gh reads GH_TOKEN/GITHUB_TOKEN directly).
  if [[ -z "${GH_TOKEN:-}" && -z "${GITHUB_TOKEN:-}" ]] && ! gh auth status &>/dev/null; then
    ai_review::err "'gh' CLI is installed but not authenticated."
    ai_review::log "       Run:  gh auth login"
    ai_review::log "       Or set the GH_TOKEN environment variable."
    exit 1
  fi
}

# scm::pr_base_ref <pr_number> — look up the PR's base branch name.
scm::pr_base_ref() {
  local pr_number="$1"
  scm::require_cli "PR number was specified via --pr"
  local base
  base="$(gh pr view "${pr_number}" --json baseRefName --jq '.baseRefName' 2>/dev/null || true)"
  if [[ -z "${base}" ]]; then
    ai_review::err "could not look up PR #${pr_number} via gh CLI."
    ai_review::log "       Verify the PR number exists and you have access to it."
    exit 1
  fi
  printf '%s' "${base}"
}

# scm::discover_pr — find the open PR for the current branch.
# Prints "<number>\t<base>" on success; exits 1 with guidance otherwise.
scm::discover_pr() {
  if ! command -v gh &>/dev/null; then
    ai_review::err "cannot auto-discover the PR for the current branch — 'gh' CLI not installed."
    ai_review::log ""
    ai_review::log "  Either:"
    ai_review::log "    • Specify a PR explicitly:      --pr <number>"
    ai_review::log "    • Specify a base ref directly:  --against origin/main"
    exit 1
  fi

  local pr_json
  if ! pr_json="$(gh pr view --json number,baseRefName 2>/dev/null)"; then
    ai_review::err "'gh pr view' could not find an open PR for the current branch."
    ai_review::log ""
    ai_review::log "  Either:"
    ai_review::log "    • Push your branch and open a PR, then re-run; or"
    ai_review::log "    • Specify the PR number explicitly:   --pr <number>"
    ai_review::log "    • Specify the base ref directly:      --against origin/main"
    exit 1
  fi

  local number base
  number="$(echo "${pr_json}" | sed -n 's/.*"number":\([0-9]*\).*/\1/p')"
  base="$(echo "${pr_json}" | sed -n 's/.*"baseRefName":"\([^"]*\)".*/\1/p')"

  if [[ -z "${number}" ]] || [[ -z "${base}" ]]; then
    ai_review::err "failed to parse PR number / base ref from 'gh pr view' output."
    exit 1
  fi
  printf '%s\t%s' "${number}" "${base}"
}

# scm::post_review <pr_number> <review_json>
# Posts one PR review with inline comments. Idempotent across re-runs: the
# payload builder drops findings already carried by a live AI comment, and
# a review with nothing new to say is skipped entirely.
scm::post_review() {
  local pr_number="$1"
  local review_json="$2"

  scm::require_cli "--post-comments was specified"

  # Resolve owner/repo from gh's view of the current repo.
  local repo_slug
  if ! repo_slug="$(gh repo view --json nameWithOwner --jq '.nameWithOwner' 2>/dev/null)"; then
    ai_review::err "could not determine repo from gh CLI."
    exit 1
  fi

  if ! command -v python3 &>/dev/null; then
    ai_review::err "python3 is required to post inline review comments."
    ai_review::log "       (Used for transforming AI JSON output → GitHub API payload.)"
    exit 1
  fi

  # Idempotency: fetch the AI reviewer's existing inline comments so the
  # payload builder can drop any finding that already carries a live comment
  # on an unchanged line. Streamed as NDJSON via gh's built-in jq (one
  # object/line across all pages — avoids the concatenated-array invalid-JSON
  # problem). A fetch failure degrades safely to empty (no de-dup), never
  # blocking the post.
  local existing_comments
  existing_comments="$(gh api --paginate \
    "repos/${repo_slug}/pulls/${pr_number}/comments" \
    --jq '.[] | {path: .path, line: .line, body: .body}' 2>/dev/null || true)"
  export AI_REVIEW_EXISTING_COMMENTS="${existing_comments}"

  # Diff positions: fetch the PR's per-file patches so the payload builder can
  # drop any finding whose line is not part of the diff. GitHub rejects the
  # ENTIRE review (HTTP 422) if a single inline comment lands on a line outside
  # the diff. A fetch failure degrades to no filtering — the body-only POST
  # fallback below still protects the run.
  local pr_files
  pr_files="$(gh api --paginate \
    "repos/${repo_slug}/pulls/${pr_number}/files" \
    --jq '.[] | {filename: .filename, patch: .patch}' 2>/dev/null || true)"
  export AI_REVIEW_PR_FILES="${pr_files}"

  local api_payload
  api_payload="$(echo "${review_json}" | python3 "${ENGINE_HOME}/lib/scm/github_payload.py")"

  if [[ "${api_payload}" == "__AI_REVIEW_SKIP_POST__" ]]; then
    ai_review::info "No new findings to post (all already commented on unchanged lines)."
    return 0
  fi

  if [[ -z "${api_payload}" ]]; then
    ai_review::err "failed to construct GitHub API payload."
    exit 1
  fi

  ai_review::info "Posting review to ${repo_slug} PR #${pr_number} via gh api..."
  local resp rc=0
  resp="$(echo "${api_payload}" | gh api \
    "repos/${repo_slug}/pulls/${pr_number}/reviews" \
    --method POST --input - 2>&1)" || rc=$?
  if ((rc == 0)); then
    ai_review::info "Review posted."
    return 0
  fi

  # Non-zero: GitHub rejected the request. Surface its actual message — a 422
  # here is almost always an invalid review PAYLOAD (most often an inline
  # comment on a line not in the diff), NOT an auth problem (that would be
  # 401 / 403).
  ai_review::err "GitHub rejected the review:"
  printf '%s\n' "${resp}" | sed "s/^/    /" >&2

  # Fallback: if the payload carried inline comments, retry body-only so the
  # summary review still lands instead of failing the build outright.
  if ! printf '%s' "${api_payload}" | grep -q '"comments": \[\]'; then
    ai_review::warn "Retrying as a summary-only review (dropping inline comments)..."
    local body_only rc2=0 resp2
    body_only="$(printf '%s' "${api_payload}" | python3 -c 'import json,sys; d=json.load(sys.stdin); d["comments"]=[]; print(json.dumps(d))')" || body_only=""
    if [[ -n "${body_only}" ]]; then
      resp2="$(echo "${body_only}" | gh api \
        "repos/${repo_slug}/pulls/${pr_number}/reviews" \
        --method POST --input - 2>&1)" || rc2=$?
      if ((rc2 == 0)); then
        ai_review::info "Posted a summary-only review (inline comments dropped; findings are in the body)."
        return 0
      fi
      ai_review::err "Summary-only retry also failed:"
      printf '%s\n' "${resp2}" | sed "s/^/    /" >&2
    fi
  fi

  ai_review::err "could not post the review via 'gh api' (see GitHub's message above)."
  ai_review::log "       HTTP 422 = invalid review payload (commonly a comment line not in the diff)."
  ai_review::log "       HTTP 401 / 403 = auth / permissions (token needs 'pull-requests: write')."
  exit 1
}
