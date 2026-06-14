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

function runReview() {
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
  const start = text.indexOf("{");
  const end = text.lastIndexOf("}");
  if (start < 0 || end < 0) return { summary: "Review unavailable.", findings: [] };
  const slice = text.slice(start, end + 1);
  for (const candidate of [slice, slice.replace(/\\'/g, "'")]) {
    try {
      return JSON.parse(candidate);
    } catch {
      /* try next */
    }
  }
  return { summary: "Review generated but could not be parsed as JSON.", findings: [] };
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

const summary =
  (review.summary || "No summary.") +
  (annotations.length ? `\n\n**${annotations.length} inline finding(s).**` : "\n\nNo blocking issues found.");

const res = await gh("check-runs", {
  name: "MacroDeploy review",
  head_sha: headSha,
  status: "completed",
  conclusion: annotations.some((a) => a.annotation_level === "failure") ? "neutral" : "success",
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
