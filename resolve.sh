#!/usr/bin/env bash
# Resolve mode: bring a PR up to date with its base and resolve any merge
# conflicts, so it becomes mergeable. Merges the base branch into the PR branch;
# if that conflicts, the agent resolves the conflicted files (preserving both
# sides' intent), then we confirm with the SCOPED tests. If it can't be resolved
# cleanly, we abort the merge and escalate (needs-human) — never push a guess.
# Triggered by workflow_dispatch with the PR number.
set -uo pipefail

cd "${GITHUB_WORKSPACE:-/github/workspace}" || { echo "no workspace"; exit 1; }

KEY="${INPUT_ANTHROPIC_API_KEY:-}"
MODEL="${INPUT_MODEL:-claude-sonnet-4-6}"
PR="${INPUT_PR_NUMBER:-}"

[ -z "$KEY" ] && { echo "resolve: no ANTHROPIC_API_KEY"; exit 1; }
[ -z "$PR" ] && { echo "resolve: no PR number"; exit 1; }

git config --global --add safe.directory "$PWD" 2>/dev/null || true

# Scoped (changed-files-only) test runner — confirm the resolution didn't break.
# shellcheck source=/dev/null
source /usr/local/bin/scoped-tests.sh

# Coding rubric (root-cause → test-first → verify) as the system prompt.
SYS_ARGS=()
[ -f /usr/local/share/macrodeploy/skills/fixing.md ] \
  && SYS_ARGS=(--append-system-prompt "$(cat /usr/local/share/macrodeploy/skills/fixing.md)")

api() { curl -s -H "Authorization: Bearer ${GITHUB_TOKEN}" -H "Accept: application/vnd.github+json" "$@"; }

escalate() {
  api -X POST "https://api.github.com/repos/${GITHUB_REPOSITORY}/issues/${PR}/labels" \
    -d '{"labels":["needs-human"]}' >/dev/null 2>&1 || true
  api -X POST "https://api.github.com/repos/${GITHUB_REPOSITORY}/issues/${PR}/comments" \
    -d "$(jq -n --arg b "### 🙋 MacroDeploy — conflicts need a human

$1" '{body:$b}')" >/dev/null 2>&1 || true
  echo "resolve: escalated #${PR}"
}

PRJSON=$(api "https://api.github.com/repos/${GITHUB_REPOSITORY}/pulls/${PR}")
HEAD_REF=$(echo "$PRJSON" | jq -r '.head.ref')
BASE_REF=$(echo "$PRJSON" | jq -r '.base.ref')
[ -z "$HEAD_REF" ] || [ "$HEAD_REF" = "null" ] && { echo "resolve: could not resolve PR branch"; exit 1; }

git fetch --no-tags origin "$HEAD_REF" "$BASE_REF" 2>/dev/null || true
git checkout -B "$HEAD_REF" "origin/$HEAD_REF"

echo "::group::Install dependencies"
if [ -f package.json ]; then
  corepack enable >/dev/null 2>&1 || true
  if   [ -f pnpm-lock.yaml ];    then pnpm install --frozen-lockfile || pnpm install
  elif [ -f yarn.lock ];         then yarn install --frozen-lockfile || yarn install
  elif [ -f package-lock.json ]; then npm ci || npm install
  else npm install; fi
fi
echo "::endgroup::"

git config user.name "macrodeploy[bot]"
git config user.email "macrodeploy@users.noreply.github.com"

echo "::group::Merge base (${BASE_REF}) into ${HEAD_REF}"
if git merge --no-edit "origin/${BASE_REF}"; then
  echo "::endgroup::"
  # Clean merge (the branch was just behind, no conflicts).
  if [ -n "$(git log "origin/${HEAD_REF}..HEAD" --oneline 2>/dev/null)" ]; then
    git push "https://x-access-token:${GITHUB_TOKEN}@github.com/${GITHUB_REPOSITORY}.git" "HEAD:${HEAD_REF}"
    api -X POST "https://api.github.com/repos/${GITHUB_REPOSITORY}/issues/${PR}/comments" \
      -d "$(jq -n --arg b "### 🔀 MacroDeploy — brought up to date

Merged \`${BASE_REF}\` into \`${HEAD_REF}\` cleanly (no conflicts). The PR is now mergeable." '{body:$b}')" >/dev/null || true
    echo "resolve: clean merge pushed"
  else
    api -X POST "https://api.github.com/repos/${GITHUB_REPOSITORY}/issues/${PR}/comments" \
      -d "$(jq -n --arg b "### 🔀 MacroDeploy — already up to date

\`${HEAD_REF}\` has no conflicts with \`${BASE_REF}\`; nothing to resolve." '{body:$b}')" >/dev/null || true
    echo "resolve: nothing to do"
  fi
  exit 0
fi
echo "::endgroup::"

CONFLICTS=$(git diff --name-only --diff-filter=U)
echo "resolve: conflicted files:"
echo "$CONFLICTS" | sed 's/^/  - /'

echo "::group::Agent (Claude Code) — resolving conflicts"
export ANTHROPIC_API_KEY="$KEY"
export MAX_THINKING_TOKENS="${MAX_THINKING_TOKENS:-8000}"
PROMPT="A merge of branch '${BASE_REF}' into '${HEAD_REF}' produced conflicts. Resolve every conflict so the code is correct and BOTH sides' intent is preserved — do not blindly discard either side. Remove ALL conflict markers (<<<<<<<, =======, >>>>>>>).

Conflicted files:
${CONFLICTS}

After resolving, run ONLY the targeted/related tests for the affected files to confirm the result is correct — do NOT run the whole suite. Do NOT use git (do not commit, merge, or abort) — only edit files and run tests.

End your reply with a 1-3 sentence summary, then on the VERY LAST line exactly one of:
  MACRODEPLOY_VERIFY=pass   (conflicts resolved and targeted tests pass)
  MACRODEPLOY_VERIFY=fail   (could not resolve cleanly / tests fail)"
RAW=$(claude -p "$PROMPT" --model "$MODEL" --permission-mode acceptEdits \
  --allowedTools "Edit,Write,Read,Bash,Grep,Glob" "${SYS_ARGS[@]}" 2>/dev/null) || echo "(agent run returned non-zero)"
VERDICT=$(printf '%s\n' "$RAW" | grep -oE 'MACRODEPLOY_VERIFY=(pass|fail)' | tail -1 | cut -d= -f2)
SUMMARY=$(printf '%s\n' "$RAW" | grep -v 'MACRODEPLOY_VERIFY=')
echo "$SUMMARY"
echo "resolve: agent verdict = ${VERDICT:-unknown}"
echo "::endgroup::"

# Any remaining unmerged paths or conflict markers → not resolved.
REMAINING=$(git diff --name-only --diff-filter=U)
MARKERS=""
for f in $CONFLICTS; do
  [ -f "$f" ] && grep -qE '^(<<<<<<<|=======|>>>>>>>)' "$f" && MARKERS="${MARKERS} ${f}"
done

if [ "$VERDICT" = "fail" ] || [ -n "$REMAINING" ] || [ -n "$MARKERS" ]; then
  git merge --abort 2>/dev/null || true
  escalate "The conflicts in this PR couldn't be resolved automatically (markers/unmerged paths remained, or the agent was unsure). Please resolve manually.

**Agent summary:**
${SUMMARY:-(none)}

**Conflicted files:**
${CONFLICTS}"
  exit 0
fi

# Confirm the resolution with the scoped tests before completing the merge.
echo "::group::Scoped tests (changed files only)"
git add -A
run_changed_tests "$BASE_REF"; SC=$?
echo "::endgroup::"
if [ "${SC:-2}" -eq 1 ]; then
  git merge --abort 2>/dev/null || true
  escalate "Conflicts were resolved but the targeted tests fail afterwards — needs a human.

**Agent summary:**
${SUMMARY:-(none)}"
  exit 0
fi

git commit --no-edit -q
git push "https://x-access-token:${GITHUB_TOKEN}@github.com/${GITHUB_REPOSITORY}.git" "HEAD:${HEAD_REF}"
NEW_SHA=$(git rev-parse HEAD)
api -X POST "https://api.github.com/repos/${GITHUB_REPOSITORY}/issues/${PR}/comments" \
  -d "$(jq -n --arg b "### 🔀 MacroDeploy — conflicts resolved

Merged \`${BASE_REF}\` into \`${HEAD_REF}\` and resolved the conflicts. Targeted tests pass. The PR should now be mergeable.

**What was done:**
${SUMMARY:-(see merge commit)}

**Files that had conflicts:**
${CONFLICTS}

Pushed commit \`$(echo "$NEW_SHA" | cut -c1-8)\`." '{body:$b}')" >/dev/null && echo "resolve: pushed resolution"
