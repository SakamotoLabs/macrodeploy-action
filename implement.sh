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
ALWAYS add or update a test that exercises this change — this is required, and
ideally it would fail without your change and pass with it. Do NOT use git and do
NOT open a pull request — only edit files. Keep the change focused. End your reply
with a 1-3 sentence summary of what you implemented."
# Docker actions run as root, where --dangerously-skip-permissions is refused.
# acceptEdits auto-approves file create/edit (Write/Edit) without prompts.
SUMMARY=$(claude -p "$PROMPT" --model "$MODEL" --permission-mode acceptEdits \
  --allowedTools "Edit,Write,Read" 2>/dev/null) || echo "(agent run returned non-zero)"
echo "$SUMMARY"
echo "::endgroup::"

# Use porcelain (not `git diff`) so newly-created untracked files count too.
if [ -z "$(git status --porcelain)" ]; then
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

## What this does
${SUMMARY:-(see commit)}

Closes #${NUM}" \
  '{title:$t, head:$h, base:$b, body:$body}')

PR_RESP=$(curl -s -X POST \
  -H "Authorization: Bearer ${GITHUB_TOKEN}" \
  -H "Accept: application/vnd.github+json" \
  "https://api.github.com/repos/${GITHUB_REPOSITORY}/pulls" \
  -d "$PR_JSON")
PR_NUM=$(echo "$PR_RESP" | jq -r '.number // empty')
echo "$PR_RESP" | jq -r '.html_url // ("PR create failed: " + (.message // "unknown"))'

# Gate + review the agent's own code here (a GITHUB_TOKEN-created PR doesn't
# auto-trigger the verify workflow, so we post the checks directly on its commit).
HEAD_SHA=$(git rev-parse HEAD)

echo "::group::Verify (agent code)"
verify.sh .
GATE_RC=$?
echo "::endgroup::"
CONCL=$([ "$GATE_RC" -eq 0 ] && echo success || echo failure)
curl -s -X POST \
  -H "Authorization: Bearer ${GITHUB_TOKEN}" \
  -H "Accept: application/vnd.github+json" \
  "https://api.github.com/repos/${GITHUB_REPOSITORY}/check-runs" \
  -d "$(jq -n --arg s "$HEAD_SHA" --arg c "$CONCL" \
    '{name:"MacroDeploy gate", head_sha:$s, status:"completed", conclusion:$c, output:{title:"Verify gate", summary:("Gate " + $c + " on the agent’s changes.")}}')" \
  >/dev/null && echo "gate check posted ($CONCL)"

echo "::group::Review (agent code)"
REVIEW_BASE_REF="$DEFAULT" REVIEW_HEAD_SHA="$HEAD_SHA" REVIEW_PR_NUMBER="$PR_NUM" \
  INPUT_ANTHROPIC_API_KEY="$KEY" INPUT_MODEL="$MODEL" \
  node /usr/local/bin/review.mjs || true
echo "::endgroup::"

echo "::group::Auto-merge"
# shellcheck source=/dev/null
source /usr/local/bin/automerge.sh
maybe_automerge "$PR_NUM" "$CONCL" "$DEFAULT" "$HEAD_SHA"
echo "::endgroup::"
