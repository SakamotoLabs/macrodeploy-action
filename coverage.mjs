// Test-coverage audit: run Claude Code over the repo to judge whether the code
// has sufficient unit and/or e2e test coverage, then post the gaps as a
// "MacroDeploy coverage" Check on the default-branch HEAD. Triggered by
// workflow_dispatch. Self-contained (only ANTHROPIC_API_KEY). Best-effort.
import { spawnSync } from "node:child_process";
import { readFileSync } from "node:fs";

const KEY = process.env.INPUT_ANTHROPIC_API_KEY || process.env.ANTHROPIC_API_KEY || "";
const MODEL = process.env.INPUT_MODEL || "claude-sonnet-4-6";
const TOKEN = process.env.GITHUB_TOKEN || "";
const REPO = process.env.GITHUB_REPOSITORY || "";
const SHA = process.env.GITHUB_SHA || "";

function bail(m) {
  console.log(`coverage: ${m}`);
  process.exit(0);
}
if (!TOKEN || !REPO || !SHA) bail("missing GitHub context");

async function postCheck(conclusion, summary) {
  await fetch(`https://api.github.com/repos/${REPO}/check-runs`, {
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
      conclusion,
      output: { title: "Test coverage audit", summary },
    }),
  }).catch(() => {});
}

// No key → post a clear "needs key" result instead of a silent green no-op.
if (!KEY) {
  await postCheck(
    "neutral",
    "⚠️ No `ANTHROPIC_API_KEY` is set on this repository, so the coverage audit couldn't run.\n\n" +
      "Add your Anthropic key — in MacroDeploy: **dashboard → Set key**; or on GitHub: **Settings → Secrets and variables → Actions → New secret `ANTHROPIC_API_KEY`** — then run the audit again.",
  );
  bail("no API key — posted needs-key check");
}

const PROMPT = `You are a senior engineer auditing this repository's automated test coverage. Read the source tree and the existing tests as needed.

Assess:
- which important modules, functions, branches, and error paths have NO unit tests,
- whether critical user-facing flows have any e2e/integration coverage,
- tests that are shallow (assert nothing meaningful, only happy path, over-mocked).

Identify the test framework(s) in use (jest, vitest, pytest, playwright, cypress, go test, etc.) and judge the OVERALL coverage posture.

Respond with ONLY JSON (no prose, no code fences):
{"summary":"<4-6 sentences: framework(s) found, rough coverage level (none/low/partial/good), and the biggest gaps>","grade":"none|low|partial|good","findings":[{"path":"<repo-relative source file that needs tests>","line":<int line of the untested function/area>,"level":"notice|warning|failure","comment":"<what is untested + what test to add>"}]}
Use "failure" only for critical untested logic (auth, payments, data mutations, security-sensitive paths). Point findings at the SOURCE file needing tests, not the test file. Empty findings array if coverage is genuinely good. Honor the repo's own CLAUDE.md / AGENTS.md conventions.${
  (() => {
    try {
      const m = readFileSync(".macrodeploy/memory.md", "utf8").slice(0, 6000);
      return m ? `\n\nThese were reviewed before and accepted as non-issues or intended — do NOT flag them again:\n${m}` : "";
    } catch {
      return "";
    }
  })()
}`;

// Inject the ea-core `coverage` rubric (where coverage matters, what counts as
// a real gap, weak-test smells, severity calibration) as the system prompt.
const SKILLS_DIR = process.env.MACRODEPLOY_SKILLS_DIR || "/usr/local/share/macrodeploy/skills";
let SYSTEM = (process.env.INPUT_SKILL || "").trim();
try {
  if (!SYSTEM) SYSTEM = readFileSync(`${SKILLS_DIR}/coverage.md`, "utf8");
} catch {
  /* no skill pack → default system prompt */
}

process.env.ANTHROPIC_API_KEY = KEY;
process.env.MAX_THINKING_TOKENS = process.env.MAX_THINKING_TOKENS || "8000"; // extended thinking
const res = spawnSync(
  "claude",
  ["-p", PROMPT, "--model", MODEL, "--permission-mode", "acceptEdits",
   "--allowedTools", "Read,Grep,Glob", "--output-format", "json",
   ...(SYSTEM ? ["--append-system-prompt", SYSTEM] : [])],
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
