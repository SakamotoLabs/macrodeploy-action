#!/usr/bin/env bash
# Emits a compact "repository context" markdown block for the implement/fix/steer
# agent — the cheap, deterministic equivalent of a codebase wiki + an in-flight
# changes view. Four sections, each best-effort (missing data just omits it):
#   1. Project layout (so the agent follows existing structure)
#   2. Stack & test/build commands
#   3. EXISTING DB migrations — the #1 cross-run collision source
#   4. OTHER OPEN PRs + their changed files — so parallel agents don't pick the
#      same migration id or stomp the same files (this is what would have caught
#      five PRs each authoring a "0035_*" migration off the same base)
# Output goes to stdout; callers splice it into the agent prompt.
set -uo pipefail

SELF_BRANCH="${1:-}"   # current PR/issue branch, excluded from the in-flight list
emit() { printf '%s\n' "$*"; }

emit "## Repository context — READ THIS before making changes"
emit ""

# --- 1. Layout (top 2 dir levels, noise pruned) ---
emit "### Project layout"
emit '```'
find . -maxdepth 2 -type d \
  \( -name node_modules -o -name .git -o -name .next -o -name dist -o -name build \
     -o -name __pycache__ -o -name .venv -o -name .turbo -o -name '.*_cache' \) -prune \
  -o -type d -print 2>/dev/null | sed 's|^\./||' | grep -vE '^\.?$' | sort | head -50
emit '```'
emit ""

# --- 2. Stack & how to test/build ---
emit "### Stack & how to test/build"
while IFS= read -r pf; do
  [ -z "$pf" ] && continue
  scripts=$(jq -r '.scripts // {} | keys | join(", ")' "$pf" 2>/dev/null)
  emit "- ${pf#./}: npm scripts → ${scripts:-none}"
done < <(find . -maxdepth 2 -name package.json -not -path '*/node_modules/*' 2>/dev/null | head -4)
while IFS= read -r py; do
  [ -z "$py" ] && continue
  emit "- ${py#./}: python/poetry project"
done < <(find . -maxdepth 2 -name pyproject.toml -not -path '*/node_modules/*' 2>/dev/null | head -4)
emit ""

# --- 3. Existing DB migrations — NEVER reuse a revision id/number ---
MIG_DIRS=$(find . -maxdepth 5 -type d \( -name versions -o -name migrations \) \
  -not -path '*/node_modules/*' 2>/dev/null | head -4)
if [ -n "$MIG_DIRS" ]; then
  emit "### Existing DB migrations"
  emit "Pick the NEXT free revision id; do NOT reuse a number/id below, and chain"
  emit "your migration onto the current head (check both these AND the open PRs)."
  while IFS= read -r d; do
    [ -z "$d" ] && continue
    emit "- ${d#./} (most recent):"
    ls -1 "$d" 2>/dev/null | grep -vE '__init__|__pycache__|README|\.pyc|^env\.py$' | sort | tail -6 \
      | sed 's/^/    - /'
  done <<< "$MIG_DIRS"
  emit ""
fi

# --- 4. Other OPEN pull requests + their files (in-flight collision guard) ---
if [ -n "${GITHUB_TOKEN:-}" ] && [ -n "${GITHUB_REPOSITORY:-}" ]; then
  api() {
    curl -s -H "Authorization: Bearer ${GITHUB_TOKEN}" \
      -H "Accept: application/vnd.github+json" \
      "https://api.github.com/repos/${GITHUB_REPOSITORY}$1" 2>/dev/null
  }
  prs=$(api "/pulls?state=open&per_page=30" | jq -c '[.[] | {n:.number, t:.title, ref:.head.ref}]' 2>/dev/null)
  if [ -n "$prs" ] && [ "$prs" != "null" ] && [ "$prs" != "[]" ]; then
    emit "### Other OPEN pull requests — do NOT collide with their files"
    emit "These changes aren't merged yet but are in flight. Avoid duplicating their"
    emit "new files (especially migration ids) and coordinate around shared files."
    while IFS= read -r row; do
      [ -z "$row" ] && continue
      n=$(printf '%s' "$row" | jq -r '.n' 2>/dev/null)
      t=$(printf '%s' "$row" | jq -r '.t' 2>/dev/null)
      ref=$(printf '%s' "$row" | jq -r '.ref' 2>/dev/null)
      [ "$ref" = "$SELF_BRANCH" ] && continue
      files=$(api "/pulls/${n}/files?per_page=100" | jq -r '[.[].filename] | join(", ")' 2>/dev/null)
      emit "- PR #${n} (${t}) — touches: ${files:-?}"
    done < <(printf '%s' "$prs" | jq -c '.[]' 2>/dev/null)
    emit ""
  fi
fi
