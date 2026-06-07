#!/usr/bin/env bash
# MacroDeploy action entrypoint. Runs inside the container with the customer's repo
# mounted at $GITHUB_WORKSPACE:
#   1. install dependencies (auto-detected)
#   2. run the verify gate (typecheck/lint/tests[/build]) — its exit code is the
#      action's result, so a red build fails the check
#   3. optionally post an AI review of the PR diff (best-effort, never fails CI)
set -uo pipefail

cd "${GITHUB_WORKSPACE:-/github/workspace}" || { echo "no workspace"; exit 1; }

# Agent modes hand off to their script and exit.
if [ "${INPUT_MODE:-verify}" = "implement" ]; then
  exec /usr/local/bin/implement.sh
fi
if [ "${INPUT_MODE:-verify}" = "fix" ]; then
  exec /usr/local/bin/fix.sh
fi
if [ "${INPUT_MODE:-verify}" = "security" ]; then
  git config --global --add safe.directory "$PWD" 2>/dev/null || true
  exec node /usr/local/bin/security.mjs
fi
if [ "${INPUT_MODE:-verify}" = "coverage" ]; then
  git config --global --add safe.directory "$PWD" 2>/dev/null || true
  exec node /usr/local/bin/coverage.mjs
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

# ── 3. AI review → Check Run with inline annotations (best-effort) ───────────
if [ "$REVIEW" = "true" ] && [ -n "$KEY" ] && [ -n "${GITHUB_BASE_REF:-}" ]; then
  echo "::group::AI review"
  git config --global --add safe.directory "$PWD" 2>/dev/null || true
  git fetch --no-tags --depth=50 origin "$GITHUB_BASE_REF" 2>/dev/null || true
  INPUT_ANTHROPIC_API_KEY="$KEY" INPUT_MODEL="$MODEL" node /usr/local/bin/review.mjs || true
  echo "::endgroup::"
fi

# The verify gate decides the check's pass/fail.
exit "$VERIFY_RC"
