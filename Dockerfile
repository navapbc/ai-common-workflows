# Review image for the AI PR review sandbox.
#
# EXPERIMENTAL — supports the not-yet-shipped egress sandbox
# (engines/_common/sandbox/). The released GitHub Action and Jenkins plugin do NOT
# use this image; they run the engine natively. See
# engines/_common/sandbox/README.md.
#
# One image, three roles, selected by the command:
#   review phase   bash /opt/engines/security-compliance-review/harness/ai-security-compliance-review --against ... --json-out ...
#   post phase     bash /opt/engines/security-compliance-review/harness/ai-security-compliance-review --post-only ...
#   proxy sidecar  python3 /opt/engines/_common/sandbox/allowlist_proxy.py
#
# The engines tree baked into the image at /opt/engines makes it usable standalone;
# the sandbox wrapper (engines/_common/sandbox/sandbox.sh) bind-mounts its own
# engines copy over /opt/engines so the engine version always matches the
# checked-out action / installed plugin, not the image build date.
#
# NOTHING BUILDS OR PUBLISHES THIS IMAGE. There is no release workflow for it
# and no registry to pull it from — this file is built by hand, if at all. An
# earlier version of this comment pointed at `.github/workflows/
# release-image.yml` and said release builds pass explicit CLI versions. That
# workflow does not exist, so nothing passed them, and the `latest` defaults
# below were justified by a build that never ran.
#
# The versions are therefore pinned here, to the same values
# `ci::install_ai_cli` uses (workflows/_shared/lib/ci.sh). An agentic CLI that
# reads untrusted PR content should not float, and that reasoning does not stop
# applying because the surface is experimental — it is the surface where a
# floating install is least likely to be noticed.
# tests/python/test_cli_pin_hygiene.py asserts these stay equal to ci.sh's, so
# bumping one side forces the other.
#
# If this image is ever published: pull by digest, never by tag.

FROM node:22-slim

ARG CLAUDE_CODE_VERSION=2.1.285
ARG CODEX_VERSION=0.159.2
ARG COPILOT_VERSION=1.0.89

# git + python3 for the engine; gh for the post phase; ca-certificates so
# the AI CLIs can reach their HTTPS endpoints through the sandbox proxy.
RUN apt-get update \
  && apt-get install -y --no-install-recommends \
       git python3 ca-certificates curl gnupg \
  && curl -fsSL https://cli.github.com/packages/githubcli-archive-keyring.gpg \
       -o /usr/share/keyrings/githubcli-archive-keyring.gpg \
  && echo "deb [arch=$(dpkg --print-architecture) signed-by=/usr/share/keyrings/githubcli-archive-keyring.gpg] https://cli.github.com/packages stable main" \
       > /etc/apt/sources.list.d/github-cli.list \
  && apt-get update \
  && apt-get install -y --no-install-recommends gh \
  && apt-get purge -y curl gnupg \
  && apt-get autoremove -y \
  && rm -rf /var/lib/apt/lists/*

RUN npm install -g \
      "@anthropic-ai/claude-code@${CLAUDE_CODE_VERSION}" \
      "@openai/codex@${CODEX_VERSION}" \
      "@github/copilot@${COPILOT_VERSION}" \
  && npm cache clean --force

COPY engines /opt/engines

# Non-root by default; the sandbox wrapper additionally drops capabilities,
# mounts the checkout read-only, and puts HOME on a tmpfs.
USER node
WORKDIR /workspace
CMD ["bash"]
