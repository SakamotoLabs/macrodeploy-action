# Action image: carries the verify engine + review script + the runtimes needed
# to install deps and run checks for Node and Python repos. The consumer's repo
# is mounted at $GITHUB_WORKSPACE; nothing is installed into their repo.
FROM node:20-slim

RUN apt-get update && apt-get install -y --no-install-recommends \
      bash git jq curl ca-certificates python3 python3-pip python3-venv \
    && rm -rf /var/lib/apt/lists/*

COPY verify.sh /usr/local/bin/verify.sh
COPY entrypoint.sh /usr/local/bin/entrypoint.sh
COPY review.mjs /usr/local/bin/review.mjs
RUN chmod +x /usr/local/bin/verify.sh /usr/local/bin/entrypoint.sh

ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
