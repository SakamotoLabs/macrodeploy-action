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
      pull-requests: write      # for the review comment
    steps:
      - uses: actions/checkout@v4
        with:
          fetch-depth: 0        # full history for the diff
      - uses: sakamotolabs/macrodeploy-action@v1
        with:
          anthropic_api_key: ${{ secrets.ANTHROPIC_API_KEY }}
```

Omit `anthropic_api_key` to run just the verify gate (no review).

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
