#!/usr/bin/env bash
# Interactive steering: a human comments `/macrodeploy <instruction>` on a PR and
# the agent applies the requested change to that PR's branch — turning the
# fire-and-forget issue→PR flow into an iterative conversation. The special case
# `/macrodeploy qa` runs the headless-Chrome visual QA on the PR instead of editing.
set -uo pipefail
cd "${GITHUB_WORKSPACE:-/github/workspace}" || { echo "no workspace"; exit 1; }

KEY="${INPUT_ANTHROPIC_API_KEY:-}"
MODEL="${INPUT_MODEL:-claude-sonnet-4-6}"
PR="${INPUT_PR_NUMBER:-}"
COMMENT="${INPUT_COMMENT_BODY:-}"

# Accept a Claude Pro/Max OAuth token (exported by entrypoint.sh) as well as an
# API key — Claude Code picks up either from the environment.
if [ -z "$KEY" ] && [ -z "${CLAUDE_CODE_OAUTH_TOKEN:-}" ]; then
  echo "steer: no ANTHROPIC_API_KEY or CLAUDE_CODE_OAUTH_TOKEN"; exit 1
fi
[ -z "$PR" ]  && { echo "steer: no pr_number"; exit 1; }

# Strip the `/macrodeploy` trigger prefix → the actual instruction.
INSTR=$(printf '%s' "$COMMENT" | sed -E '1 s#^[[:space:]]*/macrodeploy[[:space:]]*##' | tr -d '\r')
INSTR=$(printf '%s' "$INSTR" | sed -E 's/^[[:space:]]+//; s/[[:space:]]+$//')
[ -z "$INSTR" ] && { echo "steer: empty instruction"; exit 0; }

git config --global --add safe.directory "$PWD" 2>/dev/null || true
api() {
  curl -s -H "Authorization: Bearer ${GITHUB_TOKEN}" -H "Accept: application/vnd.github+json" \
    "https://api.github.com/repos/${GITHUB_REPOSITORY}$1"
}
ghpost() {
  curl -s -X POST -H "Authorization: Bearer ${GITHUB_TOKEN}" -H "Accept: application/vnd.github+json" \
    "https://api.github.com/repos/${GITHUB_REPOSITORY}/$1" -d "$2" >/dev/null
}

# Resolve the PR's head/base branches and check it out.
PR_JSON=$(api "/pulls/${PR}")
HEAD_REF=$(printf '%s' "$PR_JSON" | jq -r '.head.ref // empty')
BASE_REF=$(printf '%s' "$PR_JSON" | jq -r '.base.ref // "main"')
[ -z "$HEAD_REF" ] && { echo "steer: PR #$PR not found"; exit 1; }

git config user.name "macrodeploy[bot]"
git config user.email "macrodeploy@users.noreply.github.com"
git fetch -q origin "$HEAD_REF" || true
git checkout -B "$HEAD_REF" "origin/$HEAD_REF" 2>/dev/null || git checkout "$HEAD_REF"

# `/macrodeploy qa` → drive the running app through headless Chrome instead of editing.
if printf '%s' "$INSTR" | grep -qiE '^qa\b'; then
  echo "steer: routing to visual QA"
  exec node /usr/local/bin/qa.mjs
fi

echo "::group::Install dependencies"
if [ -f package.json ]; then
  corepack enable >/dev/null 2>&1 || true
  if   [ -f pnpm-lock.yaml ];    then pnpm install --frozen-lockfile || pnpm install
  elif [ -f yarn.lock ];         then yarn install --frozen-lockfile || yarn install
  elif [ -f package-lock.json ]; then npm ci || npm install
  else npm install; fi
fi
while IFS= read -r _pf; do
  _d=$(dirname "$_pf")
  if [ -f "$_d/poetry.lock" ] || grep -qs '^\[tool\.poetry\]' "$_pf"; then
    python3 -m pip install --quiet --break-system-packages poetry >/dev/null 2>&1 || true
    ( cd "$_d" && poetry install --no-interaction ) || true
  fi
done < <(find . -maxdepth 2 -name pyproject.toml -not -path '*/node_modules/*' 2>/dev/null)
echo "::endgroup::"

SYS_ARGS=()
[ -f /usr/local/share/macrodeploy/skills/fixing.md ] \
  && SYS_ARGS=(--append-system-prompt "$(cat /usr/local/share/macrodeploy/skills/fixing.md)")

CONTEXT=$(repo-context.sh "$HEAD_REF" 2>/dev/null || true)
DIFF=$(git diff "origin/${BASE_REF}...HEAD" 2>/dev/null | head -c 50000)

# Only export a non-empty key — empty would shadow the OAuth token in the CLI.
[ -n "$KEY" ] && export ANTHROPIC_API_KEY="$KEY"
PROMPT="A reviewer asked for a change on this pull request (PR #${PR}). Apply it.

Reviewer request:
${INSTR}

${CONTEXT}

Current PR diff vs ${BASE_REF} (truncated):
\`\`\`diff
${DIFF}
\`\`\`

Make the requested change with minimal, focused edits. Add or update a test where it
makes sense. Do NOT use git. End with a 1-3 sentence summary of what you changed."

echo "::group::Agent (steering)"
RAW=$(claude -p "$PROMPT" --model "$MODEL" --permission-mode acceptEdits \
  --allowedTools "Edit,Write,Read,Bash,Grep,Glob" "${SYS_ARGS[@]}" 2>/dev/null) || echo "(agent run returned non-zero)"
SUMMARY=$(printf '%s\n' "$RAW" | tail -8)
echo "::endgroup::"

# GITHUB_TOKEN can't push .github/workflows changes — drop any the agent made.
if [ -n "$(git status --porcelain -- .github/workflows 2>/dev/null)" ]; then
  echo "steer: dropping .github/workflows changes — GITHUB_TOKEN can't push them"
  git checkout -- .github/workflows 2>/dev/null || true
  git clean -fdq .github/workflows 2>/dev/null || true
fi

if [ -z "$(git status --porcelain)" ]; then
  ghpost "issues/${PR}/comments" \
    "$(jq -n --arg b "🤖 MacroDeploy — no file changes were needed for: \"${INSTR}\"." '{body:$b}')"
  echo "steer: no changes"; exit 0
fi

git add -A
git commit -q -m "Address review: ${INSTR:0:60}"
git push "https://x-access-token:${GITHUB_TOKEN}@github.com/${GITHUB_REPOSITORY}.git" "HEAD:${HEAD_REF}"
ghpost "issues/${PR}/comments" \
  "$(jq -n --arg b "🤖 MacroDeploy applied your request — \"${INSTR}\"

${SUMMARY}" '{body:$b}')"
echo "steer: pushed change to ${HEAD_REF}"
