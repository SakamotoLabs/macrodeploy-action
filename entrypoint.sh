#!/usr/bin/env bash
# MacroDeploy action entrypoint. Runs inside the container with the customer's repo
# mounted at $GITHUB_WORKSPACE:
#   1. install dependencies (auto-detected)
#   2. run the verify gate (typecheck/lint/tests[/build]) — its exit code is the
#      action's result, so a red build fails the check
#   3. optionally post an AI review of the PR diff (best-effort, never fails CI)
set -uo pipefail

cd "${GITHUB_WORKSPACE:-/github/workspace}" || { echo "no workspace"; exit 1; }

FAST="${INPUT_FAST:-false}"
REVIEW="${INPUT_REVIEW:-true}"
MODEL="${INPUT_MODEL:-claude-sonnet-4-6}"
KEY="${INPUT_ANTHROPIC_API_KEY:-}"

# ── 1. dependencies ─────────────────────────────────────────────────────────
echo "::group::Install dependencies"
if [ -f package.json ]; then
  corepack enable >/dev/null 2>&1 || true
  if   [ -f pnpm-lock.yaml ];   then pnpm install --frozen-lockfile || pnpm install
  elif [ -f yarn.lock ];        then yarn install --frozen-lockfile || yarn install
  elif [ -f package-lock.json ];then npm ci || npm install
  else npm install; fi
fi
if [ -f poetry.lock ] && [ -f pyproject.toml ]; then
  python3 -m pip install --quiet --break-system-packages poetry && poetry install --no-interaction || true
elif [ -f requirements.txt ]; then
  python3 -m pip install --quiet --break-system-packages -r requirements.txt || true
fi
echo "::endgroup::"

# ── 2. verify gate ──────────────────────────────────────────────────────────
echo "::group::Verify"
[ "$FAST" = "true" ] && export VERIFY_FAST=1
verify.sh .
VERIFY_RC=$?
echo "::endgroup::"

# ── 3. AI review (best-effort) ──────────────────────────────────────────────
if [ "$REVIEW" = "true" ] && [ -n "$KEY" ] && [ -n "${GITHUB_BASE_REF:-}" ]; then
  echo "::group::AI review"
  git config --global --add safe.directory "$PWD" 2>/dev/null || true
  git fetch --no-tags --depth=50 origin "$GITHUB_BASE_REF" 2>/dev/null || true
  DIFF=$(git diff --no-color "origin/${GITHUB_BASE_REF}...HEAD" 2>/dev/null | head -c 60000)

  if [ -n "$DIFF" ]; then
    PROMPT=$'Review this pull request diff. Be concise and concrete: flag real correctness or security bugs with file:line, skip style nits. If it looks good, say so in one line.\n\n'"$DIFF"
    REQ=$(jq -n --arg m "$MODEL" --arg p "$PROMPT" \
      '{model:$m, max_tokens:1024, messages:[{role:"user", content:$p}]}')
    RESP=$(curl -s https://api.anthropic.com/v1/messages \
      -H "x-api-key: $KEY" -H "anthropic-version: 2023-06-01" -H "content-type: application/json" \
      -d "$REQ")
    BODY=$(echo "$RESP" | jq -r '.content[0].text // .error.message // "review unavailable"')
    echo "$BODY"

    if [ -n "${GITHUB_TOKEN:-}" ] && [ -f "${GITHUB_EVENT_PATH:-/dev/null}" ]; then
      PR=$(jq -r '.pull_request.number // .number // empty' "$GITHUB_EVENT_PATH")
      if [ -n "$PR" ]; then
        COMMENT=$(jq -n --arg b "$BODY" '{body:("### 🤖 MacroDeploy review\n\n"+$b)}')
        curl -s -X POST \
          -H "Authorization: Bearer $GITHUB_TOKEN" \
          -H "Accept: application/vnd.github+json" \
          "https://api.github.com/repos/${GITHUB_REPOSITORY}/issues/${PR}/comments" \
          -d "$COMMENT" >/dev/null && echo "(posted PR comment)"
      fi
    fi
  fi
  echo "::endgroup::"
fi

# The verify gate decides the check's pass/fail.
exit "$VERIFY_RC"
