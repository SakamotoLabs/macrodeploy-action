# Action image: carries the verify engine + review script + the runtimes needed
# to install deps and run checks for Node and Python repos. The consumer's repo
# is mounted at $GITHUB_WORKSPACE; nothing is installed into their repo.
# Pull the base via Google's Docker Hub mirror — Docker Hub's anonymous pulls are
# rate-limited and time out intermittently on shared CI runners, which fails the
# action build. mirror.gcr.io is a reliable pull-through cache with no such limit.
FROM mirror.gcr.io/library/node:20-slim

RUN apt-get update && apt-get install -y --no-install-recommends \
      bash git jq curl ca-certificates python3 python3-pip python3-venv \
    && rm -rf /var/lib/apt/lists/*

# Claude Code CLI powers the Issue→PR agent (implement mode).
RUN npm install -g @anthropic-ai/claude-code

# QA mode drives a headless Chrome through the running app via the Playwright MCP
# server (and can run the repo's own Playwright/Cypress E2E). Install a real
# Chromium from Debian and point the MCP at it via --executable-path, so we don't
# depend on Playwright's separately-managed chrome-for-testing download at runtime.
RUN apt-get update && apt-get install -y --no-install-recommends chromium \
    && npm install -g @playwright/mcp@latest playwright@latest \
    && rm -rf /var/lib/apt/lists/*
ENV PLAYWRIGHT_CHROMIUM_EXECUTABLE_PATH=/usr/bin/chromium

COPY verify.sh /usr/local/bin/verify.sh
COPY entrypoint.sh /usr/local/bin/entrypoint.sh
COPY implement.sh /usr/local/bin/implement.sh
COPY fix.sh /usr/local/bin/fix.sh
COPY review.mjs /usr/local/bin/review.mjs
COPY security.mjs /usr/local/bin/security.mjs
COPY coverage.mjs /usr/local/bin/coverage.mjs
COPY qa.mjs /usr/local/bin/qa.mjs
RUN chmod +x /usr/local/bin/verify.sh /usr/local/bin/entrypoint.sh /usr/local/bin/implement.sh /usr/local/bin/fix.sh

ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
