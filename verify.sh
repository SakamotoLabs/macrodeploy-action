#!/usr/bin/env bash
# verify — auto-detect the stack and run typecheck, lint, tests, and build.
#
# Runs ALL applicable steps (does not stop at the first failure), prints a
# summary, and exits non-zero if any step failed.
#
# Override: if the repo defines its own canonical check, that wins —
#   an executable ./verify, a package.json "verify" script, or a Makefile
#   `verify:` target. Otherwise auto-detection runs.
#
# Usage: verify.sh [path]   (defaults to the current directory)

set -uo pipefail

ROOT="${1:-$PWD}"
cd "$ROOT" || { echo "verify: cannot cd to $ROOT" >&2; exit 2; }

c_bold=$'\033[1m'; c_dim=$'\033[2m'; c_red=$'\033[31m'; c_grn=$'\033[32m'; c_rst=$'\033[0m'
PASS=(); FAIL=(); SKIP=()

run()  { # run <label> <cmd...>
  local label="$1"; shift
  printf '\n%s▶ %s%s\n  %s$ %s%s\n' "$c_bold" "$label" "$c_rst" "$c_dim" "$*" "$c_rst"
  if "$@"; then PASS+=("$label"); printf '%s✓ %s%s\n' "$c_grn" "$label" "$c_rst"
  else FAIL+=("$label"); printf '%s✗ %s%s\n' "$c_red" "$label" "$c_rst"; fi
}
skip() { SKIP+=("$1"); printf '%s– skip %s (%s)%s\n' "$c_dim" "$1" "$2" "$c_rst"; }
has()  { command -v "$1" >/dev/null 2>&1; }

# ── Project-defined override wins ───────────────────────────────────────────
PM=""
if [ -f package.json ]; then
  if   [ -f pnpm-lock.yaml ]; then PM=pnpm
  elif [ -f yarn.lock ];      then PM=yarn
  elif [ -f bun.lockb ];      then PM=bun
  else PM=npm; fi
fi
node_script() { node -e "const s=(require('./package.json').scripts)||{};process.exit(s['$1']?0:1)" 2>/dev/null; }

if [ -x ./verify ]; then
  printf '%susing ./verify%s\n' "$c_dim" "$c_rst"; exec ./verify
fi
if [ -n "$PM" ] && node_script verify; then
  printf '%susing %s run verify%s\n' "$c_dim" "$PM" "$c_rst"; exec "$PM" run verify
fi
if has make && [ -f Makefile ] && grep -qE '^verify:' Makefile; then
  printf '%susing make verify%s\n' "$c_dim" "$c_rst"; exec make verify
fi

# ── Node / TypeScript ───────────────────────────────────────────────────────
if [ -n "$PM" ]; then
  printf '%sdetected: Node (%s)%s\n' "$c_dim" "$PM" "$c_rst"

  if node_script typecheck; then run "typecheck" "$PM" run typecheck
  elif [ -f tsconfig.json ]; then run "typecheck (tsc)" "$PM" exec tsc --noEmit
  else skip "typecheck" "no typecheck script / tsconfig"; fi

  if node_script lint; then run "lint" "$PM" run lint
  else skip "lint" "no lint script"; fi

  if node_script test; then
    if node -e "const t=((require('./package.json').scripts)||{}).test||'';process.exit(/no test specified/.test(t)?1:0)"; then
      run "test" "$PM" test
    else skip "test" "placeholder test script"; fi
  else skip "test" "no test script"; fi

  if [ -n "${VERIFY_FAST:-}" ]; then skip "build" "fast mode"
  elif node_script build; then run "build" "$PM" run build
  else skip "build" "no build script"; fi
fi

# ── Python ──────────────────────────────────────────────────────────────────
if [ -f pyproject.toml ] || [ -f setup.py ] || [ -f requirements.txt ]; then
  if [ -f poetry.lock ] && has poetry; then PY="poetry"; else PY=""; fi
  pyx()   { if [ -n "$PY" ]; then poetry run "$@"; else "$@"; fi; }
  pyhas() { pyx "$1" --version >/dev/null 2>&1; }
  printf '%sdetected: Python%s%s\n' "$c_dim" "${PY:+ (poetry)}" "$c_rst"

  if   pyhas ruff;   then run "ruff" pyx ruff check .
  elif pyhas flake8; then run "flake8" pyx flake8
  else skip "lint" "no ruff/flake8"; fi

  if pyhas mypy; then run "mypy" pyx mypy .; else skip "typecheck" "no mypy"; fi
  if pyhas pytest; then run "pytest" pyx pytest -q; else skip "test" "no pytest"; fi
fi

# ── Summary ─────────────────────────────────────────────────────────────────
total=$(( ${#PASS[@]} + ${#FAIL[@]} ))
printf '\n%s── verify summary ──%s\n' "$c_bold" "$c_rst"
for p in ${PASS[@]+"${PASS[@]}"}; do printf '  %s✓%s %s\n' "$c_grn" "$c_rst" "$p"; done
for s in ${SKIP[@]+"${SKIP[@]}"}; do printf '  %s–%s %s\n' "$c_dim" "$c_rst" "$s"; done
for f in ${FAIL[@]+"${FAIL[@]}"}; do printf '  %s✗%s %s\n' "$c_red" "$c_rst" "$f"; done

if [ "$total" -eq 0 ]; then
  printf '\n%sNo checks detected. Add a verify script, tsconfig, or tests.%s\n' "$c_dim" "$c_rst"
  exit 0
fi
if [ "${#FAIL[@]}" -gt 0 ]; then
  printf '\n%sVERIFY FAILED — %d step(s)%s\n' "$c_red" "${#FAIL[@]}" "$c_rst"
  exit 1
fi
printf '\n%sVERIFY PASSED — %d step(s)%s\n' "$c_grn" "$total" "$c_rst"
exit 0
