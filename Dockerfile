# Action image: carries the verify engine + review script + the runtimes needed
# to install deps and run checks for Node and Python repos. The consumer's repo
# is mounted at $GITHUB_WORKSPACE; nothing is installed into their repo.
FROM node:20-slim

RUN apt-get update && apt-get install -y --no-install-recommends \
      bash git jq curl ca-certificates python3 python3-pip python3-venv \
    && rm -rf /var/lib/apt/lists/*

# Claude Code CLI powers the Issue→PR agent (implement mode).
RUN npm install -g @anthropic-ai/claude-code

# QA mode drives a headless Chrome through the running app via the Playwright MCP
# server (and can run the repo's own Playwright/Cypress E2E). Bundle Chromium and
# its OS libraries so the action stays self-contained.
RUN npm install -g @playwright/mcp@latest playwright@latest \
    && npx --yes playwright install --with-deps chromium \
    && rm -rf /var/lib/apt/lists/*

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
