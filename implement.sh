#!/usr/bin/env bash
# Issue→PR agent (self-contained: needs only ANTHROPIC_API_KEY, no extra app).
# Runs Claude Code headless to implement a labeled issue, then commits to a
# branch and opens a PR via the workflow token. Runs inside the action container
# with the repo mounted at $GITHUB_WORKSPACE.
set -uo pipefail

cd "${GITHUB_WORKSPACE:-/github/workspace}" || { echo "no workspace"; exit 1; }

KEY="${INPUT_ANTHROPIC_API_KEY:-}"
MODEL="${INPUT_MODEL:-claude-sonnet-4-6}"
TITLE="${INPUT_ISSUE_TITLE:-}"
BODY="${INPUT_ISSUE_BODY:-}"
NUM="${INPUT_ISSUE_NUMBER:-}"

[ -z "$KEY" ] && { echo "implement: no ANTHROPIC_API_KEY"; exit 1; }
[ -z "$NUM" ] && { echo "implement: no issue number"; exit 1; }

git config --global --add safe.directory "$PWD" 2>/dev/null || true

echo "::group::Install dependencies"
if [ -f package.json ]; then
  corepack enable >/dev/null 2>&1 || true
  if   [ -f pnpm-lock.yaml ];    then pnpm install --frozen-lockfile || pnpm install
  elif [ -f yarn.lock ];         then yarn install --frozen-lockfile || yarn install
  elif [ -f package-lock.json ]; then npm ci || npm install
  else npm install; fi
fi
echo "::endgroup::"

echo "::group::Agent (Claude Code)"
export ANTHROPIC_API_KEY="$KEY"
PROMPT="You are implementing GitHub issue #${NUM}: \"${TITLE}\".

${BODY}

Make minimal, correct edits to the files in this repository to satisfy the issue.
Add or update tests where it makes sense. Do NOT use git and do NOT open a pull
request — only edit files. Keep the change focused."
# Docker actions run as root, where --dangerously-skip-permissions is refused.
# acceptEdits auto-approves file create/edit (Write/Edit) without prompts.
claude -p "$PROMPT" --model "$MODEL" --permission-mode acceptEdits \
  --allowedTools "Edit,Write,Read" || echo "(agent run returned non-zero)"
echo "::endgroup::"

if git diff --quiet && git diff --cached --quiet; then
  echo "implement: agent made no file changes — nothing to PR"
  exit 0
fi

BRANCH="macrodeploy/issue-${NUM}"
git config user.name "macrodeploy[bot]"
git config user.email "macrodeploy@users.noreply.github.com"
git checkout -b "$BRANCH" 2>/dev/null || git checkout "$BRANCH"
git add -A
git commit -q -m "Implement #${NUM}: ${TITLE}"
git push -f "https://x-access-token:${GITHUB_TOKEN}@github.com/${GITHUB_REPOSITORY}.git" "HEAD:${BRANCH}"

DEFAULT=$(jq -r '.repository.default_branch // "main"' "${GITHUB_EVENT_PATH:-/dev/null}" 2>/dev/null)
[ -z "$DEFAULT" ] || [ "$DEFAULT" = "null" ] && DEFAULT=main

PR_JSON=$(jq -n \
  --arg t "Implement #${NUM}: ${TITLE}" \
  --arg h "$BRANCH" --arg b "$DEFAULT" \
  --arg body "Implements #${NUM} — opened by MacroDeploy.

Closes #${NUM}" \
  '{title:$t, head:$h, base:$b, body:$body}')

curl -s -X POST \
  -H "Authorization: Bearer ${GITHUB_TOKEN}" \
  -H "Accept: application/vnd.github+json" \
  "https://api.github.com/repos/${GITHUB_REPOSITORY}/pulls" \
  -d "$PR_JSON" | jq -r '.html_url // ("PR create failed: " + (.message // "unknown"))'
