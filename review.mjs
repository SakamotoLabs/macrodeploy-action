// AI review → a GitHub Check Run with inline annotations + a summary.
// Runs inside the action container (Node 20, global fetch). Best-effort: any
// failure just logs and exits 0 so it never fails the build (the verify gate does).
import { execSync } from "node:child_process";
import { readFileSync } from "node:fs";

const KEY = process.env.INPUT_ANTHROPIC_API_KEY || process.env.ANTHROPIC_API_KEY || "";
const MODEL = process.env.INPUT_MODEL || "claude-sonnet-4-6";
const TOKEN = process.env.GITHUB_TOKEN || "";
const REPO = process.env.GITHUB_REPOSITORY || "";
const BASE = process.env.GITHUB_BASE_REF || "";
const EVENT_PATH = process.env.GITHUB_EVENT_PATH || "";

function bail(msg) {
  console.log(`review: ${msg}`);
  process.exit(0);
}

if (!KEY) bail("no API key — skipping review");
if (!BASE) bail("not a pull request — skipping review");
if (!TOKEN || !REPO) bail("missing GITHUB_TOKEN/REPOSITORY — skipping review");

// Head SHA of the PR (annotations attach to the real commit, not the merge ref).
let headSha = process.env.GITHUB_SHA;
try {
  const ev = JSON.parse(readFileSync(EVENT_PATH, "utf8"));
  headSha = ev.pull_request?.head?.sha || headSha;
} catch {}

let diff = "";
try {
  diff = execSync(`git diff --no-color origin/${BASE}...HEAD`, { encoding: "utf8", maxBuffer: 20e6 });
} catch (e) {
  bail("could not compute diff");
}
if (!diff.trim()) bail("empty diff");
diff = diff.slice(0, 60000);

const PROMPT = `Review this pull request diff. Respond with ONLY JSON (no prose, no code fences) of the form:
{"summary": "<2-4 sentence overall verdict>",
 "findings": [{"path": "<repo-relative file>", "line": <int line in the new file>, "level": "notice|warning|failure", "comment": "<concrete issue + fix>"}]}
Flag real correctness/security bugs; skip style nits. Empty findings array if it looks good.

DIFF:
${diff}`;

async function anthropic() {
  const res = await fetch("https://api.anthropic.com/v1/messages", {
    method: "POST",
    headers: {
      "x-api-key": KEY,
      "anthropic-version": "2023-06-01",
      "content-type": "application/json",
    },
    body: JSON.stringify({ model: MODEL, max_tokens: 1500, messages: [{ role: "user", content: PROMPT }] }),
  });
  const data = await res.json();
  const text = data?.content?.[0]?.text ?? "";
  const start = text.indexOf("{");
  const end = text.lastIndexOf("}");
  if (start < 0 || end < 0) return { summary: text || "Review unavailable.", findings: [] };
  try {
    return JSON.parse(text.slice(start, end + 1));
  } catch {
    return { summary: text, findings: [] };
  }
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
