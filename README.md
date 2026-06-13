# macrodeploy-action

A GitHub Action that, on every pull request, runs your project's **verify gate**
(typecheck → lint → tests → build, auto-detected for Node and Python) and posts
an **AI review** of the diff. The engine ships inside the action image — nothing
is added to your repo beyond a small workflow file.

## Usage

Add `.github/workflows/macrodeploy.yml`:

```yaml
name: MacroDeploy
on:
  pull_request:
jobs:
  macrodeploy:
    runs-on: ubuntu-latest
    permissions:
      contents: read
      pull-requests: write      # for the review
      checks: write             # for the inline annotations
    steps:
      - uses: actions/checkout@v4
        with:
          fetch-depth: 0        # full history for the diff
      - uses: sakamotolabs/macrodeploy-action@v1
        with:
          anthropic_api_key: ${{ secrets.ANTHROPIC_API_KEY }}
```

Omit `anthropic_api_key` to run just the verify gate (no review).

## Audit a repo against a checklist (`mode: checklist`)

Define the features/tools you expect — in plain language — in
`.macrodeploy/checklist.md` (see [`examples/checklist.example.md`](examples/checklist.example.md)),
then add [`examples/macrodeploy-checklist.yml`](examples/macrodeploy-checklist.yml).
On each run the agent checks every item against the code (with `file:line`
evidence) and posts a **MacroDeploy Audit** check — `pass / partial / fail /
unknown` per item, plus a score. Add `gate: true` to the checklist to fail the
check when a high-severity item is missing.

## Inputs

| input | default | description |
|---|---|---|
| `anthropic_api_key` | — | Key for the AI review. Absent → review skipped, gate still runs. |
| `fast` | `false` | Skip the build step (typecheck + lint + tests only). |
| `review` | `true` | Post the AI review comment. |
| `model` | `claude-sonnet-4-6` | Model for the review. |
| `github_token` | workflow token | Token used to post the review comment. |

## How the gate is determined

Auto-detected per repo (Node via pnpm/yarn/npm, Python via poetry/pip). A project
can override with its own canonical check — an executable `./verify`, a
package.json `verify` script, or a `make verify` target — and that wins.

The verify gate's exit code is the check result; the AI review never fails CI on
its own.

## Issue→PR (optional)

Add `examples/macrodeploy-implement.yml` as a second workflow and an agent will
implement labeled issues: label any issue **`macrodeploy`** → it opens a PR that
implements the issue, which then runs through the gate + review above. Needs the
`ANTHROPIC_API_KEY` secret.
