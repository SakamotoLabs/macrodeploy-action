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
  FINDINGS=$(api "https://api.github.com/repos/${GITHUB_REPOSITORY}/check-runs/${CID}/annotations" \
    | jq -r '.[] | "- \(.path):\(.start_line) [\(.annotation_level)] \(.message)"')
fi
if [ -z "$FINDINGS" ]; then
  echo "fix: no review findings to address"
  exit 0
fi

echo "::group::Agent (Claude Code)"
export ANTHROPIC_API_KEY="$KEY"
PROMPT="Address these code review findings in this repository. Edit files to resolve them and update or add tests as needed. Do NOT use git and do NOT open a pull request — only edit files.

FINDINGS:
${FINDINGS}"
claude -p "$PROMPT" --model "$MODEL" --permission-mode acceptEdits \
  --allowedTools "Edit,Write,Read" || echo "(agent run returned non-zero)"
echo "::endgroup::"

if [ -z "$(git status --porcelain)" ]; then
  echo "fix: agent made no changes"
  exit 0
fi

git config user.name "macrodeploy[bot]"
git config user.email "macrodeploy@users.noreply.github.com"
git add -A
git commit -q -m "Address MacroDeploy review findings (#${PR})"
git push "https://x-access-token:${GITHUB_TOKEN}@github.com/${GITHUB_REPOSITORY}.git" "HEAD:${HEAD_REF}"
NEW_SHA=$(git rev-parse HEAD)
echo "fix: pushed a commit to ${HEAD_REF}"

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
REVIEW_BASE_REF="$BASE_REF" REVIEW_HEAD_SHA="$NEW_SHA" \
  INPUT_ANTHROPIC_API_KEY="$KEY" INPUT_MODEL="$MODEL" \
  node /usr/local/bin/review.mjs || true
echo "::endgroup::"
