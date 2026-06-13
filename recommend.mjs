// Gap & opportunity audit: Claude reviews the repo and recommends what to build
// or finish next — completeness gaps (TODOs, half-built flows, missing UI/backend,
// missing states, dead ends) and concrete new-feature opportunities. Posts a
// "MacroDeploy recommendations" check; the machine-readable list goes in
// output.text so the dashboard can render one-click "Create issue" actions.
// workflow_dispatch. Self-contained (only ANTHROPIC_API_KEY). Best-effort.
import { spawnSync } from "node:child_process";

const KEY = process.env.INPUT_ANTHROPIC_API_KEY || process.env.ANTHROPIC_API_KEY || "";
const MODEL = process.env.INPUT_MODEL || "claude-sonnet-4-6";
const TOKEN = process.env.GITHUB_TOKEN || "";
const REPO = process.env.GITHUB_REPOSITORY || "";
const SHA = process.env.GITHUB_SHA || "";

function bail(m) {
  console.log(`recommend: ${m}`);
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
      name: "MacroDeploy recommendations",
      head_sha: SHA,
      status: "completed",
      conclusion,
      output: { title: "Recommendations", summary, text: text || "" },
    }),
  }).catch(() => {});
}

if (!KEY && !process.env.CLAUDE_CODE_OAUTH_TOKEN) {
  await postCheck(
    "neutral",
    "⚠️ No `ANTHROPIC_API_KEY` is set on this repository, so recommendations couldn't run.\n\n" +
      "Add your Anthropic key — in MacroDeploy: **dashboard → Set key**; or on GitHub: **Settings → Secrets and variables → Actions → New secret `ANTHROPIC_API_KEY`** — then run it again.",
    "",
  );
  bail("no API key — posted needs-key check");
}

const PROMPT = `You are a senior product engineer reviewing this repository to recommend what to build or finish next. Read the code, routes, UI, and TODO/FIXME comments as needed. First infer what this product is and who uses it.

Find TWO kinds of items:
1. GAPS — incomplete or broken-by-omission work: TODO/FIXME/HACK comments, half-built flows, backend endpoints with no UI (or UI with no backend), missing empty/loading/error states, dead ends, obviously missing CRUD actions, accessibility gaps.
2. OPPORTUNITIES — concrete NEW features that fit this product's purpose and would plausibly add real user value.

For each item: an actionable, specific title and a description a developer could pick up. Anchor to a file path when one applies. Do NOT recommend things that are already fully implemented.

CRITICAL — verify before you claim something is missing, unwired, or has "no entry point". Proving absence requires search: grep for imports, component usages, route definitions, nav links, and call sites across the whole repo before asserting a feature/page/route/endpoint isn't reachable. If you find it wired up ANYWHERE (e.g. a backend endpoint is already called from some page, or a component is already imported), do NOT report it as a gap. A missing literal route path does not mean the feature is unreachable — it may be reached from another page. Prefer false negatives over false positives: when you are not certain after searching, omit the item rather than guess.

Respond with ONLY JSON (no prose, no code fences):
{"summary":"<4-6 sentences on the product's maturity and the most valuable things to build/finish next>","recommendations":[{"title":"<short imperative title>","detail":"<what + why + rough approach>","category":"gap|opportunity|todo","priority":"high|medium|low","path":"<repo-relative file, or empty string>"}]}
Order by priority (high first). Aim for 6-15 high-quality, deduped items.`;

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
let audit = { summary: "No parseable output.", recommendations: [] };
const s = text.indexOf("{");
const e = text.lastIndexOf("}");
if (s >= 0 && e > s) {
  try {
    audit = JSON.parse(text.slice(s, e + 1));
  } catch {
    audit = { summary: text.slice(0, 800), recommendations: [] };
  }
}

const recs = (Array.isArray(audit.recommendations) ? audit.recommendations : [])
  .filter((r) => r && r.title)
  .slice(0, 30)
  .map((r) => ({
    title: String(r.title).slice(0, 140),
    detail: String(r.detail || "").slice(0, 1200),
    category: ["gap", "opportunity", "todo"].includes(r.category) ? r.category : "opportunity",
    priority: ["high", "medium", "low"].includes(r.priority) ? r.priority : "medium",
    path: typeof r.path === "string" ? r.path : "",
  }));

const icon = (c) => (c === "gap" ? "🔧" : c === "todo" ? "📝" : "✨");
const lines = [audit.summary || "Recommendations complete."];
if (recs.length) {
  lines.push("", `**${recs.length} recommendation(s):**`);
  for (const r of recs)
    lines.push(`- ${icon(r.category)} _[${r.priority}]_ **${r.title}**${r.path ? ` — \`${r.path}\`` : ""}`);
} else {
  lines.push("", "No recommendations — looks complete. 🎉");
}

await postCheck("neutral", lines.join("\n").slice(0, 65000), JSON.stringify(recs));
console.log(`recommend: posted ${recs.length} recommendation(s)`);
