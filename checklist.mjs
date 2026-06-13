// User-defined audit: evaluate each item in .macrodeploy/checklist.md against the
// repo and report whether it's implemented, with evidence (file:line). Posts a
// "MacroDeploy Audit" check; the machine-readable per-item results go in
// output.text so the dashboard can render statuses + one-click "Create issue"/Fix.
// workflow_dispatch / schedule. Self-contained (only ANTHROPIC_API_KEY). Best-effort.
import { spawnSync } from "node:child_process";
import { existsSync, readFileSync } from "node:fs";

const KEY = process.env.INPUT_ANTHROPIC_API_KEY || process.env.ANTHROPIC_API_KEY || "";
const MODEL = process.env.INPUT_MODEL || "claude-sonnet-4-6";
const TOKEN = process.env.GITHUB_TOKEN || "";
const REPO = process.env.GITHUB_REPOSITORY || "";
const SHA = process.env.GITHUB_SHA || "";

function bail(m) {
  console.log(`checklist: ${m}`);
  process.exit(0);
}
if (!TOKEN || !REPO || !SHA) bail("missing GitHub context");

async function postCheck(conclusion, summary, text) {
  await fetch(`https://api.github.com/repos/${REPO}/check-runs`, {
    method: "POST",
    headers: {
      authorization: `Bearer ${TOKEN}`,
      accept: "application/vnd.github+json",
      "content-type": "application/json",
    },
    body: JSON.stringify({
      name: "MacroDeploy Audit",
      head_sha: SHA,
      status: "completed",
      conclusion,
      output: { title: "Audit", summary, text: text || "" },
    }),
  }).catch(() => {});
}

// The checklist can come two ways:
//   1. inline `checklist` input — the dashboard passes the user's selected items
//      at dispatch time (select-then-audit, no file needed);
//   2. a committed `.macrodeploy/checklist.md` — used by scheduled/AutoPilot runs.
// The inline input wins when present.
const INLINE = (process.env.INPUT_CHECKLIST || "").trim();
const CANDIDATES = [
  ".macrodeploy/checklist.md",
  ".macrodeploy/checklist.yml",
  ".macrodeploy/checklist.yaml",
  ".macrodeploy/checklist.txt",
];
let CHECKLIST = "";
let source = "selected items";
if (INLINE) {
  CHECKLIST = INLINE.slice(0, 12000);
} else {
  const file = CANDIDATES.find((p) => existsSync(p));
  if (!file) {
    await postCheck(
      "neutral",
      "No checklist provided. Either select items in MacroDeploy (**dashboard → Audit → Run**) " +
        "or commit **`.macrodeploy/checklist.md`** — one feature/tool per line (plain language). " +
        "Add `gate: true` to fail this check when a high-severity item is missing.\n\nExample:\n```\n" +
        "gate: true\n- API rate limiting is enforced on public endpoints (severity: high)\n" +
        "- Role-based access control on routes\n- CI runs tests on every PR\n" +
        "- No secrets committed to the repo (severity: high)\n```",
      "",
    );
    bail("no checklist (no inline input, no file) — posted needs-config check");
  }
  CHECKLIST = readFileSync(file, "utf8").slice(0, 12000);
  source = file;
}
// Gate flag: `gate: true` anywhere in the file turns a high-severity miss into a failure.
const GATE = /^\s*gate:\s*true\s*$/im.test(CHECKLIST);

if (!KEY) {
  await postCheck(
    "neutral",
    "⚠️ No `ANTHROPIC_API_KEY` is set on this repository, so the audit couldn't run.\n\n" +
      "Add your Anthropic key — in MacroDeploy: **dashboard → Set key**; or on GitHub: " +
      "**Settings → Secrets and variables → Actions → New secret `ANTHROPIC_API_KEY`** — then run it again.",
    "",
  );
  bail("no API key — posted needs-key check");
}

let MEMORY = "";
try {
  MEMORY = readFileSync(".macrodeploy/memory.md", "utf8").slice(0, 6000);
} catch {
  /* optional */
}

// The audit rubric is passed at runtime by the MacroDeploy dashboard (kept out of
// this public repo). Fall back to a bundled skill only if one exists.
let SYSTEM = (process.env.INPUT_SKILL || "").trim();
if (!SYSTEM) {
  const SKILLS_DIR = process.env.MACRODEPLOY_SKILLS_DIR || "/usr/local/share/macrodeploy/skills";
  try {
    SYSTEM = readFileSync(`${SKILLS_DIR}/checklist.md`, "utf8");
  } catch {
    /* no skill — runs generic */
  }
}

const PROMPT = `You are auditing this repository against a user-defined checklist. For EACH item, determine whether it is actually implemented in the codebase — and back every verdict with evidence.

${MEMORY ? `Repo context (from .macrodeploy/memory.md):\n${MEMORY}\n\n` : ""}CHECKLIST (${source}):
---
${CHECKLIST}
---

Rules:
- Investigate with Read/Grep/Glob. CRITICAL — proving something is present OR absent requires search: grep for imports, call sites, route definitions, config files, and dependencies across the WHOLE repo before deciding. Never claim an item is missing without having searched for it. Prefer "unknown" over guessing.
- status: "pass" (clearly implemented), "partial" (started but incomplete), "fail" (not implemented), or "unknown" (couldn't determine after searching).
- evidence: up to 3 concrete {path, line, quote} — the code that implements the item, or (for a fail) the place it should be and isn't.
- note: one line. remediation: short, only when status is fail/partial.
- id: kebab-case derived from the item. title: a short label. severity: use the one the item states (e.g. "(severity: high)") if present, else infer high/medium/low.
- Ignore a leading "gate: true" line — it's a config flag, not a checklist item.

Respond with ONLY JSON (no prose, no code fences):
{"summary":"<3-5 sentences: overall posture + the most important gaps>","items":[{"id":"","title":"","status":"pass|partial|fail|unknown","severity":"high|medium|low","confidence":"high|medium|low","note":"","remediation":"","evidence":[{"path":"","line":0,"quote":""}]}]}`;

process.env.ANTHROPIC_API_KEY = KEY;
const res = spawnSync(
  "claude",
  [
    "-p", PROMPT, "--model", MODEL, "--permission-mode", "acceptEdits",
    "--allowedTools", "Read,Grep,Glob", "--output-format", "json",
    ...(SYSTEM ? ["--append-system-prompt", SYSTEM] : []),
  ],
  { encoding: "utf8", maxBuffer: 64 * 1024 * 1024 },
);
const rawOut = (res.stdout || "") + "";

let text = rawOut;
try {
  const env = JSON.parse(rawOut);
  text = env.result || env.text || rawOut;
} catch {
  /* not enveloped */
}
let audit = { summary: "No parseable output.", items: [] };
const s = text.indexOf("{");
const e = text.lastIndexOf("}");
if (s >= 0 && e > s) {
  try {
    audit = JSON.parse(text.slice(s, e + 1));
  } catch {
    audit = { summary: text.slice(0, 800), items: [] };
  }
}

const items = (Array.isArray(audit.items) ? audit.items : [])
  .filter((it) => it && it.title)
  .slice(0, 100)
  .map((it) => ({
    id: String(it.id || "").slice(0, 80),
    title: String(it.title).slice(0, 160),
    status: ["pass", "partial", "fail", "unknown"].includes(it.status) ? it.status : "unknown",
    severity: ["high", "medium", "low"].includes(it.severity) ? it.severity : "medium",
    confidence: ["high", "medium", "low"].includes(it.confidence) ? it.confidence : "medium",
    note: String(it.note || "").slice(0, 500),
    remediation: String(it.remediation || "").slice(0, 800),
    evidence: (Array.isArray(it.evidence) ? it.evidence : []).slice(0, 3).map((ev) => ({
      path: typeof ev?.path === "string" ? ev.path : "",
      line: Number.isFinite(ev?.line) ? ev.line : 0,
      quote: String(ev?.quote || "").slice(0, 200),
    })),
  }));

const passed = items.filter((i) => i.status === "pass").length;
const failedHigh = items.some((i) => i.status === "fail" && i.severity === "high");
const icon = (st) => (st === "pass" ? "✅" : st === "partial" ? "🟡" : st === "fail" ? "❌" : "❔");
const lines = [audit.summary || "Audit complete.", "", `**${passed}/${items.length} passed**`];
for (const it of items) {
  lines.push(`- ${icon(it.status)} **${it.title}** _(${it.severity})_${it.note ? ` — ${it.note}` : ""}`);
}
if (!items.length) lines.push("", "No checklist items evaluated.");

const conclusion = GATE && failedHigh ? "failure" : "neutral";
await postCheck(
  conclusion,
  lines.join("\n").slice(0, 65000),
  JSON.stringify({ score: { passed, total: items.length }, gate: GATE, items }),
);
console.log(`checklist: posted ${items.length} item(s), ${passed} passed, conclusion=${conclusion}`);
