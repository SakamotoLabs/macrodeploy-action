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

# Accept a Claude Pro/Max OAuth token (exported by entrypoint.sh) as well as an
# API key — Claude Code picks up either from the environment.
if [ -z "$KEY" ] && [ -z "${CLAUDE_CODE_OAUTH_TOKEN:-}" ]; then
  echo "implement: no ANTHROPIC_API_KEY or CLAUDE_CODE_OAUTH_TOKEN"; exit 1
fi
[ -z "$NUM" ] && { echo "implement: no issue number"; exit 1; }

git config --global --add safe.directory "$PWD" 2>/dev/null || true

# Scoped (changed-files-only) test runner for the red→green gate.
# shellcheck source=/dev/null
source /usr/local/bin/scoped-tests.sh

# Coding rubric (root-cause → test-first → verify) as the system prompt; the
# repo's CLAUDE.md / AGENTS.md is auto-loaded by Claude Code for project context.
SYS_ARGS=()
[ -f /usr/local/share/macrodeploy/skills/fixing.md ] \
  && SYS_ARGS=(--append-system-prompt "$(cat /usr/local/share/macrodeploy/skills/fixing.md)")

echo "::group::Install dependencies"
if [ -f package.json ]; then
  corepack enable >/dev/null 2>&1 || true
  if   [ -f pnpm-lock.yaml ];    then pnpm install --frozen-lockfile || pnpm install
  elif [ -f yarn.lock ];         then yarn install --frozen-lockfile || yarn install
  elif [ -f package-lock.json ]; then npm ci || npm install
  else npm install; fi
fi
# Python deps — monorepo-aware (install subdir backends too), so the agent's
# test-first loop and the verify gate both have the dev/test group available.
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

echo "::group::Agent (Claude Code, test-first)"
# Only export a non-empty key — a set (even empty) ANTHROPIC_API_KEY shadows the
# OAuth token in the CLI. With OAuth, CLAUDE_CODE_OAUTH_TOKEN is already exported.
[ -n "$KEY" ] && export ANTHROPIC_API_KEY="$KEY"
# Codebase awareness + in-flight-changes view: layout, stack, existing migrations,
# and the files other open PRs touch — so parallel runs follow conventions and
# don't collide (e.g. duplicate migration ids authored off the same base).
CONTEXT=$(repo-context.sh "macrodeploy/issue-${NUM}" 2>/dev/null || true)
PROMPT="You are implementing GitHub issue #${NUM}: \"${TITLE}\".

${BODY}

${CONTEXT}

Make minimal, correct edits to satisfy the issue, working test-first:
  1. Add a FOCUSED test that captures the new behavior and fails before your change
     (run ONLY that test plus closely-related tests to see it fail — do NOT run the
     whole suite; it is slow and runs later as a separate gate).
  2. Implement the change.
  3. Run ONLY those targeted/related tests again and iterate until they pass (green).
A test proving the change is REQUIRED. Use the repo's existing test runner.

Do NOT use git and do NOT open a pull request — only edit files and run tests.

End your reply with a 1-3 sentence summary, then on the VERY LAST line exactly one of:
  MACRODEPLOY_VERIFY=pass   (targeted test added and passing red→green)
  MACRODEPLOY_VERIFY=fail   (could not get the targeted test passing)
  MACRODEPLOY_VERIFY=none   (no targeted test was feasible)"
# Docker actions run as root, where --dangerously-skip-permissions is refused.
# acceptEdits auto-approves Write/Edit; Bash is allowlisted so the agent can run
# the targeted tests for the red→green loop.
RAW=$(claude -p "$PROMPT" --model "$MODEL" --permission-mode acceptEdits \
  --allowedTools "Edit,Write,Read,Bash,Grep,Glob" "${SYS_ARGS[@]}" 2>/dev/null) || echo "(agent run returned non-zero)"
VERDICT=$(printf '%s\n' "$RAW" | grep -oE 'MACRODEPLOY_VERIFY=(pass|fail|none)' | tail -1 | cut -d= -f2)
SUMMARY=$(printf '%s\n' "$RAW" | grep -v 'MACRODEPLOY_VERIFY=')
echo "$SUMMARY"
echo "implement: agent verdict = ${VERDICT:-unknown}"
echo "::endgroup::"

# GITHUB_TOKEN can't push .github/workflows changes (a GitHub restriction; no
# permissions: key lifts it) and one rejected file fails the WHOLE push — so drop
# any workflow files the agent created/edited before we commit.
if [ -n "$(git status --porcelain -- .github/workflows 2>/dev/null)" ]; then
  echo "implement: dropping .github/workflows changes — GITHUB_TOKEN can't push them"
  git checkout -- .github/workflows 2>/dev/null || true
  git clean -fdq .github/workflows 2>/dev/null || true
fi

# Use porcelain (not `git diff`) so newly-created untracked files count too.
if [ -z "$(git status --porcelain)" ]; then
  echo "implement: agent made no file changes — nothing to PR"
  exit 0
fi

BRANCH="macrodeploy/issue-${NUM}"
git config user.name "macrodeploy[bot]"
git config user.email "macrodeploy@users.noreply.github.com"
git checkout -b "$BRANCH" 2>/dev/null || git checkout "$BRANCH"
# Auto-fix trivial lint/format on the changed files before committing, so the gate
# isn't tripped by import hygiene / formatting the agent didn't normalize.
echo "::group::Autofix (changed files)"
autofix.sh .
echo "::endgroup::"
git add -A
git commit -q -m "Implement #${NUM}: ${TITLE}"
git push -f "https://x-access-token:${GITHUB_TOKEN}@github.com/${GITHUB_REPOSITORY}.git" "HEAD:${BRANCH}"

DEFAULT=$(jq -r '.repository.default_branch // "main"' "${GITHUB_EVENT_PATH:-/dev/null}" 2>/dev/null)
[ -z "$DEFAULT" ] || [ "$DEFAULT" = "null" ] && DEFAULT=main

# Red→green gate (SCOPED): confirm the agent's verdict by re-running ONLY the
# changed test files (the whole suite runs below as the pre-merge gate). On
# failure we still open the PR so the work surfaces, but flag it for a human and
# skip auto-merge — an unverified change never merges on its own.
echo "::group::Scoped tests (changed files only)"
run_changed_tests "$DEFAULT"; SC=$?
echo "::endgroup::"
FAILED=0
{ [ "$VERDICT" = "fail" ] || [ "${SC:-2}" -eq 1 ]; } && FAILED=1
if [ "$FAILED" -eq 1 ]; then
  VERIFY_NOTE="❌ Targeted tests not passing — flagged for human review, auto-merge held."
elif [ "$VERDICT" = "none" ]; then
  VERIFY_NOTE="⚠️ No targeted test was feasible — the full suite runs at the merge gate."
else
  VERIFY_NOTE="✅ Targeted test added and confirmed passing (red→green)."
fi

PR_JSON=$(jq -n \
  --arg t "Implement #${NUM}: ${TITLE}" \
  --arg h "$BRANCH" --arg b "$DEFAULT" \
  --arg body "Implements #${NUM} — opened by MacroDeploy.

## What this does
${SUMMARY:-(see commit)}

**Verification:** ${VERIFY_NOTE}

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

ghpost() {
  curl -s -X POST -H "Authorization: Bearer ${GITHUB_TOKEN}" \
    -H "Accept: application/vnd.github+json" "https://api.github.com/repos/${GITHUB_REPOSITORY}/$1" -d "$2" >/dev/null
}

# Red→green failed: surface the PR for a human, mark the gate red, review for
# context, and DO NOT auto-merge. The work is preserved on the branch.
if [ "$FAILED" -eq 1 ] && [ -n "$PR_NUM" ]; then
  ghpost "issues/${PR_NUM}/labels" '{"labels":["needs-human"]}'
  ghpost "issues/${PR_NUM}/comments" "$(jq -n --arg b "### 🙋 MacroDeploy — needs a human

The implementation is up, but its targeted tests are not passing, so it was not auto-merged.

**Agent summary:**
${SUMMARY:-(none)}" '{body:$b}')"
  ghpost "check-runs" "$(jq -n --arg s "$HEAD_SHA" '{name:"MacroDeploy gate", head_sha:$s, status:"completed", conclusion:"failure", output:{title:"Verify gate", summary:"Targeted tests failing on the agent’s changes — needs human review."}}')"
  echo "::group::Review (agent code)"
  REVIEW_BASE_REF="$DEFAULT" REVIEW_HEAD_SHA="$HEAD_SHA" REVIEW_PR_NUMBER="$PR_NUM" \
    INPUT_ANTHROPIC_API_KEY="$KEY" INPUT_MODEL="$MODEL" node /usr/local/bin/review.mjs || true
  echo "::endgroup::"
  echo "implement: escalated #${PR_NUM} — targeted tests failing, auto-merge held"
  exit 0
fi

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
