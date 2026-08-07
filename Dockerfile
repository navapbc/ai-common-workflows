# Review image for the AI PR review sandbox.
#
# EXPERIMENTAL — supports the not-yet-shipped egress sandbox
# (engines/_common/sandbox/). The released GitHub Action and Jenkins plugin do NOT
# use this image; they run the engine natively. See engine/lib/sandbox/README.md.
#
# One image, three roles, selected by the command:
#   review phase   bash /opt/engines/security-compliance-review/harness/ai-pr-review --against ... --json-out ...
#   post phase     bash /opt/engines/security-compliance-review/harness/ai-pr-review --post-only ...
#   proxy sidecar  python3 /opt/engines/_common/sandbox/allowlist_proxy.py
#
# The engines tree baked into the image at /opt/engines makes it usable standalone;
# the sandbox wrapper (engines/_common/sandbox/sandbox.sh) bind-mounts its own
# engines copy over /opt/engines so the engine version always matches the
# checked-out action / installed plugin, not the image build date.
#
# Release builds pass explicit CLI versions (see .github/workflows/
# release-image.yml); consumers should pull by digest, never by tag.

FROM node:22-slim

ARG CLAUDE_CODE_VERSION=latest
ARG CODEX_VERSION=latest
ARG COPILOT_VERSION=latest

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
