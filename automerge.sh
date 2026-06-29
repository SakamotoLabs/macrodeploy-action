#!/usr/bin/env bash
# Auto-merge eligibility + action. Sourced by implement.sh / fix.sh, called after
# the gate + review run. A PR is auto-merged ONLY when ALL hold:
#   (1) verify gate is green                      — objective correctness
#   (2) zero failure-level review findings        — no blocking issues
#   (3) diff touches no high-risk paths           — risk classifier (slice 3)
#   (4) diff includes a test for the change       — test-proof gate (slice 4)
# Otherwise the PR is left open, labeled "needs-human" with the reason.
# Gated by INPUT_AUTO_MERGE=true (the repo's Autonomy setting).

_am_api() {
  curl -s -H "Authorization: Bearer ${GITHUB_TOKEN}" -H "Accept: application/vnd.github+json" "$@"
}

_am_comment() {
  _am_api -X POST "https://api.github.com/repos/${GITHUB_REPOSITORY}/issues/${1}/comments" \
    -d "$(jq -n --arg b "$2" '{body:$b}')" >/dev/null 2>&1 || true
}

_am_escalate() {
  local pr="$1" reason="$2"
  _am_api -X POST "https://api.github.com/repos/${GITHUB_REPOSITORY}/issues/${pr}/labels" \
    -d '{"labels":["needs-human"]}' >/dev/null 2>&1 || true
  _am_comment "$pr" "### 🙋 Needs a human
Auto-merge held — ${reason}"
  echo "automerge: escalated #${pr} (${reason})"
}

# maybe_automerge <pr> <gate success|failure> <base ref> <head sha>
maybe_automerge() {
  local pr="$1" gate="$2" base="$3" head="$4"
  [ "${INPUT_AUTO_MERGE:-false}" = "true" ] || { echo "automerge: off"; return 0; }
  [ -z "$pr" ] && { echo "automerge: no PR number"; return 0; }

  # (1) gate
  if [ "$gate" != "success" ]; then _am_escalate "$pr" "the verify gate is red — fix the build/tests first."; return 0; fi

  # (4) a test must accompany the change
  local changed tests
  changed=$(git diff --name-only "origin/${base}...HEAD" 2>/dev/null)
  tests=$(echo "$changed" | grep -iE '(^|/)(tests?|__tests__|spec)/|\.(test|spec)\.|_test\.|test_.*\.py' | head -1)
  if [ -z "$tests" ]; then _am_escalate "$pr" "no test accompanies the change — auto-merge requires a test proving it."; return 0; fi

  # (3) risk classifier — high-blast-radius paths need a human
  local risky
  risky=$(echo "$changed" | grep -iE 'auth|login|password|secret|token|oauth|credential|payment|billing|stripe|charge|migration|alembic|/migrations/|\.env|/infra/|\.github/workflows/|security' | head -5)
  if [ -n "$risky" ]; then
    _am_escalate "$pr" "touches high-risk paths (needs human review):
$(echo "$risky" | sed 's/^/- /')"
    return 0
  fi

  # (2) no blocking review findings. Failures always block; warnings block too
  # when the repo opts into strict mode (MACRODEPLOY_BLOCK_WARNINGS / block_warnings).
  local cid fails=0 levels='.annotation_level=="failure"' label="failure"
  if [ "${INPUT_BLOCK_WARNINGS:-false}" = "true" ]; then
    levels='(.annotation_level=="failure" or .annotation_level=="warning")'
    label="warning/failure"
  fi
  cid=$(_am_api "https://api.github.com/repos/${GITHUB_REPOSITORY}/commits/${head}/check-runs" \
    | jq -r '.check_runs[] | select(.name=="MacroDeploy review") | .id' | head -1)
  if [ -n "$cid" ] && [ "$cid" != "null" ]; then
    fails=$(_am_api "https://api.github.com/repos/${GITHUB_REPOSITORY}/check-runs/${cid}/annotations" \
      | jq "[.[] | select(${levels})] | length")
  fi
  if [ "${fails:-0}" -gt 0 ]; then _am_escalate "$pr" "${fails} blocking (${label}) review finding(s) — address them first."; return 0; fi

  # Eligible → squash merge.
  local res
  res=$(_am_api -X PUT "https://api.github.com/repos/${GITHUB_REPOSITORY}/pulls/${pr}/merge" \
    -d '{"merge_method":"squash"}')
  if echo "$res" | jq -e '.merged==true' >/dev/null 2>&1; then
    _am_comment "$pr" "### 🤖 Auto-merged
Gate green ✓ · a test accompanies the change ✓ · no blocking findings ✓ · low-risk diff ✓ — merged automatically by MacroDeploy."
    echo "automerge: merged #${pr}"
  else
    _am_escalate "$pr" "ready to merge, but the merge call failed: $(echo "$res" | jq -r '.message // "unknown"') (branch protection?)."
  fi
}
