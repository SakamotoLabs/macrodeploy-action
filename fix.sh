#!/usr/bin/env bash
# Fix mode: address the AI review findings on an existing PR — the agent edits
# the PR's own branch (a new commit), then we re-gate + re-review. Triggered by
# workflow_dispatch with the PR number. Self-contained (only ANTHROPIC_API_KEY).
set -uo pipefail

cd "${GITHUB_WORKSPACE:-/github/workspace}" || { echo "no workspace"; exit 1; }

KEY="${INPUT_ANTHROPIC_API_KEY:-}"
MODEL="${INPUT_MODEL:-claude-sonnet-4-6}"
PR="${INPUT_PR_NUMBER:-}"

[ -z "$KEY" ] && { echo "fix: no ANTHROPIC_API_KEY"; exit 1; }
[ -z "$PR" ] && { echo "fix: no PR number"; exit 1; }

git config --global --add safe.directory "$PWD" 2>/dev/null || true

api() { curl -s -H "Authorization: Bearer ${GITHUB_TOKEN}" -H "Accept: application/vnd.github+json" "$@"; }

# Scoped (changed-files-only) test runner for the red→green gate.
# shellcheck source=/dev/null
source /usr/local/bin/scoped-tests.sh

PRJSON=$(api "https://api.github.com/repos/${GITHUB_REPOSITORY}/pulls/${PR}")
HEAD_REF=$(echo "$PRJSON" | jq -r '.head.ref')
BASE_REF=$(echo "$PRJSON" | jq -r '.base.ref')
[ -z "$HEAD_REF" ] || [ "$HEAD_REF" = "null" ] && { echo "fix: could not resolve PR branch"; exit 1; }

git fetch --no-tags origin "$HEAD_REF" "$BASE_REF" 2>/dev/null || true
git checkout -B "$HEAD_REF" "origin/$HEAD_REF"
HEAD_SHA=$(git rev-parse HEAD)

echo "::group::Install dependencies"
if [ -f package.json ]; then
  corepack enable >/dev/null 2>&1 || true
  if   [ -f pnpm-lock.yaml ];    then pnpm install --frozen-lockfile || pnpm install
  elif [ -f yarn.lock ];         then yarn install --frozen-lockfile || yarn install
  elif [ -f package-lock.json ]; then npm ci || npm install
  else npm install; fi
fi
echo "::endgroup::"

# Collect the review findings from the "MacroDeploy review" check.
CID=$(api "https://api.github.com/repos/${GITHUB_REPOSITORY}/commits/${HEAD_SHA}/check-runs" \
  | jq -r '.check_runs[] | select(.name=="MacroDeploy review") | .id' | head -1)
FINDINGS=""
if [ -n "$CID" ]; then
  # Only address significant findings (warning/failure). Skip `notice` nits so
  # the fix → re-review loop converges instead of churning on style minutiae.
  FINDINGS=$(api "https://api.github.com/repos/${GITHUB_REPOSITORY}/check-runs/${CID}/annotations" \
    | jq -r '.[] | select(.annotation_level=="warning" or .annotation_level=="failure") | "- \(.path):\(.start_line) [\(.annotation_level)] \(.message)"')
fi
if [ -z "$FINDINGS" ]; then
  echo "fix: no significant findings (warning/failure) to address"
  api -X POST "https://api.github.com/repos/${GITHUB_REPOSITORY}/issues/${PR}/comments" \
    -d "$(jq -n --arg b "### 🔧 MacroDeploy fix

No significant findings (warning/failure) to address — only minor notes remain, which are safe to ignore or handle manually. ✅" '{body:$b}')" >/dev/null || true
  exit 0
fi

echo "::group::Agent (Claude Code, test-first)"
export ANTHROPIC_API_KEY="$KEY"
PROMPT="Address these code review findings in this repository, working test-first.

For each finding where a test is feasible:
  1. First add or extend a FOCUSED test that fails BECAUSE of the finding, and run
     ONLY that test (plus closely-related tests) to confirm it fails (red). Use the
     repo's existing test runner. Do NOT run the entire test suite — it is slow and
     runs later as a separate gate.
  2. Implement the minimal fix.
  3. Run ONLY those targeted/related tests again, and iterate until they pass (green).
If a finding genuinely cannot be tested (e.g. config, infra, a pure dependency bump),
fix it and say so — do NOT invent a hollow test just to have one.

Do NOT use git and do NOT open a pull request — only edit files and run tests.

End your reply with a 1-3 sentence summary of what you changed, then on the VERY LAST
line exactly one of:
  MACRODEPLOY_VERIFY=pass   (you added/updated targeted tests and they pass red→green)
  MACRODEPLOY_VERIFY=fail   (you could not get the targeted tests passing)
  MACRODEPLOY_VERIFY=none   (no targeted test was feasible for these findings)

FINDINGS:
${FINDINGS}"
RAW=$(claude -p "$PROMPT" --model "$MODEL" --permission-mode acceptEdits \
  --allowedTools "Edit,Write,Read,Bash,Grep,Glob" 2>/dev/null) || echo "(agent run returned non-zero)"
# Split the machine verdict off the human-facing summary.
VERDICT=$(printf '%s\n' "$RAW" | grep -oE 'MACRODEPLOY_VERIFY=(pass|fail|none)' | tail -1 | cut -d= -f2)
SUMMARY=$(printf '%s\n' "$RAW" | grep -v 'MACRODEPLOY_VERIFY=')
echo "$SUMMARY"
echo "fix: agent verdict = ${VERDICT:-unknown}"
echo "::endgroup::"

if [ -z "$(git status --porcelain)" ]; then
  echo "fix: agent made no changes"
  api -X POST "https://api.github.com/repos/${GITHUB_REPOSITORY}/issues/${PR}/comments" \
    -d "$(jq -n --arg b "### 🔧 MacroDeploy fix — no change needed

The agent assessed the findings and decided no code change was required (e.g. the concern was already handled, or it was a false positive). Its reasoning:

${SUMMARY:-(no detail provided)}

**Findings considered:**
${FINDINGS}" '{body:$b}')" >/dev/null || true

  # The agent reviewed the significant findings and required no change → clear
  # them so they stop showing as outstanding (keep notices). Posts a fresh review
  # check on the same commit; the dashboard reads the latest one.
  if [ -n "$CID" ] && [ "$CID" != "null" ]; then
    KEEP=$(api "https://api.github.com/repos/${GITHUB_REPOSITORY}/check-runs/${CID}/annotations" \
      | jq '[.[] | select(.annotation_level=="notice") | {path, start_line, end_line, annotation_level, message}]')
    api -X POST "https://api.github.com/repos/${GITHUB_REPOSITORY}/check-runs" \
      -d "$(jq -n --argjson ann "${KEEP:-[]}" --arg s "$HEAD_SHA" '{name:"MacroDeploy review", head_sha:$s, status:"completed", conclusion:"success", output:{title:"MacroDeploy review", summary:"Earlier findings were assessed by the fix agent and required no change — cleared. See the fix comment for the reasoning.", annotations:$ann}}')" \
      >/dev/null && echo "fix: cleared dismissed findings"
  fi
  exit 0
fi

# Red→green gate (SCOPED). The agent self-reports a verdict; we independently
# confirm by re-running ONLY the changed test files. The whole suite is NOT run
# here — it runs once afterwards as the pre-merge gate (verify.sh below). On
# failure we escalate and DO NOT push, so a broken/unverified fix never lands.
ESCALATE_REASON=""
if [ "$VERDICT" = "fail" ]; then
  ESCALATE_REASON="the fix could not get its targeted tests passing (red→green failed)."
else
  echo "::group::Scoped tests (changed files only)"
  run_changed_tests "$BASE_REF"; SC=$?
  echo "::endgroup::"
  [ "${SC:-2}" -eq 1 ] && ESCALATE_REASON="the targeted tests for this fix are failing."
fi
if [ -n "$ESCALATE_REASON" ]; then
  api -X POST "https://api.github.com/repos/${GITHUB_REPOSITORY}/issues/${PR}/labels" \
    -d '{"labels":["needs-human"]}' >/dev/null 2>&1 || true
  api -X POST "https://api.github.com/repos/${GITHUB_REPOSITORY}/issues/${PR}/comments" \
    -d "$(jq -n --arg b "### 🙋 MacroDeploy fix — needs a human

Held back — ${ESCALATE_REASON} **The change was not pushed.**

**Agent summary:**
${SUMMARY:-(none)}

**Findings considered:**
${FINDINGS}" '{body:$b}')" >/dev/null 2>&1 || true
  echo "fix: escalated #${PR} — not pushed (${ESCALATE_REASON})"
  exit 0
fi

case "$VERDICT" in
  pass) VERIFY_NOTE="✅ Targeted test(s) added/updated and confirmed passing (red→green).";;
  none) VERIFY_NOTE="⚠️ No targeted test was feasible for these findings — the full suite runs at the merge gate.";;
  *)    VERIFY_NOTE="Targeted tests checked.";;
esac

git config user.name "macrodeploy[bot]"
git config user.email "macrodeploy@users.noreply.github.com"
git add -A
git commit -q -m "Address MacroDeploy review findings (#${PR})"
git push "https://x-access-token:${GITHUB_TOKEN}@github.com/${GITHUB_REPOSITORY}.git" "HEAD:${HEAD_REF}"
NEW_SHA=$(git rev-parse HEAD)
echo "fix: pushed a commit to ${HEAD_REF}"

# Document the fix in the PR conversation.
api -X POST "https://api.github.com/repos/${GITHUB_REPOSITORY}/issues/${PR}/comments" \
  -d "$(jq -n --arg b "### 🔧 MacroDeploy fix — addressed review findings

**What changed:**
${SUMMARY:-(see commit)}

**Verification:** ${VERIFY_NOTE}

**Findings addressed:**
${FINDINGS}

Pushed commit \`$(echo "$NEW_SHA" | cut -c1-8)\` to \`${HEAD_REF}\`. Re-running gate + review below." '{body:$b}')" >/dev/null && echo "fix: posted PR comment"

echo "::group::Verify (after fix)"
verify.sh .
GATE_RC=$?
echo "::endgroup::"
CONCL=$([ "$GATE_RC" -eq 0 ] && echo success || echo failure)
api -X POST "https://api.github.com/repos/${GITHUB_REPOSITORY}/check-runs" \
  -d "$(jq -n --arg s "$NEW_SHA" --arg c "$CONCL" \
    '{name:"MacroDeploy gate", head_sha:$s, status:"completed", conclusion:$c, output:{title:"Verify gate", summary:("Gate " + $c + " after fix.")}}')" \
  >/dev/null && echo "gate check posted ($CONCL)"

echo "::group::Review (after fix)"
REVIEW_BASE_REF="$BASE_REF" REVIEW_HEAD_SHA="$NEW_SHA" REVIEW_PR_NUMBER="$PR" \
  INPUT_ANTHROPIC_API_KEY="$KEY" INPUT_MODEL="$MODEL" \
  node /usr/local/bin/review.mjs || true
echo "::endgroup::"

echo "::group::Auto-merge"
# shellcheck source=/dev/null
source /usr/local/bin/automerge.sh
maybe_automerge "$PR" "$CONCL" "$BASE_REF" "$NEW_SHA"
echo "::endgroup::"
