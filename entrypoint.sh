#!/usr/bin/env bash
# MacroDeploy action entrypoint. Runs inside the container with the customer's repo
# mounted at $GITHUB_WORKSPACE:
#   1. install dependencies (auto-detected)
#   2. run the verify gate (typecheck/lint/tests[/build]) — its exit code is the
#      action's result, so a red build fails the check
#   3. optionally post an AI review of the PR diff (best-effort, never fails CI)
set -uo pipefail

cd "${GITHUB_WORKSPACE:-/github/workspace}" || { echo "no workspace"; exit 1; }

# Auth: prefer the API key; otherwise use a Pro/Max subscription OAuth token, if
# provided, so AI runs draw on the user's plan. Export it process-wide so the
# Claude CLI + all runners pick it up. NOTE: a set ANTHROPIC_API_KEY silently
# overrides the OAuth token in the CLI, so only use the token when no key is set.
if [ -z "${INPUT_ANTHROPIC_API_KEY:-}" ] && [ -n "${INPUT_CLAUDE_CODE_OAUTH_TOKEN:-}" ]; then
  export CLAUDE_CODE_OAUTH_TOKEN="${INPUT_CLAUDE_CODE_OAUTH_TOKEN}"
  unset ANTHROPIC_API_KEY 2>/dev/null || true
fi

# Agent modes hand off to their script and exit.
if [ "${INPUT_MODE:-verify}" = "implement" ]; then
  exec /usr/local/bin/implement.sh
fi
if [ "${INPUT_MODE:-verify}" = "fix" ]; then
  exec /usr/local/bin/fix.sh
fi
if [ "${INPUT_MODE:-verify}" = "review" ]; then
  exec /usr/local/bin/review-pr.sh
fi
if [ "${INPUT_MODE:-verify}" = "resolve" ]; then
  exec /usr/local/bin/resolve.sh
fi
if [ "${INPUT_MODE:-verify}" = "steer" ]; then
  exec /usr/local/bin/steer.sh
fi
if [ "${INPUT_MODE:-verify}" = "security" ]; then
  git config --global --add safe.directory "$PWD" 2>/dev/null || true
  exec node /usr/local/bin/security.mjs
fi
if [ "${INPUT_MODE:-verify}" = "coverage" ]; then
  git config --global --add safe.directory "$PWD" 2>/dev/null || true
  exec node /usr/local/bin/coverage.mjs
fi
if [ "${INPUT_MODE:-verify}" = "deployaudit" ]; then
  git config --global --add safe.directory "$PWD" 2>/dev/null || true
  exec node /usr/local/bin/deploy-audit.mjs
fi
if [ "${INPUT_MODE:-verify}" = "deploysetup" ]; then
  exec /usr/local/bin/deploy-setup.sh
fi
if [ "${INPUT_MODE:-verify}" = "recommend" ]; then
  git config --global --add safe.directory "$PWD" 2>/dev/null || true
  exec node /usr/local/bin/recommend.mjs
fi
if [ "${INPUT_MODE:-verify}" = "plan" ]; then
  git config --global --add safe.directory "$PWD" 2>/dev/null || true
  exec node /usr/local/bin/plan.mjs
fi
if [ "${INPUT_MODE:-verify}" = "qa" ]; then
  git config --global --add safe.directory "$PWD" 2>/dev/null || true
  exec node /usr/local/bin/qa.mjs
fi
if [ "${INPUT_MODE:-verify}" = "checklist" ]; then
  git config --global --add safe.directory "$PWD" 2>/dev/null || true
  exec node /usr/local/bin/checklist.mjs
fi

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
# Python deps — monorepo-aware: install every poetry/pip project up to 2 levels
# deep (not just the repo root), so a subdir backend (e.g. backend/) gets its full
# dependency set — including the dev/test group (pytest-asyncio, etc.) the verify
# gate needs to collect and run the suite.
while IFS= read -r _pf; do
  _d=$(dirname "$_pf")
  if [ -f "$_d/poetry.lock" ] || grep -qs '^\[tool\.poetry\]' "$_pf"; then
    python3 -m pip install --quiet --break-system-packages poetry >/dev/null 2>&1 || true
    ( cd "$_d" && poetry install --no-interaction ) || true
  fi
done < <(find . -maxdepth 2 -name pyproject.toml -not -path '*/node_modules/*' 2>/dev/null)
while IFS= read -r _rf; do
  ( cd "$(dirname "$_rf")" && python3 -m pip install --quiet --break-system-packages -r requirements.txt ) || true
done < <(find . -maxdepth 2 -name requirements.txt -not -path '*/node_modules/*' 2>/dev/null)
echo "::endgroup::"

# ── 2. verify gate ──────────────────────────────────────────────────────────
echo "::group::Verify"
[ "$FAST" = "true" ] && export VERIFY_FAST=1
verify.sh .
VERIFY_RC=$?
echo "::endgroup::"

# ── 3. AI review → Check Run with inline annotations (best-effort) ───────────
if [ "$REVIEW" = "true" ] && { [ -n "$KEY" ] || [ -n "${CLAUDE_CODE_OAUTH_TOKEN:-}" ]; } && [ -n "${GITHUB_BASE_REF:-}" ]; then
  echo "::group::AI review"
  git config --global --add safe.directory "$PWD" 2>/dev/null || true
  git fetch --no-tags --depth=50 origin "$GITHUB_BASE_REF" 2>/dev/null || true
  INPUT_ANTHROPIC_API_KEY="$KEY" INPUT_MODEL="$MODEL" node /usr/local/bin/review.mjs || true
  echo "::endgroup::"
fi

# The verify gate decides the check's pass/fail.
exit "$VERIFY_RC"
