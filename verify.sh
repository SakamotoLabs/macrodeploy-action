#!/usr/bin/env bash
# verify — auto-detect the stack and run typecheck, lint, tests, and build.
#
# Monorepo-aware: a project's manifest can live at the repo root OR in a
# subdirectory (e.g. frontend/ + backend/). We discover every package.json /
# pyproject.toml (up to 2 levels deep, excluding node_modules) and check each —
# so a broken frontend build can't slip through just because the root has no
# manifest. Node deps are installed on demand so `next build` / `tsc` can run.
#
# Runs ALL applicable steps (does not stop at the first failure), prints a
# summary, and exits non-zero if any step failed.
#
# Override: if the repo ROOT defines its own canonical check, that wins —
#   an executable ./verify, a package.json "verify" script, or a Makefile
#   `verify:` target. Otherwise auto-detection runs.
#
# Usage: verify.sh [path]   (defaults to the current directory)

set -uo pipefail

ROOT="${1:-$PWD}"
cd "$ROOT" || { echo "verify: cannot cd to $ROOT" >&2; exit 2; }
ROOT="$PWD"

c_bold=$'\033[1m'; c_dim=$'\033[2m'; c_red=$'\033[31m'; c_grn=$'\033[32m'; c_rst=$'\033[0m'
PASS=(); FAIL=(); SKIP=()

run()  { # run <label> <cmd...>  (executes in the current directory)
  local label="$1"; shift
  printf '\n%s▶ %s%s\n  %s$ %s%s\n' "$c_bold" "$label" "$c_rst" "$c_dim" "$*" "$c_rst"
  if "$@"; then PASS+=("$label"); printf '%s✓ %s%s\n' "$c_grn" "$label" "$c_rst"
  else FAIL+=("$label"); printf '%s✗ %s%s\n' "$c_red" "$label" "$c_rst"; fi
}
skip() { SKIP+=("$1"); printf '%s– skip %s (%s)%s\n' "$c_dim" "$1" "$2" "$c_rst"; }
has()  { command -v "$1" >/dev/null 2>&1; }
node_script() { node -e "const s=(require('./package.json').scripts)||{};process.exit(s['$1']?0:1)" 2>/dev/null; }

# ── Project-defined override wins (root only) ───────────────────────────────
ROOT_PM=""
if [ -f package.json ]; then
  if   [ -f pnpm-lock.yaml ]; then ROOT_PM=pnpm
  elif [ -f yarn.lock ];      then ROOT_PM=yarn
  elif [ -f bun.lockb ];      then ROOT_PM=bun
  else ROOT_PM=npm; fi
fi
if [ -x ./verify ]; then
  printf '%susing ./verify%s\n' "$c_dim" "$c_rst"; exec ./verify
fi
if [ -n "$ROOT_PM" ] && node_script verify; then
  printf '%susing %s run verify%s\n' "$c_dim" "$ROOT_PM" "$c_rst"; exec "$ROOT_PM" run verify
fi
if has make && [ -f Makefile ] && grep -qE '^verify:' Makefile; then
  printf '%susing make verify%s\n' "$c_dim" "$c_rst"; exec make verify
fi

# ── Per-directory checkers ──────────────────────────────────────────────────

check_node() { # check_node <dir>
  cd "$ROOT/$1" || return
  local rel="$1"; [ "$rel" = "." ] && rel="root"
  local PM
  if   [ -f pnpm-lock.yaml ]; then PM=pnpm
  elif [ -f yarn.lock ];      then PM=yarn
  elif [ -f bun.lockb ];      then PM=bun
  else PM=npm; fi
  printf '%sdetected: Node in %s (%s)%s\n' "$c_dim" "$rel" "$PM" "$c_rst"

  # `next build` / `tsc` need node_modules — install if absent so the gate can
  # actually compile (this is what catches missing imports + type errors).
  if [ ! -d node_modules ]; then
    printf '%sinstalling deps in %s…%s\n' "$c_dim" "$rel" "$c_rst"
    case "$PM" in
      pnpm) pnpm install --frozen-lockfile || pnpm install ;;
      yarn) yarn install --frozen-lockfile || yarn install ;;
      bun)  bun install ;;
      *)    npm ci || npm install ;;
    esac
  fi

  if node_script typecheck; then run "[$rel] typecheck" "$PM" run typecheck
  elif [ -f tsconfig.json ]; then run "[$rel] typecheck (tsc)" "$PM" exec tsc --noEmit
  else skip "[$rel] typecheck" "no typecheck script / tsconfig"; fi

  if node_script lint; then run "[$rel] lint" "$PM" run lint
  else skip "[$rel] lint" "no lint script"; fi

  if node_script test; then
    if node -e "const t=((require('./package.json').scripts)||{}).test||'';process.exit(/no test specified/.test(t)?1:0)"; then
      run "[$rel] test" "$PM" test
    else skip "[$rel] test" "placeholder test script"; fi
  else skip "[$rel] test" "no test script"; fi

  if [ -n "${VERIFY_FAST:-}" ]; then skip "[$rel] build" "fast mode"
  elif node_script build; then run "[$rel] build" "$PM" run build
  else skip "[$rel] build" "no build script"; fi

  cd "$ROOT"
}

check_python() { # check_python <dir>
  cd "$ROOT/$1" || return
  local rel="$1"; [ "$rel" = "." ] && rel="root"
  local PY=""; if [ -f poetry.lock ] && has poetry; then PY="poetry"; fi
  pyx()   { if [ -n "$PY" ]; then poetry run "$@"; else "$@"; fi; }
  pyhas() { pyx "$1" --version >/dev/null 2>&1; }
  printf '%sdetected: Python in %s%s%s\n' "$c_dim" "$rel" "${PY:+ (poetry)}" "$c_rst"

  if   pyhas ruff;   then run "[$rel] ruff" pyx ruff check .
  elif pyhas flake8; then run "[$rel] flake8" pyx flake8
  else skip "[$rel] lint" "no ruff/flake8"; fi

  if pyhas mypy;   then run "[$rel] mypy" pyx mypy .; else skip "[$rel] typecheck" "no mypy"; fi
  if pyhas pytest; then run "[$rel] pytest" pyx pytest -q; else skip "[$rel] test" "no pytest"; fi

  cd "$ROOT"
}

# ── Discover project dirs (root + one level down) ───────────────────────────
# Relative dirs containing a Node / Python manifest, node_modules excluded.
mapfile -t NODE_DIRS < <(
  find . -maxdepth 2 -name package.json -not -path '*/node_modules/*' \
    -exec dirname {} \; 2>/dev/null | sed 's#^\./##' | sort -u
)
mapfile -t PY_DIRS < <(
  find . -maxdepth 2 \( -name pyproject.toml -o -name setup.py -o -name requirements.txt \) \
    -not -path '*/node_modules/*' -exec dirname {} \; 2>/dev/null | sed 's#^\./##' | sort -u
)

for d in ${NODE_DIRS[@]+"${NODE_DIRS[@]}"}; do check_node "$d"; done
for d in ${PY_DIRS[@]+"${PY_DIRS[@]}"};   do check_python "$d"; done

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
