// MacroDeploy QA: build & start the app, run the repo's own Playwright/Cypress
// E2E if present, then have Claude drive a headless Chrome through the running app
// (via the Playwright MCP server) to find broken pages/flows. Posts a
// "MacroDeploy QA" Check and saves screenshots to ./qa-screenshots for the
// workflow to upload as an artifact. Self-contained; best-effort. Manual dispatch.
import { spawn, spawnSync } from "node:child_process";
import { existsSync, mkdirSync, writeFileSync, readdirSync, readFileSync } from "node:fs";
import net from "node:net";

const KEY = process.env.INPUT_ANTHROPIC_API_KEY || process.env.ANTHROPIC_API_KEY || "";
// QA is an audit — default to the stronger audit-tier model (parity with the
// security/coverage audits) unless the workflow passes one explicitly.
const MODEL = process.env.INPUT_MODEL || "claude-opus-4-8";
const TOKEN = process.env.GITHUB_TOKEN || "";
const REPO = process.env.GITHUB_REPOSITORY || "";
const SHA = process.env.GITHUB_SHA || "";
const PORT = parseInt(process.env.INPUT_APP_PORT || "3000", 10) || 3000;
const START_CMD = (process.env.INPUT_START_COMMAND || "").trim();
const INSTRUCTIONS = (process.env.INPUT_QA_INSTRUCTIONS || "").trim();
const APP_URL = `http://localhost:${PORT}`;
const WS = process.env.GITHUB_WORKSPACE || process.cwd();
const SCREENS = `${WS}/qa-screenshots`;

const log = (m) => console.log(`qa: ${m}`);
const tail = (s, n = 1500) => (s || "").slice(-n);
const sh = (cmd, ms = 600000, env = {}) =>
  spawnSync("bash", ["-lc", cmd], {
    encoding: "utf8",
    cwd: WS,
    timeout: ms,
    maxBuffer: 64 * 1024 * 1024,
    env: { ...process.env, ...env },
  });

if (!TOKEN || !REPO || !SHA) {
  log("missing GitHub context");
  process.exit(0);
}
mkdirSync(SCREENS, { recursive: true });

const issues = []; // { severity: info|warn|fail, area, detail }
const notes = []; // markdown lines for the E2E section
let aiSummary = "";

function has(files) {
  return files.some((f) => existsSync(`${WS}/${f}`));
}

function detectStart() {
  if (START_CMD) return START_CMD;
  let pkg = {};
  try {
    pkg = JSON.parse(sh("cat package.json").stdout || "{}");
  } catch {
    /* none */
  }
  const deps = { ...(pkg.dependencies || {}), ...(pkg.devDependencies || {}) };
  const scripts = pkg.scripts || {};
  if (deps.next) return `npm run build && PORT=${PORT} npx next start -p ${PORT}`;
  if (deps.vite || scripts.preview)
    return `npm run build && npx vite preview --port ${PORT} --host`;
  if (deps["react-scripts"]) return `npm run build && npx --yes serve -s build -l ${PORT}`;
  if (scripts.start) return `PORT=${PORT} npm run start`;
  return "";
}

function waitForPort(port, ms) {
  const deadline = Date.now() + ms;
  return new Promise((resolve) => {
    const tryOnce = () => {
      const sock = net.connect(port, "127.0.0.1");
      sock.once("connect", () => {
        sock.destroy();
        resolve(true);
      });
      sock.once("error", () => {
        sock.destroy();
        if (Date.now() > deadline) resolve(false);
        else setTimeout(tryOnce, 1500);
      });
    };
    tryOnce();
  });
}

// ── 1. install dependencies ─────────────────────────────────────────────────
log("installing dependencies");
if (has(["package.json"])) {
  if (has(["pnpm-lock.yaml"])) sh("corepack enable; pnpm install --frozen-lockfile || pnpm install");
  else if (has(["yarn.lock"])) sh("corepack enable; yarn install --frozen-lockfile || yarn install");
  else if (has(["package-lock.json"])) sh("npm ci || npm install");
  else sh("npm install");
}

// ── 2. start the app ────────────────────────────────────────────────────────
const startCmd = detectStart();
let server = null;
let serverLog = "";
let up = false;
if (!startCmd) {
  issues.push({
    severity: "fail",
    area: "App startup",
    detail:
      "Could not determine how to start the app (no recognizable framework or `start` script). " +
      "Set a start command on the QA run to enable browser testing.",
  });
} else {
  log(`starting app: ${startCmd}`);
  server = spawn("bash", ["-lc", startCmd], { cwd: WS, env: { ...process.env, PORT: String(PORT) } });
  server.stdout.on("data", (d) => (serverLog += d));
  server.stderr.on("data", (d) => (serverLog += d));
  up = await waitForPort(PORT, 150000);
  if (!up) {
    issues.push({
      severity: "fail",
      area: "App startup",
      detail:
        `The app did not become reachable at ${APP_URL} within 150s using \`${startCmd}\`.\n\n` +
        "Build/start log tail:\n```\n" +
        tail(serverLog) +
        "\n```",
    });
  }
}

// ── 3. existing E2E tests (best-effort) ─────────────────────────────────────
if (up) {
  if (has(["cypress.config.js", "cypress.config.ts", "cypress.config.mjs", "cypress.json"])) {
    log("running Cypress E2E");
    const r = sh(`npx --yes cypress run --config baseUrl=${APP_URL}`, 600000, { CI: "1" });
    const ok = r.status === 0;
    notes.push(`**Cypress E2E:** ${ok ? "✅ passed" : "❌ failed"}`);
    if (!ok)
      issues.push({ severity: "fail", area: "Cypress E2E", detail: "```\n" + tail(r.stdout + r.stderr) + "\n```" });
  }
  if (has(["playwright.config.js", "playwright.config.ts", "playwright.config.mjs"])) {
    log("running Playwright E2E");
    // Make sure the repo's Playwright has its Chromium, and point its baseURL at
    // our already-running server (reuse, so it doesn't try to boot a second one).
    sh("npx --yes playwright install chromium", 300000);
    const r = sh(`npx --yes playwright test`, 600000, {
      CI: "1",
      PLAYWRIGHT_TEST_BASE_URL: APP_URL,
      BASE_URL: APP_URL,
    });
    const ok = r.status === 0;
    notes.push(`**Playwright E2E:** ${ok ? "✅ passed" : "❌ failed"}`);
    if (!ok)
      issues.push({ severity: "fail", area: "Playwright E2E", detail: "```\n" + tail(r.stdout + r.stderr) + "\n```" });
  }
}

// ── 4. AI exploratory QA via Claude + Playwright MCP ────────────────────────
if (up && KEY) {
  log("running AI exploratory QA");
  // Use the Debian Chromium baked into the image (CHROME_BIN), falling back to
  // Playwright's managed download. --executable-path makes the MCP use it directly.
  const chromePath = process.env.CHROME_BIN || "/usr/bin/chromium";
  const mcpConfig = {
    mcpServers: {
      playwright: {
        command: "npx",
        args: [
          "@playwright/mcp@latest",
          "--headless",
          "--browser", "chromium",
          "--executable-path", chromePath,
          "--isolated",
          "--output-dir", SCREENS,
        ],
      },
    },
  };
  const cfgPath = "/tmp/mcp-playwright.json";
  writeFileSync(cfgPath, JSON.stringify(mcpConfig));

  // QA rubric (how to test, what's a real problem, severity, confidence bar) as
  // the system prompt; the repo's CLAUDE.md/AGENTS.md is auto-loaded for context.
  const SKILLS_DIR = process.env.MACRODEPLOY_SKILLS_DIR || "/usr/local/share/macrodeploy/skills";
  let SYSTEM = (process.env.INPUT_SKILL || "").trim();
  try {
    if (!SYSTEM) SYSTEM = readFileSync(`${SKILLS_DIR}/qa.md`, "utf8");
  } catch {}
  // Per-repo memory of accepted non-issues, so QA doesn't re-raise them.
  let MEMORY = "";
  try {
    MEMORY = readFileSync(`${WS}/.macrodeploy/memory.md`, "utf8").slice(0, 6000);
  } catch {}

  const prompt = `You are an automated QA engineer testing a web app already running at ${APP_URL}.

Use the Playwright browser tools to:
1. Open ${APP_URL} and wait for it to load.
2. Find the primary navigation and the main user flows.
3. Visit each major page/section. On each: confirm it renders (not blank, not an error page), watch for JavaScript console errors, and try the obvious primary action (click main buttons, submit visible forms with plausible dummy data).
${INSTRUCTIONS ? `4. Pay special attention to: ${INSTRUCTIONS}` : ""}

Take a screenshot of each major screen, and of anything that looks broken.

Only report REAL problems: blank/error pages, JavaScript console errors, broken or dead buttons/links, clearly broken layout, or flows that fail. Do not invent issues. Honor the repo's own CLAUDE.md / AGENTS.md conventions.${
  MEMORY ? `\n\nThese were reviewed before and accepted as non-issues or intended — do NOT raise them again:\n${MEMORY}` : ""
}

Respond with ONLY JSON (no prose, no code fences):
{"summary":"<3-5 sentences assessing the app's quality and what you exercised>","issues":[{"severity":"info|warn|fail","area":"<page or flow>","detail":"<what is wrong + how to reproduce>"}]}
Empty issues array if everything works.`;

  if (KEY) process.env.ANTHROPIC_API_KEY = KEY;
  process.env.MAX_THINKING_TOKENS = process.env.MAX_THINKING_TOKENS || "8000"; // extended thinking
  const res = spawnSync(
    "claude",
    ["-p", prompt, "--model", MODEL, "--permission-mode", "acceptEdits",
     "--allowedTools", "mcp__playwright", "--mcp-config", cfgPath, "--output-format", "json",
     ...(SYSTEM ? ["--append-system-prompt", SYSTEM] : [])],
    { encoding: "utf8", cwd: WS, timeout: 900000, maxBuffer: 64 * 1024 * 1024 },
  );
  let text = (res.stdout || "") + "";
  try {
    const env = JSON.parse(text);
    text = env.result || env.text || text;
  } catch {
    /* not enveloped */
  }
  const a = text.indexOf("{");
  const b = text.lastIndexOf("}");
  if (a >= 0 && b > a) {
    try {
      const parsed = JSON.parse(text.slice(a, b + 1));
      aiSummary = parsed.summary || "";
      for (const it of Array.isArray(parsed.issues) ? parsed.issues : []) {
        if (it && it.detail) issues.push({ severity: it.severity || "warn", area: it.area || "App", detail: it.detail });
      }
    } catch {
      aiSummary = text.slice(0, 800);
    }
  }
} else if (up && !KEY) {
  notes.push("_AI exploratory pass skipped: no `ANTHROPIC_API_KEY` set._");
}

// ── 5. stop the app ─────────────────────────────────────────────────────────
if (server) {
  try {
    server.kill("SIGTERM");
  } catch {
    /* already gone */
  }
}

// ── 6. post the "MacroDeploy QA" Check ──────────────────────────────────────
let shots = 0;
try {
  shots = readdirSync(SCREENS).filter((f) => /\.(png|jpe?g)$/i.test(f)).length;
} catch {
  /* none */
}

const badge = (s) => (s === "fail" ? "🔴" : s === "warn" ? "🟠" : "🔵");
const fails = issues.filter((i) => i.severity === "fail").length;
const lines = [];
if (aiSummary) lines.push(aiSummary);
if (notes.length) lines.push("", ...notes);
if (issues.length) {
  lines.push("", `**${issues.length} issue(s) found:**`);
  for (const i of issues) lines.push(`- ${badge(i.severity)} **${i.area}** — ${tail(i.detail, 600)}`);
} else {
  lines.push("", "No issues found. ✅");
}
if (shots) lines.push("", `_${shots} screenshot(s) attached to this workflow run as the \`qa-screenshots\` artifact._`);

const summary = lines.join("\n").slice(0, 65000);
const r = await fetch(`https://api.github.com/repos/${REPO}/check-runs`, {
  method: "POST",
  headers: {
    authorization: `Bearer ${TOKEN}`,
    accept: "application/vnd.github+json",
    "content-type": "application/json",
  },
  body: JSON.stringify({
    name: "MacroDeploy QA",
    head_sha: SHA,
    status: "completed",
    conclusion: fails > 0 ? "failure" : "success",
    output: { title: "QA run", summary },
  }),
});
log(r.ok ? `posted QA with ${issues.length} issue(s), ${shots} screenshot(s)` : `check POST failed (${r.status}) ${await r.text()}`);
