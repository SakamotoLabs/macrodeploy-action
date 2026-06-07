// AI review → a GitHub Check Run with inline annotations + a summary.
// Runs inside the action container (Node 20, global fetch). Best-effort: any
// failure just logs and exits 0 so it never fails the build (the verify gate does).
import { execSync } from "node:child_process";
import { readFileSync } from "node:fs";

const KEY = process.env.INPUT_ANTHROPIC_API_KEY || process.env.ANTHROPIC_API_KEY || "";
const MODEL = process.env.INPUT_MODEL || "claude-sonnet-4-6";
const TOKEN = process.env.GITHUB_TOKEN || "";
const REPO = process.env.GITHUB_REPOSITORY || "";
// REVIEW_BASE_REF / REVIEW_HEAD_SHA let the implement flow review the agent's
// own commit; otherwise fall back to the pull_request context.
const BASE = process.env.REVIEW_BASE_REF || process.env.GITHUB_BASE_REF || "";
const EVENT_PATH = process.env.GITHUB_EVENT_PATH || "";

function bail(msg) {
  console.log(`review: ${msg}`);
  process.exit(0);
}

if (!KEY) bail("no API key — skipping review");
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
  diff = execSync(`git diff --no-color origin/${BASE}...HEAD`, { encoding: "utf8", maxBuffer: 20e6 });
} catch (e) {
  bail("could not compute diff");
}
if (!diff.trim()) bail("empty diff");
diff = diff.slice(0, 35000);

// Full content of changed files (capped) so the reviewer can SEE imports,
// helpers, and definitions that live outside the diff hunks — this is what
// prevents false positives like "is X imported?" when X is imported elsewhere.
let context = "";
try {
  const files = execSync(`git diff --name-only origin/${BASE}...HEAD`, { encoding: "utf8" })
    .split("\n")
    .filter(Boolean);
  let budget = 45000;
  for (const f of files) {
    let body = "";
    try {
      body = readFileSync(f, "utf8");
    } catch {
      continue; // deleted/binary
    }
    const chunk = `\n\n===== FILE: ${f} =====\n${body}`;
    if (chunk.length > budget) break;
    context += chunk;
    budget -= chunk.length;
  }
} catch {
  /* best-effort */
}

// The review rubric (correctness bar, severity calibration, confidence/false-
// positive discipline) is injected as the system prompt — distilled from the
// ea-core `code-review` skill so the cloud reviewer follows the same standard a
// local Claude Code session would. Optional; absent file → no system prompt.
const SKILLS_DIR = process.env.MACRODEPLOY_SKILLS_DIR || "/usr/local/share/macrodeploy/skills";
let SYSTEM = "";
try {
  SYSTEM = readFileSync(`${SKILLS_DIR}/code-review.md`, "utf8");
} catch {
  /* no skill pack → fall back to the user prompt alone */
}

const PROMPT = `Review this pull request. Respond with ONLY JSON (no prose, no code fences) of the form:
{"summary": "<2-4 sentence overall verdict>",
 "findings": [{"path": "<repo-relative file>", "line": <int line in the new file>, "level": "notice|warning|failure", "comment": "<concrete issue + fix>"}]}
Flag real correctness/security bugs; skip style nits. Empty findings array if it looks good.

Only flag issues introduced by the DIFF. Use the FULL FILES below for context so you DON'T raise false positives about things that already exist outside the diff (e.g. an import, helper, or type that's present elsewhere in the file). If you're tempted to say "ensure X is imported/defined", first check the full file — if it's there, do not flag it.

Each "comment" MUST be 1-2 sentences, concrete and FINAL — no reasoning out loud, no "wait", no second-guessing or retracting. Output STRICT, valid JSON: double-quoted strings only, escape any double quote inside a string as \\", and never use a backslash before a single quote.

DIFF:
${diff}

FULL FILES (context only — do not flag pre-existing code):
${context}`;

async function anthropic() {
  const res = await fetch("https://api.anthropic.com/v1/messages", {
    method: "POST",
    headers: {
      "x-api-key": KEY,
      "anthropic-version": "2023-06-01",
      "content-type": "application/json",
    },
    // temperature 0 → stable, repeatable reviews (severity/findings don't drift
    // run-to-run on the same code), which matters for the fix → re-review loop.
    body: JSON.stringify({
      model: MODEL,
      max_tokens: 1500,
      temperature: 0,
      ...(SYSTEM ? { system: SYSTEM } : {}),
      messages: [{ role: "user", content: PROMPT }],
    }),
  });
  const data = await res.json();
  const text = data?.content?.[0]?.text ?? "";
  const start = text.indexOf("{");
  const end = text.lastIndexOf("}");
  if (start < 0 || end < 0) return { summary: "Review unavailable.", findings: [] };
  const slice = text.slice(start, end + 1);
  // Models occasionally emit invalid JSON (e.g. `\'`, a non-JSON escape). Try as-is,
  // then with that escape cleaned. Never fall back to dumping the raw blob.
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

const review = await anthropic();
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

// Also document the review as a PR comment so the trail is visible in the PR,
// not just in Checks. PR number: explicit (implement/fix) or the PR event.
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
