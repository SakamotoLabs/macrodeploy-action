#!/usr/bin/env bash
# autofix — run safe, SCOPED auto-fixers on the files the agent just changed, so
# trivial lint/format issues (unused imports, formatting) are corrected IN the
# agent's commit instead of tripping the verify gate. This mirrors what a human's
# format-on-save does, which the agent otherwise lacks.
#
# Scoped to the changed files only — never reformats the whole repo (that would
# create huge unrelated diffs). Safe fixes only (ruff's default --fix; no unsafe
# rewrites). Best-effort: every step is optional and the script always exits 0, so
# it can never block the pipeline. The verify gate still runs afterwards and is
# the real arbiter.
#
# Usage: autofix.sh [path]   (defaults to the current directory). Stages its
# results with `git add -A`; the caller commits.
set -uo pipefail
ROOT="${1:-$PWD}"; cd "$ROOT" 2>/dev/null || exit 0
c_dim=$'\033[2m'; c_rst=$'\033[0m'
note() { printf '%sautofix: %s%s\n' "$c_dim" "$1" "$c_rst"; }
has()  { command -v "$1" >/dev/null 2>&1; }

# Stage the agent's work so we can enumerate exactly what changed (added/copied/
# modified/renamed — not deletions).
git add -A 2>/dev/null || exit 0
mapfile -t CHANGED < <(git diff --cached --name-only --diff-filter=ACMR 2>/dev/null)
[ "${#CHANGED[@]}" -eq 0 ] && { note "no changes"; exit 0; }

# ── Python: ruff lint --fix + format, scoped to changed .py files ──────────────
mapfile -t PY < <(printf '%s\n' "${CHANGED[@]}" | grep -E '\.py$' || true)
if [ "${#PY[@]}" -gt 0 ]; then
  if ! has ruff; then
    note "installing ruff…"
    pip3 install --quiet --break-system-packages ruff >/dev/null 2>&1 \
      || pip3 install --quiet ruff >/dev/null 2>&1 || true
  fi
  if has ruff; then
    note "ruff --fix + format on ${#PY[@]} changed file(s)"
    # --exit-zero: applying safe fixes is best-effort; remaining issues are the
    # verify gate's job to report, not autofix's to fail on.
    ruff check --fix --exit-zero "${PY[@]}" >/dev/null 2>&1 || true
    ruff format "${PY[@]}" >/dev/null 2>&1 || true
  else
    note "ruff unavailable — skipped Python autofix"
  fi
fi

# ── Node: prettier + eslint --fix, scoped to changed files (repo tooling only) ─
# Uses the repo's own prettier/eslint via `npx --no-install` so we honor its
# config and never pull tools it didn't choose. Skips silently if absent or if
# deps aren't installed yet at this stage.
if [ -f package.json ]; then
  mapfile -t WEB < <(printf '%s\n' "${CHANGED[@]}" | grep -E '\.(js|jsx|ts|tsx|mjs|cjs|json|css|scss|md|mdx|ya?ml)$' || true)
  if [ "${#WEB[@]}" -gt 0 ] && npx --no-install prettier --version >/dev/null 2>&1; then
    note "prettier --write on ${#WEB[@]} changed file(s)"
    npx --no-install prettier --write "${WEB[@]}" >/dev/null 2>&1 || true
  fi
  mapfile -t JS < <(printf '%s\n' "${CHANGED[@]}" | grep -E '\.(js|jsx|ts|tsx|mjs|cjs)$' || true)
  if [ "${#JS[@]}" -gt 0 ] && npx --no-install eslint --version >/dev/null 2>&1; then
    note "eslint --fix on ${#JS[@]} changed file(s)"
    npx --no-install eslint --fix "${JS[@]}" >/dev/null 2>&1 || true
  fi
fi

git add -A 2>/dev/null || true
note "done"
exit 0
