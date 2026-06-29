#!/usr/bin/env bash
# Scoped test runner for the fix/implement red→green loop. Runs ONLY the test
# files that changed (the reproducing test the agent added + siblings it touched)
# — never the whole suite. The full suite runs once later as the pre-merge gate
# (verify.sh). This is the independent confirmation of the agent's self-report.
#
# run_changed_tests <base_ref>
#   echoes the files it ran; returns:
#     0 = scoped tests passed
#     1 = scoped tests failed
#     2 = indeterminate (no changed test files, or no runner could be determined)

run_changed_tests() {
  local base="$1"
  local files
  # --diff-filter=ACMR excludes DELETED (D) files — a fix that only removes a test
  # file must not pass the now-missing path to the runner (vitest then reports
  # "No test files found" and exits 1, which we'd wrongly read as a failure).
  files=$(git diff --name-only --diff-filter=ACMR "origin/${base}...HEAD" 2>/dev/null \
    | grep -Ei '(\.(test|spec)\.[jt]sx?$)|(_test\.py$)|((^|/)test_[^/]*\.py$)' || true)
  if [ -z "$files" ]; then
    echo "scoped-tests: no (surviving) changed test files — skipping scoped run"
    return 2
  fi
  echo "scoped-tests: running only —"
  echo "$files" | sed 's/^/  - /'

  # --passWithNoTests so a runner invoked on files that resolve to zero tests
  # exits 0 (a no-op), not 1 — "nothing to run" is not "tests failed".
  # shellcheck disable=SC2086
  if [ -f package.json ]; then
    if grep -qE '"vitest"' package.json; then
      npx --no-install vitest run --passWithNoTests $files; return $?
    elif grep -qE '"jest"' package.json; then
      npx --no-install jest --passWithNoTests $files; return $?
    fi
  fi
  if grep -qiE 'pytest' pyproject.toml requirements*.txt setup.cfg tox.ini 2>/dev/null \
     || command -v pytest >/dev/null 2>&1; then
    # shellcheck disable=SC2086
    python -m pytest $files; return $?
  fi

  echo "scoped-tests: could not determine a test runner — deferring to agent verdict"
  return 2
}
