#!/usr/bin/env bash
# Fix mode: make the PR mergeable — address the AI review findings AND, if the
# verify gate (build/tests) is red, repair that too (it's blocking this PR), all on
# the PR's own branch. Triggered by workflow_dispatch with the PR number.
# Self-contained (only ANTHROPIC_API_KEY / CLAUDE_CODE_OAUTH_TOKEN).
set -uo pipefail

cd "${GITHUB_WORKSPACE:-/github/workspace}" || { echo "no workspace"; exit 1; }

KEY="${INPUT_ANTHROPIC_API_KEY:-}"
MODEL="${INPUT_MODEL:-claude-sonnet-4-6}"
PR="${INPUT_PR_NUMBER:-}"
MAX_GATE_REPAIRS=2 # bounded so a truly-stuck gate escalates instead of looping

if [ -z "$KEY" ] && [ -z "${CLAUDE_CODE_OAUTH_TOKEN:-}" ]; then
  echo "fix: no ANTHROPIC_API_KEY or CLAUDE_CODE_OAUTH_TOKEN"; exit 1
fi
[ -z "$PR" ] && { echo "fix: no PR number"; exit 1; }

git config --global --add safe.directory "$PWD" 2>/dev/null || true

api() { curl -s -H "Authorization: Bearer ${GITHUB_TOKEN}" -H "Accept: application/vnd.github+json" "$@"; }

# Pull the human-readable failing lines out of a verify.sh run, for the agent
# prompt and the escalation comment.
extract_fails() {
  printf '%s\n' "$1" \
    | grep -iE '✗|✘|FAIL|error TS|Error:|assert|expected|failing|failed' \
    | grep -viE '::(group|endgroup)|VERIFY (PASSED|FAILED)|gate check posted' \
    | head -40
}

post_comment() {
  api -X POST "https://api.github.com/repos/${GITHUB_REPOSITORY}/issues/${PR}/comments" \
    -d "$(jq -n --arg b "$1" '{body:$b}')" >/dev/null 2>&1 || true
}
post_gate() { # post_gate <sha> <success|failure>
  api -X POST "https://api.github.com/repos/${GITHUB_REPOSITORY}/check-runs" \
    -d "$(jq -n --arg s "$1" --arg c "$2" \
      '{name:"MacroDeploy gate", head_sha:$s, status:"completed", conclusion:$c, output:{title:"Verify gate", summary:("Gate " + $c + " after fix.")}}')" \
    >/dev/null 2>&1 || true
}

# Scoped (changed-files-only) test runner for the red→green gate.
# shellcheck source=/dev/null
source /usr/local/bin/scoped-tests.sh

SYS_ARGS=()
[ -f /usr/local/share/macrodeploy/skills/fixing.md ] \
  && SYS_ARGS=(--append-system-prompt "$(cat /usr/local/share/macrodeploy/skills/fixing.md)")

PRJSON=$(api "https://api.github.com/repos/${GITHUB_REPOSITORY}/pulls/${PR}")
HEAD_REF=$(echo "$PRJSON" | jq -r '.head.ref')
BASE_REF=$(echo "$PRJSON" | jq -r '.base.ref')
[ -z "$HEAD_REF" ] || [ "$HEAD_REF" = "null" ] && { echo "fix: could not resolve PR branch"; exit 1; }

git fetch --no-tags origin "$HEAD_REF" "$BASE_REF" 2>/dev/null || true
git checkout -B "$HEAD_REF" "origin/$HEAD_REF"
HEAD_SHA=$(git rev-parse HEAD)
NEW_SHA="$HEAD_SHA"

echo "::group::Install dependencies"
if [ -f package.json ]; then
  corepack enable >/dev/null 2>&1 || true
  if   [ -f pnpm-lock.yaml ];    then pnpm install --frozen-lockfile || pnpm install
  elif [ -f yarn.lock ];         then yarn install --frozen-lockfile || yarn install
  elif [ -f package-lock.json ]; then npm ci || npm install
  else npm install; fi
fi
echo "::endgroup::"

# GITHUB_TOKEN can't push .github/workflows changes — drop any the agent makes.
drop_workflow_changes() {
  if [ -n "$(git status --porcelain -- .github/workflows 2>/dev/null)" ]; then
    echo "fix: dropping .github/workflows changes — GITHUB_TOKEN can't push them"
    git checkout -- .github/workflows 2>/dev/null || true
    git clean -fdq .github/workflows 2>/dev/null || true
  fi
}

git config user.name "macrodeploy[bot]"
git config user.email "macrodeploy@users.noreply.github.com"
[ -n "$KEY" ] && export ANTHROPIC_API_KEY="$KEY"

# ── Collect review findings from the "MacroDeploy review" check ────────────────
CID=$(api "https://api.github.com/repos/${GITHUB_REPOSITORY}/commits/${HEAD_SHA}/check-runs" \
  | jq -r '.check_runs[] | select(.name=="MacroDeploy review") | .id' | head -1)
FINDINGS=""
if [ -n "$CID" ]; then
  LEVELS='.annotation_level=="failure"'
  if [ "${INPUT_BLOCK_WARNINGS:-false}" = "true" ] || [ "${INPUT_FIX_WARNINGS:-false}" = "true" ]; then
    LEVELS='(.annotation_level=="failure" or .annotation_level=="warning")'
  fi
  FINDINGS=$(api "https://api.github.com/repos/${GITHUB_REPOSITORY}/check-runs/${CID}/annotations" \
    | jq -r ".[] | select(${LEVELS}) | \"- \(.path):\(.start_line) [\(.annotation_level)] \(.message)\"")
fi

SUMMARY=""

# ── Phase 1: address review findings (if any) ─────────────────────────────────
if [ -n "$FINDINGS" ]; then
  echo "::group::Agent — review findings (test-first)"
  CONTEXT=$(repo-context.sh "$(git rev-parse --abbrev-ref HEAD 2>/dev/null)" 2>/dev/null || true)
  PROMPT="Address these code review findings in this repository, working test-first.

${CONTEXT}

For each finding where a test is feasible:
  1. First add or extend a FOCUSED test that fails BECAUSE of the finding, and run
     ONLY that test to confirm it fails (red). Do NOT run the whole suite.
  2. Implement the minimal fix.
  3. Run ONLY those targeted tests again until they pass (green).
If a finding genuinely cannot be tested, fix it and say so — do NOT invent a hollow test.

Do NOT use git and do NOT open a pull request — only edit files and run tests.

End with a 1-3 sentence summary, then on the VERY LAST line exactly one of:
  MACRODEPLOY_VERIFY=pass | MACRODEPLOY_VERIFY=fail | MACRODEPLOY_VERIFY=none

FINDINGS:
${FINDINGS}"
  RAW=$(claude -p "$PROMPT" --model "$MODEL" --permission-mode acceptEdits \
    --allowedTools "Edit,Write,Read,Bash,Grep,Glob" "${SYS_ARGS[@]}" 2>/dev/null) || echo "(agent run returned non-zero)"
  VERDICT=$(printf '%s\n' "$RAW" | grep -oE 'MACRODEPLOY_VERIFY=(pass|fail|none)' | tail -1 | cut -d= -f2)
  FSUM=$(printf '%s\n' "$RAW" | grep -v 'MACRODEPLOY_VERIFY=')
  echo "$FSUM"
  echo "fix: findings agent verdict = ${VERDICT:-unknown}"
  echo "::endgroup::"
  drop_workflow_changes

  if [ -z "$(git status --porcelain)" ]; then
    # No change: record the findings as dismissed non-issues + clear the review.
    echo "fix: findings agent made no changes (dismissed)"
    CLEAR_SHA="$HEAD_SHA"
    mkdir -p .macrodeploy
    {
      printf '\n### Dismissed %s (PR #%s)\n' "$(date -u +%Y-%m-%d)" "$PR"
      printf '%s\n' "$FINDINGS"
      printf '_Assessed by the fix agent as non-issues / intended behavior._\n'
    } >> .macrodeploy/memory.md
    git add .macrodeploy/memory.md
    if git commit -q -m "MacroDeploy: record dismissed findings as known non-issues (#${PR})" \
       && git push "https://x-access-token:${GITHUB_TOKEN}@github.com/${GITHUB_REPOSITORY}.git" "HEAD:${HEAD_REF}"; then
      CLEAR_SHA=$(git rev-parse HEAD)
      NEW_SHA="$CLEAR_SHA"
    fi
    post_comment "### 🔧 MacroDeploy fix — no change needed

The agent assessed the findings and decided no code change was required. Its reasoning:

${FSUM:-(no detail provided)}

**Findings considered:**
${FINDINGS}

_Recorded as known non-issues in \`.macrodeploy/memory.md\` so they won't be re-flagged._"
    if [ -n "$CID" ] && [ "$CID" != "null" ]; then
      KEEP=$(api "https://api.github.com/repos/${GITHUB_REPOSITORY}/check-runs/${CID}/annotations" \
        | jq '[.[] | select(.annotation_level=="notice") | {path, start_line, end_line, annotation_level, message}]')
      api -X POST "https://api.github.com/repos/${GITHUB_REPOSITORY}/check-runs" \
        -d "$(jq -n --argjson ann "${KEEP:-[]}" --arg s "$CLEAR_SHA" '{name:"MacroDeploy review", head_sha:$s, status:"completed", conclusion:"success", output:{title:"MacroDeploy review", summary:"Earlier findings were assessed and required no change — cleared.", annotations:$ann}}')" \
        >/dev/null || true
    fi
    # Fall through: even with findings dismissed, the gate may be red — repair below.
  else
    # Push the findings fix. The full verify gate below (+ repair loop) is the
    # authoritative check now, so we don't hold back on a scoped pre-check here.
    echo "::group::Autofix (changed files)"; autofix.sh .; echo "::endgroup::"
    git add -A
    git commit -q -m "Address MacroDeploy review findings (#${PR})"
    git push "https://x-access-token:${GITHUB_TOKEN}@github.com/${GITHUB_REPOSITORY}.git" "HEAD:${HEAD_REF}"
    NEW_SHA=$(git rev-parse HEAD)
    SUMMARY="$FSUM"
    echo "fix: pushed findings fix to ${HEAD_REF}"
    post_comment "### 🔧 MacroDeploy fix — addressed review findings

**What changed:**
${FSUM:-(see commit)}

**Findings addressed:**
${FINDINGS}

Pushed \`$(echo "$NEW_SHA" | cut -c1-8)\`. Verifying + (if needed) repairing the gate below."
  fi
fi

# ── Phase 2: verify the gate, and REPAIR it if red (it blocks this PR) ─────────
echo "::group::Verify (gate)"
GATE_OUT=$(verify.sh . 2>&1); GATE_RC=$?
printf '%s\n' "$GATE_OUT" | tail -60
echo "::endgroup::"
post_gate "$NEW_SHA" "$([ "$GATE_RC" -eq 0 ] && echo success || echo failure)"

# Nothing to do: no findings to fix and the gate is already green.
if [ -z "$FINDINGS" ] && [ "$GATE_RC" -eq 0 ]; then
  echo "fix: no findings and gate green — nothing to do"
  post_comment "### 🔧 MacroDeploy fix — nothing to do

No blocking review findings, and the verify gate is green. ✅"
  exit 0
fi

attempt=0
while [ "$GATE_RC" -ne 0 ] && [ "$attempt" -lt "$MAX_GATE_REPAIRS" ]; do
  attempt=$((attempt + 1))
  FAILS=$(extract_fails "$GATE_OUT")
  echo "::group::Gate repair — attempt ${attempt}"
  RPROMPT="The verify gate (full build + tests) is FAILING on this pull request and is
blocking it from merging. Fix the failing checks so the build and the entire test
suite pass. A failure may be pre-existing or unrelated to this PR's feature — fix
it anyway, because it is blocking this PR. Prefer fixing the root cause; if a test
itself is wrong/flaky, correct the test. Make minimal changes.

Do NOT use git and do NOT open a pull request — only edit files and run tests.
End with a 1-3 sentence summary of what you changed.

FAILING CHECKS:
${FAILS:-$(printf '%s\n' "$GATE_OUT" | tail -30)}"
  RAW=$(claude -p "$RPROMPT" --model "$MODEL" --permission-mode acceptEdits \
    --allowedTools "Edit,Write,Read,Bash,Grep,Glob" "${SYS_ARGS[@]}" 2>/dev/null) || echo "(agent run returned non-zero)"
  RSUM=$(printf '%s\n' "$RAW" | grep -v 'MACRODEPLOY_VERIFY=')
  echo "$RSUM"
  echo "::endgroup::"
  drop_workflow_changes
  if [ -z "$(git status --porcelain)" ]; then
    echo "gate-repair: agent made no changes — cannot fix, stopping"
    break
  fi
  echo "::group::Autofix (changed files)"; autofix.sh .; echo "::endgroup::"
  git add -A
  git commit -q -m "MacroDeploy: repair failing gate (#${PR}) [attempt ${attempt}]"
  git push "https://x-access-token:${GITHUB_TOKEN}@github.com/${GITHUB_REPOSITORY}.git" "HEAD:${HEAD_REF}"
  NEW_SHA=$(git rev-parse HEAD)
  SUMMARY="${SUMMARY}
Gate-repair ${attempt}: ${RSUM}"
  post_comment "### 🔧 MacroDeploy — gate repair (attempt ${attempt})

The build/tests were failing (this blocks the PR). The agent attempted a fix:

${RSUM:-(see commit)}

Re-verifying…"
  echo "::group::Verify (after repair ${attempt})"
  GATE_OUT=$(verify.sh . 2>&1); GATE_RC=$?
  printf '%s\n' "$GATE_OUT" | tail -60
  echo "::endgroup::"
  post_gate "$NEW_SHA" "$([ "$GATE_RC" -eq 0 ] && echo success || echo failure)"
done

# ── Still red after repairs → escalate with a CLEAR, actionable message ────────
if [ "$GATE_RC" -ne 0 ]; then
  FAILS=$(extract_fails "$GATE_OUT")
  api -X POST "https://api.github.com/repos/${GITHUB_REPOSITORY}/issues/${PR}/labels" \
    -d '{"labels":["needs-human"]}' >/dev/null 2>&1 || true
  post_comment "### 🙋 MacroDeploy — needs a human

The build/tests are still failing after ${attempt} automated repair attempt(s), so
**auto-merge stays blocked** until the gate is green.

**Still failing:**
\`\`\`
${FAILS:-see the run logs}
\`\`\`

**What to do:** open the PR, fix the failing check(s) above and push — or click
**Fix findings** again to retry. Clicking Fix re-runs the repair, so it's safe."
  echo "fix: gate still red after ${attempt} repair attempt(s) — escalated #${PR}"
  exit 0
fi

# ── Gate green → re-review + auto-merge ────────────────────────────────────────
echo "::group::Review (after fix)"
REVIEW_BASE_REF="$BASE_REF" REVIEW_HEAD_SHA="$NEW_SHA" REVIEW_PR_NUMBER="$PR" \
  INPUT_ANTHROPIC_API_KEY="$KEY" INPUT_MODEL="$MODEL" \
  node /usr/local/bin/review.mjs || true
echo "::endgroup::"

echo "::group::Auto-merge"
# shellcheck source=/dev/null
source /usr/local/bin/automerge.sh
maybe_automerge "$PR" "success" "$BASE_REF" "$NEW_SHA"
echo "::endgroup::"
