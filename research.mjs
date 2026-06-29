// Research mode: the user asks a free-form question about the repo; Claude
// investigates the code (read-only) and answers, optionally proposing concrete
// ideas the user can turn into issues. Posts a "MacroDeploy Research" check; the
// machine-readable {question, answer, ideas} goes in output.text so the dashboard
// can render the answer + one-click "Create issue" actions for the ideas.
// workflow_dispatch. Self-contained (only ANTHROPIC_API_KEY). Best-effort.
import { spawnSync } from "node:child_process";

const KEY = process.env.INPUT_ANTHROPIC_API_KEY || process.env.ANTHROPIC_API_KEY || "";
const MODEL = process.env.INPUT_MODEL || "claude-sonnet-4-6";
const TOKEN = process.env.GITHUB_TOKEN || "";
const REPO = process.env.GITHUB_REPOSITORY || "";
const SHA = process.env.GITHUB_SHA || "";
const QUESTION = (process.env.INPUT_QUESTION || "").trim();

function bail(m) {
  console.log(`research: ${m}`);
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
      name: "MacroDeploy Research",
      head_sha: SHA,
      status: "completed",
      conclusion,
      output: { title: "Research", summary, text: text || "" },
    }),
  }).catch(() => {});
}

if (!QUESTION) bail("no question provided");

if (!KEY && !process.env.CLAUDE_CODE_OAUTH_TOKEN) {
  await postCheck(
    "neutral",
    "⚠️ No `ANTHROPIC_API_KEY` is set on this repository, so research couldn't run.\n\n" +
      "Add your Anthropic key — in MacroDeploy: **dashboard → Set key**; or on GitHub: **Settings → Secrets and variables → Actions → New secret `ANTHROPIC_API_KEY`** — then ask again.",
    JSON.stringify({ question: QUESTION, answer: "", ideas: [] }),
  );
  bail("no API key — posted needs-key check");
}

const PROMPT = `You are a senior engineer answering a question about THIS repository for its owner. Investigate the code, routes, UI, config, and docs as needed to answer accurately. First infer what this product is and who uses it.

THE QUESTION:
${QUESTION}

Answer it directly and concretely, grounded in what the code actually does — cite file paths where helpful. Do NOT make changes, do NOT open issues or PRs; this is investigation only.

Then, ONLY IF the question naturally invites them, propose a few concrete IDEAS the owner could act on (e.g. improvements, fixes, or features related to the question). Ideas are optional — return an empty array if none are warranted. Do not pad with generic suggestions.

CRITICAL — verify before you claim something exists, is missing, or is unwired. Proving absence requires search: grep for imports, usages, route definitions, and call sites across the whole repo before asserting something isn't there. Prefer "I couldn't find evidence of X" over a confident false claim.

Respond with ONLY JSON (no prose, no code fences):
{"answer":"<a clear, specific answer to the question, in markdown; multiple paragraphs ok>","ideas":[{"title":"<short imperative title>","detail":"<what + why + rough approach>","category":"gap|opportunity|todo","priority":"high|medium|low","path":"<repo-relative file, or empty string>"}]}
Keep ideas to at most 8, ordered by priority (high first), deduped. If no ideas are warranted, use "ideas":[].`;

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
let parsed = { answer: "", ideas: [] };
const s = text.indexOf("{");
const e = text.lastIndexOf("}");
if (s >= 0 && e > s) {
  try {
    parsed = JSON.parse(text.slice(s, e + 1));
  } catch {
    parsed = { answer: text.slice(0, 4000), ideas: [] };
  }
}

const answer = String(parsed.answer || "").slice(0, 60000) || "No answer was produced.";
const ideas = (Array.isArray(parsed.ideas) ? parsed.ideas : [])
  .filter((r) => r && r.title)
  .slice(0, 8)
  .map((r) => ({
    title: String(r.title).slice(0, 140),
    detail: String(r.detail || "").slice(0, 1200),
    category: ["gap", "opportunity", "todo"].includes(r.category) ? r.category : "opportunity",
    priority: ["high", "medium", "low"].includes(r.priority) ? r.priority : "medium",
    path: typeof r.path === "string" ? r.path : "",
  }));

// The check summary (markdown, shown in the GitHub UI) carries the answer + an
// ideas index; the dashboard reads the structured payload from output.text.
const icon = (c) => (c === "gap" ? "🔧" : c === "todo" ? "📝" : "✨");
const lines = [answer];
if (ideas.length) {
  lines.push("", `**${ideas.length} idea(s):**`);
  for (const r of ideas)
    lines.push(`- ${icon(r.category)} _[${r.priority}]_ **${r.title}**${r.path ? ` — \`${r.path}\`` : ""}`);
}

await postCheck(
  "neutral",
  lines.join("\n").slice(0, 65000),
  JSON.stringify({ question: QUESTION, answer, ideas }),
);
console.log(`research: answered; posted ${ideas.length} idea(s)`);
