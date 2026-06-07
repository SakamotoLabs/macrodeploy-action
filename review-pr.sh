#!/usr/bin/env bash
# Re-review mode: run ONLY the AI review on an existing PR's current head (no fix,
# no new commit). Triggered by workflow_dispatch with the PR number. Lets the user
# get a fresh opinion — useful now that the reviewer has full-file context, so a
# re-review can clear an earlier false-positive finding. Self-contained.
set -uo pipefail

cd "${GITHUB_WORKSPACE:-/github/workspace}" || { echo "no workspace"; exit 1; }

KEY="${INPUT_ANTHROPIC_API_KEY:-}"
MODEL="${INPUT_MODEL:-claude-sonnet-4-6}"
PR="${INPUT_PR_NUMBER:-}"

[ -z "$KEY" ] && { echo "review: no ANTHROPIC_API_KEY"; exit 0; }
[ -z "$PR" ] && { echo "review: no PR number"; exit 1; }

git config --global --add safe.directory "$PWD" 2>/dev/null || true
api() { curl -s -H "Authorization: Bearer ${GITHUB_TOKEN}" -H "Accept: application/vnd.github+json" "$@"; }

PRJSON=$(api "https://api.github.com/repos/${GITHUB_REPOSITORY}/pulls/${PR}")
HEAD_REF=$(echo "$PRJSON" | jq -r '.head.ref')
BASE_REF=$(echo "$PRJSON" | jq -r '.base.ref')
[ -z "$HEAD_REF" ] || [ "$HEAD_REF" = "null" ] && { echo "review: could not resolve PR branch"; exit 1; }

git fetch --no-tags origin "$HEAD_REF" "$BASE_REF" 2>/dev/null || true
git checkout -B "$HEAD_REF" "origin/$HEAD_REF"
HEAD_SHA=$(git rev-parse HEAD)

echo "::group::Re-review (PR #${PR})"
REVIEW_BASE_REF="$BASE_REF" REVIEW_HEAD_SHA="$HEAD_SHA" REVIEW_PR_NUMBER="$PR" \
  INPUT_ANTHROPIC_API_KEY="$KEY" INPUT_MODEL="$MODEL" \
  node /usr/local/bin/review.mjs || true
echo "::endgroup::"
