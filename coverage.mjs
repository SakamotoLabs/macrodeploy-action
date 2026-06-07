// Test-coverage audit: run Claude Code over the repo to judge whether the code
// has sufficient unit and/or e2e test coverage, then post the gaps as a
// "MacroDeploy coverage" Check on the default-branch HEAD. Triggered by
// workflow_dispatch. Self-contained (only ANTHROPIC_API_KEY). Best-effort.
import { spawnSync } from "node:child_process";

const KEY = process.env.INPUT_ANTHROPIC_API_KEY || process.env.ANTHROPIC_API_KEY || "";
const MODEL = process.env.INPUT_MODEL || "claude-sonnet-4-6";
const TOKEN = process.env.GITHUB_TOKEN || "";
const REPO = process.env.GITHUB_REPOSITORY || "";
const SHA = process.env.GITHUB_SHA || "";

function bail(m) {
  console.log(`coverage: ${m}`);
  process.exit(0);
}
if (!KEY) bail("no API key");
if (!TOKEN || !REPO || !SHA) bail("missing GitHub context");

const PROMPT = `You are a senior engineer auditing this repository's automated test coverage. Read the source tree and the existing tests as needed.

Assess:
- which important modules, functions, branches, and error paths have NO unit tests,
- whether critical user-facing flows have any e2e/integration coverage,
- tests that are shallow (assert nothing meaningful, only happy path, over-mocked).

Identify the test framework(s) in use (jest, vitest, pytest, playwright, cypress, go test, etc.) and judge the OVERALL coverage posture.

Respond with ONLY JSON (no prose, no code fences):
{"summary":"<4-6 sentences: framework(s) found, rough coverage level (none/low/partial/good), and the biggest gaps>","grade":"none|low|partial|good","findings":[{"path":"<repo-relative source file that needs tests>","line":<int line of the untested function/area>,"level":"notice|warning|failure","comment":"<what is untested + what test to add>"}]}
Use "failure" only for critical untested logic (auth, payments, data mutations, security-sensitive paths). Point findings at the SOURCE file needing tests, not the test file. Empty findings array if coverage is genuinely good.`;

process.env.ANTHROPIC_API_KEY = KEY;
const res = spawnSync(
  "claude",
  ["-p", PROMPT, "--model", MODEL, "--permission-mode", "acceptEdits",
   "--allowedTools", "Read,Grep,Glob", "--output-format", "json"],
  { encoding: "utf8", maxBuffer: 64 * 1024 * 1024 },
);
const rawOut = (res.stdout || "") + "";

// claude --output-format json → { result: "<assistant text>", ... }
let text = rawOut;
try {
  const env = JSON.parse(rawOut);
  text = env.result || env.text || rawOut;
} catch {
  /* not enveloped */
}
let audit = { summary: "Audit produced no parseable output.", grade: "", findings: [] };
const s = text.indexOf("{");
const e = text.lastIndexOf("}");
if (s >= 0 && e > s) {
  try {
    audit = JSON.parse(text.slice(s, e + 1));
  } catch {
    audit = { summary: text.slice(0, 800), grade: "", findings: [] };
  }
}

const findings = Array.isArray(audit.findings) ? audit.findings : [];
const annotations = findings
  .filter((f) => f && f.path && f.line)
  .slice(0, 50)
  .map((f) => ({
    path: f.path,
    start_line: f.line,
    end_line: f.line,
    annotation_level: ["notice", "warning", "failure"].includes(f.level) ? f.level : "warning",
    message: f.comment || "Needs test coverage.",
  }));

const hasCritical = annotations.some((a) => a.annotation_level === "failure");
const grade = audit.grade ? `\n\n**Coverage grade: ${audit.grade}.**` : "";
const summary =
  (audit.summary || "Coverage audit complete.") +
  grade +
  (annotations.length ? `\n\n**${annotations.length} file(s) need tests.**` : "\n\nNo significant gaps found.");

const r = await fetch(`https://api.github.com/repos/${REPO}/check-runs`, {
  method: "POST",
  headers: {
    authorization: `Bearer ${TOKEN}`,
    accept: "application/vnd.github+json",
    "content-type": "application/json",
  },
  body: JSON.stringify({
    name: "MacroDeploy coverage",
    head_sha: SHA,
    status: "completed",
    conclusion: hasCritical ? "neutral" : "success",
    output: { title: "Test coverage audit", summary, annotations },
  }),
});
console.log(
  r.ok
    ? `coverage: posted audit with ${annotations.length} finding(s)`
    : `coverage: check POST failed (${r.status}) ${await r.text()}`,
);
