# MacroDeploy audit checklist — copy to .macrodeploy/checklist.md and edit.
#
# One feature/tool per line, in plain language. Add "(severity: high|medium|low)"
# to any item. Add a top-level "gate: true" to FAIL the audit check when any
# high-severity item is missing (turns it into a PR/merge gate); default is
# report-only.

gate: false

## Engineering & CI
- CI runs tests on every pull request (severity: high)
- Linter and formatter are configured and enforced
- Type checking is enabled (strict)
- Lockfile is committed and dependency versions are pinned
- README documents setup, run, and deploy steps

## Security
- No secrets, tokens, or private keys are committed to the repo (severity: high)
- Authentication is enforced on all non-public endpoints (severity: high)
- User input is validated/sanitized at every boundary
- Dependency vulnerability scanning is enabled (Dependabot/Snyk/CodeQL)

## Ops
- Dockerfile (or other reproducible build) is present
- Health-check endpoint exists
- Structured logging and error tracking are wired

## Product features (list what THIS repo should implement)
- Rate limiting on the public API
- Role-based access control on routes
- Database migrations are versioned
- Background job / queue processing
