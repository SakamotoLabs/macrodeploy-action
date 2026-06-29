// AI review → a GitHub Check Run with inline annotations + a summary.
// Runs inside the action container. Best-effort: any failure just logs and exits
// 0 so it never fails the build (the verify gate does).
//
// Agentic: instead of a single blind API call on the diff, we run the review
// through the Claude Code CLI WITH Read/Grep/Glob tools, so the reviewer can
// inspect the rest of the repo to VERIFY a finding before flagging it (e.g.
// confirm a symbol really is undefined, or that an import is actually missing).
// This is the main defense against false positives. It also auto-loads the
// repo's CLAUDE.md/AGENTS.md as project memory, and honors a per-repo memory of
// previously-accepted non-issues so re-reviews stop re-flagging the same things.
import { spawnSync } from "node:child_process";
import { readFileSync } from "node:fs";

const KEY = process.env.INPUT_ANTHROPIC_API_KEY || process.env.ANTHROPIC_API_KEY || "";
const MODEL = process.env.INPUT_MODEL || "claude-sonnet-4-6";
// For large / complex diffs, escalate to a stronger model + more thinking — the
// judgment a hard review needs (mirrors running Opus locally on a gnarly PR).
const DEEP_MODEL = process.env.INPUT_REVIEW_DEEP_MODEL || "claude-opus-4-8";
const TOKEN = process.env.GITHUB_TOKEN || "";
const REPO = process.env.GITHUB_REPOSITORY || "";
const BASE = process.env.REVIEW_BASE_REF || process.env.GITHUB_BASE_REF || "";
const EVENT_PATH = process.env.GITHUB_EVENT_PATH || "";

function bail(msg) {
  console.log(`review: ${msg}`);
  process.exit(0);
}

if (!KEY && !process.env.CLAUDE_CODE_OAUTH_TOKEN) bail("no API key — skipping review");
if (!BASE) bail("no base ref — skipping review");
if (!TOKEN || !REPO) bail("missing GITHUB_TOKEN/REPOSITORY — skipping review");

// Head SHA the annotations attach to.
let headSha = process.env.REVIEW_HEAD_SHA || process.env.GITHUB_SHA;
if (!process.env.REVIEW_HEAD_SHA) {
  try {
    const ev = JSON.parse(readFileSync(EVENT_PATH, "utf8"));
    headSha = ev.pull_request?.head?.sha || headSha;
  } catch {}
}

let diff = "";
try {
  // Args array (no shell) so a branch/ref name can never be interpreted by a shell.
  const d = spawnSync("git", ["diff", "--no-color", `origin/${BASE}...HEAD`], { encoding: "utf8", maxBuffer: 20e6 });
  if (d.status !== 0) throw new Error(d.stderr || "git diff failed");
  diff = d.stdout || "";
} catch {
  bail("could not compute diff");
}
if (!diff.trim()) bail("empty diff");
const fileCount = (diff.match(/^diff --git/gm) || []).length;
const big = diff.length > 12000 || fileCount > 8;
diff = diff.slice(0, 40000);

// Per-repo memory of accepted non-issues / conventions, so the reviewer doesn't
// re-flag things a previous round already dismissed (the closest analog to a
// local session's memory). Written by the fix flow when it dismisses a finding.
let memory = "";
try {
  memory = readFileSync(".macrodeploy/memory.md", "utf8").slice(0, 6000);
} catch {}

// Review rubric (severity calibration + confidence/false-positive bar), distilled
// from the ea-core `code-review` skill, injected as the system prompt.
const SKILLS_DIR = process.env.MACRODEPLOY_SKILLS_DIR || "/usr/local/share/macrodeploy/skills";
let SYSTEM = "";
try {
  SYSTEM = readFileSync(`${SKILLS_DIR}/code-review.md`, "utf8");
} catch {}

const PROMPT = `Review the pull request diff below. You have Read, Grep, and Glob tools — USE them to inspect the rest of the repository and VERIFY before flagging. Before raising "X is undefined/unimported/missing", actually look: grep for X, open the file. If it exists, do not flag it. This verification step is mandatory.

Follow the repository's own conventions — its CLAUDE.md / AGENTS.md and the patterns already in the code. Flag only issues INTRODUCED by this diff; never pre-existing code.
${memory ? `\nThese were reviewed before and accepted as non-issues or intended conventions — do NOT flag them again:\n${memory}\n` : ""}
When done, respond with ONLY JSON (no prose, no code fences) as your final message:
{"summary": "<2-4 sentence overall verdict>",
 "findings": [{"path": "<repo-relative file>", "line": <int line in the new file>, "level": "notice|warning|failure", "comment": "<concrete issue + fix, 1-2 sentences, final — no thinking out loud>"}]}
Empty findings array if it looks good. Output STRICT valid JSON: double-quoted strings, escape any inner double quote as \\", never backslash before a single quote.

DIFF:
${diff}`;

// One model invocation → raw assistant text (unwraps the --output-format json envelope).
function callClaude() {
  const useModel = big ? DEEP_MODEL : MODEL;
  // Claude Code reads MAX_THINKING_TOKENS to size extended thinking; give complex
  // reviews more room to reason.
  const thinking = big ? "12000" : "4000";
  const res = spawnSync(
    "claude",
    ["-p", PROMPT, "--model", useModel, "--permission-mode", "acceptEdits",
     "--allowedTools", "Read,Grep,Glob", "--output-format", "json",
     ...(SYSTEM ? ["--append-system-prompt", SYSTEM] : [])],
    {
      encoding: "utf8",
      maxBuffer: 64 * 1024 * 1024,
      // Only set ANTHROPIC_API_KEY when present — an empty value would shadow a
      // Pro/Max CLAUDE_CODE_OAUTH_TOKEN in the CLI (it's inherited via process.env).
      env: { ...process.env, ...(KEY ? { ANTHROPIC_API_KEY: KEY } : {}), MAX_THINKING_TOKENS: thinking },
    },
  );
  console.log(`review: model=${useModel} thinking=${thinking} files=${fileCount}`);
  let text = res.stdout || "";
  // claude --output-format json → { result: "<assistant text>", ... }
  try {
    const env = JSON.parse(text);
    text = env.result || env.text || text;
  } catch {
    /* not enveloped — treat as raw text */
  }
  return text;
}

function tryParse(s) {
  try { return JSON.parse(s); } catch { /* fall through to a forgiving pass */ }
  try { return JSON.parse(s.replace(/\\'/g, "'")); } catch { return null; }
}

// First brace-balanced {...} object (string/escape aware). Robust to prose around
// the JSON or a stray "}" in trailing commentary that the naive first-{/last-}
// slice would wrongly swallow.
function firstBalancedObject(s) {
  for (let i = 0; i < s.length; i++) {
    if (s[i] !== "{") continue;
    let depth = 0, inStr = false, esc = false;
    for (let j = i; j < s.length; j++) {
      const ch = s[j];
      if (inStr) {
        if (esc) esc = false;
        else if (ch === "\\") esc = true;
        else if (ch === '"') inStr = false;
        continue;
      }
      if (ch === '"') inStr = true;
      else if (ch === "{") depth++;
      else if (ch === "}" && --depth === 0) return s.slice(i, j + 1);
    }
  }
  return null;
}

// Pull the review JSON out of the model text: prefer a fenced ```json block, then a
// balanced object, then the naive first-{/last-} slice. Returns null if none parse.
function extractJson(text) {
  const sources = [];
  const fence = text.match(/```(?:json)?\s*([\s\S]*?)```/i);
  if (fence) sources.push(fence[1]);
  sources.push(text);
  for (const src of sources) {
    const bal = firstBalancedObject(src);
    if (bal) {
      const p = tryParse(bal);
      if (p && typeof p === "object") return p;
    }
  }
  const start = text.indexOf("{");
  const end = text.lastIndexOf("}");
  if (start >= 0 && end > start) {
    const p = tryParse(text.slice(start, end + 1));
    if (p) return p;
  }
  return null;
}

// Run the review; retry once if the model's output won't parse (usually transient).
// On a persistent failure, flag parseError so the check is neutral (never a silent
// "clean" pass).
function runReview() {
  for (let attempt = 1; attempt <= 2; attempt++) {
    const parsed = extractJson(callClaude());
    if (parsed) return parsed;
    console.log(`review: could not parse model output (attempt ${attempt}/2)`);
  }
  return {
    summary: "Review output couldn't be parsed as JSON after a retry — please re-run the review.",
    findings: [],
    parseError: true,
  };
}

function gh(path, body) {
  return fetch(`https://api.github.com/repos/${REPO}/${path}`, {
    method: "POST",
    headers: {
      authorization: `Bearer ${TOKEN}`,
      accept: "application/vnd.github+json",
      "content-type": "application/json",
    },
    body: JSON.stringify(body),
  });
}

const review = runReview();
const findings = Array.isArray(review.findings) ? review.findings : [];
const annotations = findings
  .filter((f) => f && f.path && f.line)
  .slice(0, 50)
  .map((f) => ({
    path: f.path,
    start_line: f.line,
    end_line: f.line,
    annotation_level: ["notice", "warning", "failure"].includes(f.level) ? f.level : "warning",
    message: f.comment || "Issue flagged by MacroDeploy.",
  }));

const summary = review.parseError
  ? review.summary
  : (review.summary || "No summary.") +
    (annotations.length ? `\n\n**${annotations.length} inline finding(s).**` : "\n\nNo blocking issues found.");

const res = await gh("check-runs", {
  name: "MacroDeploy review",
  head_sha: headSha,
  status: "completed",
  // Parse failures and failure-level findings are both neutral (advisory), so a
  // broken parse is never mistaken for a clean review.
  conclusion:
    review.parseError || annotations.some((a) => a.annotation_level === "failure") ? "neutral" : "success",
  output: { title: "MacroDeploy review", summary, annotations },
});

if (!res.ok) {
  console.log(`review: check-run POST failed (${res.status}) — ${await res.text()}`);
} else {
  console.log(`review: posted check with ${annotations.length} annotation(s)`);
}

// Also document the review as a PR comment so the trail is visible in the PR.
let prNum = process.env.REVIEW_PR_NUMBER || "";
if (!prNum && EVENT_PATH) {
  try {
    prNum = String(JSON.parse(readFileSync(EVENT_PATH, "utf8")).pull_request?.number || "");
  } catch {}
}
if (prNum) {
  const shortSha = (headSha || "").slice(0, 8);
  const lines = findings
    .filter((f) => f && f.path)
    .map((f) => `- \`${f.path}:${f.line ?? "?"}\` _[${f.level || "warning"}]_ ${f.comment || ""}`);
  const body =
    `### 🔎 MacroDeploy AI review — commit \`${shortSha}\`\n\n` +
    (review.summary || "") +
    (lines.length
      ? `\n\n**${lines.length} finding(s):**\n${lines.join("\n")}`
      : "\n\n✅ No blocking issues found.");
  const c = await gh(`issues/${prNum}/comments`, { body });
  console.log(c.ok ? `review: posted PR comment on #${prNum}` : `review: PR comment failed (${c.status})`);
}
