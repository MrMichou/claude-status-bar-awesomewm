#!/usr/bin/env node
// Invoked by Claude Code hooks. Reads the hook JSON payload on stdin, maps the
// event to a status, and atomically writes ~/.claude/statusbar/state.json.
// Usage: node update.js <prompt|pre|post|notify|permreq|stop>

const fs = require("fs");
const os = require("os");
const path = require("path");

const dir = path.join(os.homedir(), ".claude", "statusbar");
const statePath = path.join(dir, "state.json");
const event = process.argv[2] || "";

const TOOL_LABELS = {
  Bash: "Running command", Edit: "Editing", Write: "Writing", MultiEdit: "Editing",
  NotebookEdit: "Editing", Read: "Reading", Grep: "Searching", Glob: "Searching",
  WebFetch: "Browsing web", WebSearch: "Searching web", Task: "Delegating",
  TodoWrite: "Planning",
};

// Per-million-token USD rates, matched by model-id prefix (longest first). cacheWrite is the
// 5-minute write rate (1.25x input); cacheRead is 0.1x input. Used to estimate the cost of the
// current turn from the transcript's usage metadata.
const PRICING = [
  ["claude-opus-4",   { in: 5,  out: 25, cacheWrite: 6.25, cacheRead: 0.5 }],
  ["claude-sonnet-4", { in: 3,  out: 15, cacheWrite: 3.75, cacheRead: 0.3 }],
  ["claude-haiku-4",  { in: 1,  out: 5,  cacheWrite: 1.25, cacheRead: 0.1 }],
  ["claude-fable-5",  { in: 10, out: 50, cacheWrite: 12.5, cacheRead: 1.0 }],
  ["claude-mythos-5", { in: 10, out: 50, cacheWrite: 12.5, cacheRead: 1.0 }],
];
const priceFor = (model) => {
  for (const [prefix, p] of PRICING) if (model && model.startsWith(prefix)) return p;
  return null;
};

// A turn-start line: a user message that is a real prompt, not a tool_result carrier.
function isUserPrompt(o) {
  if (!o || o.type !== "user" || !o.message) return false;
  const c = o.message.content;
  if (typeof c === "string") return true;
  if (Array.isArray(c)) return !c.some((b) => b && b.type === "tool_result");
  return false;
}

// Sum the usage of the assistant messages in the current turn (since the last user prompt),
// reading only the transcript tail so a large file stays cheap on the hot path. Returns
// { tokens, cost } where tokens is the turn's output tokens and cost is an estimate in USD.
// Null if the transcript can't be read or carries no usable usage.
function turnUsage(transcriptPath) {
  if (!transcriptPath) return null;
  let data, start;
  try {
    const stat = fs.statSync(transcriptPath);
    const CAP = 1024 * 1024; // tail only — a turn rarely exceeds this; undercount past it
    start = stat.size > CAP ? stat.size - CAP : 0;
    const fd = fs.openSync(transcriptPath, "r");
    try {
      const len = stat.size - start;
      const buf = Buffer.allocUnsafe(len);
      fs.readSync(fd, buf, 0, len, start);
      data = buf.toString("utf8");
    } finally { fs.closeSync(fd); }
  } catch { return null; }

  const lines = data.split("\n");
  if (start > 0) lines.shift(); // a mid-file start truncates the first line — drop it
  let inTok = 0, outTok = 0, cacheCreate = 0, cacheRead = 0, model = null;
  for (let i = lines.length - 1; i >= 0; i--) {
    const line = lines[i].trim();
    if (!line) continue;
    let o;
    try { o = JSON.parse(line); } catch { continue; }
    if (isUserPrompt(o)) break; // reached the start of the current turn
    const u = o && o.type === "assistant" && o.message && o.message.usage;
    if (u) {
      inTok += u.input_tokens || 0;
      outTok += u.output_tokens || 0;
      cacheCreate += u.cache_creation_input_tokens || 0;
      cacheRead += u.cache_read_input_tokens || 0;
      if (!model && o.message.model) model = o.message.model;
    }
  }
  if (outTok === 0 && inTok === 0 && cacheRead === 0) return null;
  const p = priceFor(model);
  const cost = p
    ? (inTok * p.in + outTok * p.out + cacheCreate * p.cacheWrite + cacheRead * p.cacheRead) / 1e6
    : 0;
  return { tokens: outTok, cost: Math.round(cost * 1e6) / 1e6 };
}

let raw = "";
process.stdin.on("data", (d) => (raw += d));
process.stdin.on("end", () => {
  let p = {};
  try { p = JSON.parse(raw || "{}"); } catch {}

  // Off by default; CLAUDE_STATUSBAR_DEBUG=1 logs every hook invocation to hooks.log.
  if (process.env.CLAUDE_STATUSBAR_DEBUG === "1") {
    try {
      fs.mkdirSync(dir, { recursive: true });
      fs.appendFileSync(path.join(dir, "hooks.log"),
        `${new Date().toISOString()} [${event}] tool=${p.tool_name || "-"} mode=${p.permission_mode || "-"} msg=${JSON.stringify(p.message || "").slice(0, 160)} keys=${Object.keys(p).join(",")}\n`);
    } catch {}
  }

  // Register the session here too, so a session that predates the hook install (never
  // fired SessionStart) still gets tracked once it does anything. See CLAUDE.md gotcha.
  // "wx" never overwrites: lifecycle.js records the claude PID in the marker at
  // SessionStart (for the stale-marker reaper), and blanking it here would disable it.
  const sid = String(p.session_id || "").replace(/[^A-Za-z0-9_.-]/g, "").slice(0, 64);
  if (sid) {
    try {
      const sessDir = path.join(dir, "sessions.d");
      fs.mkdirSync(sessDir, { recursive: true });
      fs.writeFileSync(path.join(sessDir, sid), "", { flag: "wx" });
    } catch {}
  }

  let prev = {};
  try { prev = JSON.parse(fs.readFileSync(statePath, "utf8")); } catch {}

  const project = p.cwd ? path.basename(p.cwd) : prev.project || "";
  const ts = Math.floor(Date.now() / 1000);
  let state = "idle", label = "", startedAt = prev.startedAt || 0;

  switch (event) {
    case "prompt":
      state = "thinking"; label = "Thinking…"; startedAt = ts; break;
    case "pre": {
      const t = p.tool_name || "";
      // Known tools get a friendly verb; everything else (incl. long mcp__server__method
      // names) collapses to a generic "Using tool".
      state = "tool"; label = TOOL_LABELS[t] || "Using tool";
      if (!startedAt) startedAt = ts;
      break;
    }
    case "post":
      state = "thinking"; label = "Thinking…";
      if (!startedAt) startedAt = ts;
      break;
    case "notify": {
      const m = (p.message || "").toLowerCase();
      if (m.includes("permission") || m.includes("approve") || m.includes("allow")) {
        state = "permission"; label = "Awaiting permission";
      } else if (m.includes("waiting")) {
        state = "waiting"; label = "Waiting for you";
      } else {
        state = "waiting"; label = p.message || "Waiting";
      }
      startedAt = 0;
      break;
    }
    case "permreq":
      // PermissionRequest fires the instant the approval dialog is shown, in BOTH the
      // CLI and the Desktop app (unlike Notification, which is CLI-only). Fires ~30ms
      // after `pre` so it correctly overrides the running state with the dot. On approve,
      // `post` clears it; on deny nothing fires, so the next prompt/tool/stop clears it.
      state = "permission"; label = "Awaiting permission"; startedAt = 0; break;
    case "stop":
      state = "done"; label = "Done"; startedAt = 0; break;
    default:
      return;
  }

  const transcript = p.transcript_path || prev.transcript || "";
  // Token/cost for the current turn, derived from the transcript. Only recompute while a turn
  // is live or just finished (the transcript carries usage then); otherwise carry the prior
  // value forward so a mid-turn permission prompt doesn't blank it.
  let tokens = prev.tokens, cost = prev.cost;
  if (event === "prompt") {
    tokens = 0; cost = 0; // new turn — reset until the first assistant usage lands
  } else if (event === "pre" || event === "post" || event === "stop") {
    const u = turnUsage(transcript);
    if (u) { tokens = u.tokens; cost = u.cost; }
  }
  const out = { state, label, tool: p.tool_name || "", project, sessionId: p.session_id || "", transcript, startedAt, ts, tokens: tokens || 0, cost: cost || 0 };
  try {
    fs.mkdirSync(dir, { recursive: true });
    const tmp = statePath + "." + process.pid + ".tmp";
    fs.writeFileSync(tmp, JSON.stringify(out));
    fs.renameSync(tmp, statePath);
  } catch {}

  // Per-session state, kept in a SEPARATE dir from sessions.d/ (whose plain file count
  // the macOS app uses for liveness — adding .json there would inflate it). Powers the
  // Linux widget's "active sessions" menu; cleaned up by lifecycle.js on SessionEnd.
  if (sid) {
    try {
      const stateDir = path.join(dir, "sessions-state");
      fs.mkdirSync(stateDir, { recursive: true });
      const sp = path.join(stateDir, sid + ".json");
      const stmp = sp + "." + process.pid + ".tmp";
      fs.writeFileSync(stmp, JSON.stringify(out));
      fs.renameSync(stmp, sp);
    } catch {}
  }
});
