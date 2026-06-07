// Security audit: run Claude Code over the repo, then post the findings as a
// "MacroDeploy security" Check on the default-branch HEAD. Triggered by
// workflow_dispatch. Self-contained (only ANTHROPIC_API_KEY). Best-effort.
import { spawnSync } from "node:child_process";
import { readFileSync } from "node:fs";

const KEY = process.env.INPUT_ANTHROPIC_API_KEY || process.env.ANTHROPIC_API_KEY || "";
const MODEL = process.env.INPUT_MODEL || "claude-sonnet-4-6";
const TOKEN = process.env.GITHUB_TOKEN || "";
const REPO = process.env.GITHUB_REPOSITORY || "";
const SHA = process.env.GITHUB_SHA || "";

function bail(m) {
  console.log(`security: ${m}`);
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
      name: "MacroDeploy security",
      head_sha: SHA,
      status: "completed",
      conclusion,
      output: { title: "Security audit", summary },
    }),
  }).catch(() => {});
}

// No key → post a clear "needs key" result instead of a silent green no-op.
if (!KEY) {
  await postCheck(
    "neutral",
    "⚠️ No `ANTHROPIC_API_KEY` is set on this repository, so the security audit couldn't run.\n\n" +
      "Add your Anthropic key — in MacroDeploy: **dashboard → Set key**; or on GitHub: **Settings → Secrets and variables → Actions → New secret `ANTHROPIC_API_KEY`** — then run the audit again.",
  );
  bail("no API key — posted needs-key check");
}

const PROMPT = `Audit this repository for security vulnerabilities — injection (SQL/command), broken authn/authz, hardcoded secrets, SSRF, path traversal, unsafe deserialization, missing input validation, and risky dependencies. Read the source as needed. Respond with ONLY JSON (no prose, no code fences):
{"summary":"<3-5 sentence overall security posture>","findings":[{"path":"<repo-relative file>","line":<int>,"level":"notice|warning|failure","comment":"<issue + fix>"}]}
Use "failure" only for exploitable issues. Empty findings array if the code looks secure.`;

// Inject the ea-core `security-review` rubric (attack surfaces, severity
// calibration, red flags, confidence bar) as the system prompt, so the cloud
// audit holds the same standard a local Claude Code session would.
const SKILLS_DIR = process.env.MACRODEPLOY_SKILLS_DIR || "/usr/local/share/macrodeploy/skills";
let SYSTEM = "";
try {
  SYSTEM = readFileSync(`${SKILLS_DIR}/security-review.md`, "utf8");
} catch {
  /* no skill pack → default system prompt */
}

process.env.ANTHROPIC_API_KEY = KEY;
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
let audit = { summary: "Audit produced no parseable output.", findings: [] };
const s = text.indexOf("{");
const e = text.lastIndexOf("}");
if (s >= 0 && e > s) {
  try {
    audit = JSON.parse(text.slice(s, e + 1));
  } catch {
    audit = { summary: text.slice(0, 800), findings: [] };
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
    message: f.comment || "Security finding.",
  }));

const hasCritical = annotations.some((a) => a.annotation_level === "failure");
const summary =
  (audit.summary || "Security audit complete.") +
  (annotations.length ? `\n\n**${annotations.length} finding(s).**` : "\n\nNo issues found.");

const r = await fetch(`https://api.github.com/repos/${REPO}/check-runs`, {
  method: "POST",
  headers: {
    authorization: `Bearer ${TOKEN}`,
    accept: "application/vnd.github+json",
    "content-type": "application/json",
  },
  body: JSON.stringify({
    name: "MacroDeploy security",
    head_sha: SHA,
    status: "completed",
    conclusion: hasCritical ? "neutral" : "success",
    output: { title: "Security audit", summary, annotations },
  }),
});
console.log(
  r.ok
    ? `security: posted audit with ${annotations.length} finding(s)`
    : `security: check POST failed (${r.status}) ${await r.text()}`,
);
