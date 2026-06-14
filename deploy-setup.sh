#!/usr/bin/env bash
# Deploy-setup mode: generate a tailored "deploy on merge" GitHub Actions workflow
# for this repo (gated by the MACRODEPLOY_AUTO_DEPLOY repo variable so the
# dashboard toggle controls it), then open a PR so the user reviews it before it's
# active. The PR body lists the exact secrets they must add. Triggered by
# workflow_dispatch. Self-contained (only ANTHROPIC_API_KEY).
set -uo pipefail

cd "${GITHUB_WORKSPACE:-/github/workspace}" || { echo "no workspace"; exit 1; }

KEY="${INPUT_ANTHROPIC_API_KEY:-}"
MODEL="${INPUT_MODEL:-claude-sonnet-4-6}"
# Accept a Claude Pro/Max OAuth token (exported by entrypoint.sh) as well as an
# API key — Claude Code picks up either from the environment.
if [ -z "$KEY" ] && [ -z "${CLAUDE_CODE_OAUTH_TOKEN:-}" ]; then
  echo "deploy-setup: no ANTHROPIC_API_KEY or CLAUDE_CODE_OAUTH_TOKEN"; exit 1
fi

git config --global --add safe.directory "$PWD" 2>/dev/null || true
api() { curl -s -H "Authorization: Bearer ${GITHUB_TOKEN}" -H "Accept: application/vnd.github+json" "$@"; }

DEFAULT=$(api "https://api.github.com/repos/${GITHUB_REPOSITORY}" | jq -r '.default_branch // "main"')
[ -z "$DEFAULT" ] || [ "$DEFAULT" = "null" ] && DEFAULT=main

# Deployment rubric as context so the agent understands platforms/secrets.
SYS_ARGS=()
[ -f /usr/local/share/macrodeploy/skills/deploy-audit.md ] \
  && SYS_ARGS=(--append-system-prompt "$(cat /usr/local/share/macrodeploy/skills/deploy-audit.md)")

echo "::group::Agent (Claude Code) — generating deploy workflow"
# Only export a non-empty key — empty would shadow the OAuth token in the CLI.
[ -n "$KEY" ] && export ANTHROPIC_API_KEY="$KEY"
export MAX_THINKING_TOKENS="${MAX_THINKING_TOKENS:-8000}"
PROMPT="Create exactly ONE file: .github/workflows/macrodeploy-deploy.yml — a GitHub Actions workflow that deploys THIS app to its platform when commits land on the default branch ('${DEFAULT}'), i.e. after a PR merges.

Requirements:
- Trigger on push to '${DEFAULT}'.
- The deploy job MUST be gated so a dashboard toggle controls it: add
    if: \${{ vars.MACRODEPLOY_AUTO_DEPLOY == 'true' }}
  on the job. (Until the user flips it on, the workflow is a no-op.)
- Use the repo's EXISTING deploy mechanism — read deploy.sh, infra/cloudbuild.yaml, vercel.json, fly.toml, render.yaml, Procfile, package.json, etc., and invoke that. Don't invent a new deploy path if one exists.
- All credentials come from GitHub Actions secrets (\${{ secrets.NAME }}) — NEVER hardcode. Use the platform's standard auth where applicable (e.g. google-github-actions/auth for GCP/Cloud Run, superfly/flyctl-actions for Fly, the Vercel CLI/action for Vercel).
- If this app ALREADY auto-deploys via a platform's native git integration (e.g. Vercel/Netlify connected to GitHub), DO NOT create a workflow — instead explain that in your summary and create no file.

Do NOT modify any other files. Do NOT use git and do NOT open a pull request — only create that one workflow file.

End your reply with a short summary of what the workflow does, then a checklist titled 'Secrets to add' listing the EXACT secret names the user must add (GitHub → Settings → Secrets and variables → Actions), one line each on how to obtain it."

SUMMARY=$(claude -p "$PROMPT" --model "$MODEL" --permission-mode acceptEdits \
  --allowedTools "Edit,Write,Read,Grep,Glob,Bash" "${SYS_ARGS[@]}" 2>/dev/null) || echo "(agent run returned non-zero)"
echo "$SUMMARY"
echo "::endgroup::"

WF=".github/workflows/macrodeploy-deploy.yml"
if [ -z "$(git status --porcelain "$WF")" ]; then
  # No workflow created (e.g. platform already auto-deploys) — report via a check.
  SHA=$(git rev-parse HEAD)
  api -X POST "https://api.github.com/repos/${GITHUB_REPOSITORY}/check-runs" \
    -d "$(jq -n --arg s "$SHA" --arg b "### 🚀 MacroDeploy — auto-deploy setup

No deploy workflow was created. Reason / next steps:

${SUMMARY:-(no detail)}" '{name:"MacroDeploy deploy setup", head_sha:$s, status:"completed", conclusion:"neutral", output:{title:"Auto-deploy setup", summary:$b}}')" >/dev/null || true
  echo "deploy-setup: no workflow created — posted a check"
  exit 0
fi

BRANCH="macrodeploy/auto-deploy"
git config user.name "macrodeploy[bot]"
git config user.email "macrodeploy@users.noreply.github.com"
git checkout -b "$BRANCH" 2>/dev/null || git checkout "$BRANCH"
git add "$WF"
git commit -q -m "Add auto-deploy-on-merge workflow (gated by MACRODEPLOY_AUTO_DEPLOY)"
git push -f "https://x-access-token:${GITHUB_TOKEN}@github.com/${GITHUB_REPOSITORY}.git" "HEAD:${BRANCH}"

PR_BODY="Sets up **deploy on merge** for this repo — opened by MacroDeploy.

${SUMMARY:-(see the workflow file)}

---
**To turn it on:**
1. Review & merge this PR.
2. Add the secrets listed above (GitHub → Settings → Secrets and variables → Actions).
3. In MacroDeploy: **Settings → Autonomy → Auto-deploy on merge → ON**.

The deploy job is gated by \`vars.MACRODEPLOY_AUTO_DEPLOY\`, so nothing deploys until you flip that toggle on."

PR_RESP=$(api -X POST "https://api.github.com/repos/${GITHUB_REPOSITORY}/pulls" \
  -d "$(jq -n --arg t "Set up auto-deploy on merge" --arg h "$BRANCH" --arg b "$DEFAULT" --arg body "$PR_BODY" \
    '{title:$t, head:$h, base:$b, body:$body}')")
echo "$PR_RESP" | jq -r '.html_url // ("PR create failed: " + (.message // "unknown"))'
echo "deploy-setup: opened PR"
