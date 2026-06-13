// Deployment audit: run Claude Code over the repo to figure out HOW this app is
// (or should be) deployed, and post a plain-language report as a "MacroDeploy
// deploy audit" Check on the default-branch HEAD. Triggered by workflow_dispatch.
// Self-contained (only ANTHROPIC_API_KEY). Best-effort, read-only.
import { spawnSync } from "node:child_process";
import { readFileSync } from "node:fs";

const KEY = process.env.INPUT_ANTHROPIC_API_KEY || process.env.ANTHROPIC_API_KEY || "";
const MODEL = process.env.INPUT_MODEL || "claude-sonnet-4-6";
const TOKEN = process.env.GITHUB_TOKEN || "";
const REPO = process.env.GITHUB_REPOSITORY || "";
const SHA = process.env.GITHUB_SHA || "";

function bail(m) {
  console.log(`deploy-audit: ${m}`);
  process.exit(0);
}
if (!TOKEN || !REPO || !SHA) bail("missing GitHub context");

async function postCheck(conclusion, summary, annotations = []) {
  const r = await fetch(`https://api.github.com/repos/${REPO}/check-runs`, {
    method: "POST",
    headers: {
      authorization: `Bearer ${TOKEN}`,
      accept: "application/vnd.github+json",
      "content-type": "application/json",
    },
    body: JSON.stringify({
      name: "MacroDeploy deploy audit",
      head_sha: SHA,
      status: "completed",
      conclusion,
      output: { title: "Deployment audit", summary, annotations },
    }),
  }).catch(() => null);
  return r;
}

if (!KEY) {
  await postCheck(
    "neutral",
    "⚠️ No `ANTHROPIC_API_KEY` is set on this repository, so the deployment audit couldn't run.\n\n" +
      "Add your Anthropic key — in MacroDeploy: **dashboard → Set key** — then run the audit again.",
  );
  bail("no API key — posted needs-key check");
}

const PROMPT = `You are a deployment engineer auditing this repository to explain, in plain language a non-technical "vibecoder" can follow, HOW this app is deployed (or should be). Read the repo as needed: package.json/pyproject scripts, Dockerfile, deploy scripts (deploy.sh etc.), CI/CD under .github/workflows, and platform configs (vercel.json, fly.toml, render.yaml, app.yaml, cloudbuild.yaml, Procfile, netlify.toml, railway.json, etc.). Detect the framework/stack, the current deployment method, and the target platform.

Respond with ONLY JSON (no prose, no code fences):
{"summary":"<a clear, friendly markdown report: ## Stack, ## How it deploys today, ## Recommended way to deploy (numbered steps tailored to THIS repo), ## To set up auto-deploy on merge (what a GitHub Actions deploy workflow would need, incl. which secrets). Use plain language; spell out commands.>",
 "platform":"<best guess: Vercel|Netlify|Cloud Run|Fly.io|Railway|Render|Heroku|AWS|none-detected|other>",
 "method":"<one line: e.g. 'manual ./deploy.sh to Cloud Run', 'auto on push via Vercel', 'none found'>",
 "findings":[{"path":"<repo-relative file or '-'>","line":<int or 1>,"level":"notice|warning|failure","comment":"<a concrete gap or risk in the deployment setup + how to fix it>"}]}

Use "failure" for things that would block or break a deploy (no build script, secrets committed, broken Dockerfile), "warning" for missing CI/CD or undocumented env/secrets, "notice" for nice-to-haves. Empty findings array if deployment is already solid. Honor the repo's CLAUDE.md / AGENTS.md.`;

const SKILLS_DIR = process.env.MACRODEPLOY_SKILLS_DIR || "/usr/local/share/macrodeploy/skills";
let SYSTEM = (process.env.INPUT_SKILL || "").trim();
try {
  if (!SYSTEM) SYSTEM = readFileSync(`${SKILLS_DIR}/deploy-audit.md`, "utf8");
} catch {
  /* no skill pack → default system prompt */
}

process.env.ANTHROPIC_API_KEY = KEY;
process.env.MAX_THINKING_TOKENS = process.env.MAX_THINKING_TOKENS || "8000";
const res = spawnSync(
  "claude",
  ["-p", PROMPT, "--model", MODEL, "--permission-mode", "acceptEdits",
   "--allowedTools", "Read,Grep,Glob", "--output-format", "json",
   ...(SYSTEM ? ["--append-system-prompt", SYSTEM] : [])],
  { encoding: "utf8", maxBuffer: 64 * 1024 * 1024 },
);

let text = (res.stdout || "") + "";
try {
  const env = JSON.parse(text);
  text = env.result || env.text || text;
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
    audit = { summary: text.slice(0, 1500), findings: [] };
  }
}

const findings = Array.isArray(audit.findings) ? audit.findings : [];
const annotations = findings
  .filter((f) => f && f.path && f.path !== "-" && f.line)
  .slice(0, 50)
  .map((f) => ({
    path: f.path,
    start_line: f.line,
    end_line: f.line,
    annotation_level: ["notice", "warning", "failure"].includes(f.level) ? f.level : "warning",
    message: f.comment || "Deployment finding.",
  }));

// Findings without a real file path (e.g. "no CI/CD") still belong in the report.
const orphan = findings
  .filter((f) => f && (!f.path || f.path === "-" || !f.line))
  .map((f) => `- _[${f.level || "warning"}]_ ${f.comment || ""}`);

const header = [
  audit.platform ? `**Platform:** ${audit.platform}` : "",
  audit.method ? `**Current method:** ${audit.method}` : "",
].filter(Boolean).join(" · ");

const summary =
  (header ? header + "\n\n" : "") +
  (audit.summary || "Deployment audit complete.") +
  (orphan.length ? `\n\n**Gaps:**\n${orphan.join("\n")}` : "") +
  (annotations.length ? `\n\n**${annotations.length} inline finding(s).**` : "");

const hasBlocker = annotations.some((a) => a.annotation_level === "failure");
const r = await postCheck(hasBlocker ? "neutral" : "success", summary, annotations);
console.log(
  r && r.ok
    ? `deploy-audit: posted report (${annotations.length} inline, ${orphan.length} general)`
    : `deploy-audit: check POST failed`,
);
