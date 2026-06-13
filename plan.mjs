// Feature → tasks breakdown: given a feature description, Claude reads the repo
// and splits it into a small set of concrete, agent-ready tasks. Posts a
// "MacroDeploy plan" check; the machine-readable task list goes in output.text
// so the dashboard can turn each task into a labeled issue (→ issue→PR agent).
// workflow_dispatch with a `feature` input. Self-contained. Best-effort.
import { spawnSync } from "node:child_process";

const KEY = process.env.INPUT_ANTHROPIC_API_KEY || process.env.ANTHROPIC_API_KEY || "";
const MODEL = process.env.INPUT_MODEL || "claude-sonnet-4-6";
const TOKEN = process.env.GITHUB_TOKEN || "";
const REPO = process.env.GITHUB_REPOSITORY || "";
const SHA = process.env.GITHUB_SHA || "";
const FEATURE = (process.env.INPUT_PLAN_FEATURE || "").trim();

function bail(m) {
  console.log(`plan: ${m}`);
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
      name: "MacroDeploy plan",
      head_sha: SHA,
      status: "completed",
      conclusion,
      output: { title: "Feature plan", summary, text: text || "" },
    }),
  }).catch(() => {});
}

if (!KEY && !process.env.CLAUDE_CODE_OAUTH_TOKEN) {
  await postCheck(
    "neutral",
    "⚠️ No `ANTHROPIC_API_KEY` is set on this repository, so the feature plan couldn't run.\n\n" +
      "Add your Anthropic key — in MacroDeploy: **dashboard → Set key** — then try again.",
    "",
  );
  bail("no API key — posted needs-key check");
}
if (!FEATURE) {
  await postCheck("neutral", "No feature description was provided.", "");
  bail("no feature provided");
}

const PROMPT = `You are a senior engineer planning work in THIS repository. Read the codebase for context (structure, stack, conventions), then break the feature request below into a small set of concrete, independently-shippable tasks.

FEATURE REQUEST:
${FEATURE}

Each task must be implementable on its own by a coding agent. Give a clear imperative title and a description with enough specifics (which files/areas, the approach, acceptance) to implement without further questions. Prefer 3-7 well-scoped tasks over many tiny ones. Order them so earlier tasks unblock later ones.

Ground every task in what's actually in the repo: before proposing to build something, grep for existing imports/usages/routes/endpoints so you don't recommend building something that already exists. If part of the feature is already implemented, scope tasks to only the missing pieces.

Respond with ONLY JSON (no prose, no code fences):
{"summary":"<2-4 sentences: your overall approach and sequencing>","tasks":[{"title":"<short imperative title>","detail":"<what to build + which files/areas + approach + acceptance>","priority":"high|medium|low"}]}`;

if (KEY) process.env.ANTHROPIC_API_KEY = KEY;
const res = spawnSync(
  "claude",
  ["-p", PROMPT, "--model", MODEL, "--permission-mode", "acceptEdits",
   "--allowedTools", "Read,Grep,Glob", "--output-format", "json"],
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
let plan = { summary: "No parseable output.", tasks: [] };
const s = text.indexOf("{");
const e = text.lastIndexOf("}");
if (s >= 0 && e > s) {
  try {
    plan = JSON.parse(text.slice(s, e + 1));
  } catch {
    plan = { summary: text.slice(0, 800), tasks: [] };
  }
}

const tasks = (Array.isArray(plan.tasks) ? plan.tasks : [])
  .filter((t) => t && t.title)
  .slice(0, 20)
  .map((t) => ({
    title: String(t.title).slice(0, 140),
    detail: String(t.detail || "").slice(0, 2000),
    priority: ["high", "medium", "low"].includes(t.priority) ? t.priority : "medium",
  }));

const lines = [`**Feature:** ${FEATURE.slice(0, 300)}`, "", plan.summary || ""];
if (tasks.length) {
  lines.push("", `**${tasks.length} task(s):**`);
  tasks.forEach((t, i) => lines.push(`${i + 1}. _[${t.priority}]_ **${t.title}**`));
} else {
  lines.push("", "Could not break this into tasks — try rephrasing the feature.");
}

await postCheck("neutral", lines.join("\n").slice(0, 65000), JSON.stringify(tasks));
console.log(`plan: posted ${tasks.length} task(s)`);
