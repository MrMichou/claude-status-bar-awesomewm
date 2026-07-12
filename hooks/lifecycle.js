#!/usr/bin/env node
// SessionStart/SessionEnd: launch the app, and track sessions as one file per session id
// in sessions.d/ (race-free; the app quits itself). Rationale + history in CLAUDE.md.
// Usage: node lifecycle.js <start|end>   (hook JSON, incl. session_id, arrives on stdin)

const fs = require("fs");
const os = require("os");
const path = require("path");
const cp = require("child_process");

const BUNDLE_ID = "com.local.claudestatusbar";
const EXEC = "ClaudeStatusBar";
const dir = path.join(os.homedir(), ".claude", "statusbar");
const sessDir = path.join(dir, "sessions.d");
const stateDir = path.join(dir, "sessions-state"); // per-session state.json files (widget menu)
const winDir = path.join(dir, "sessions-win"); // per-session X11 window id (Linux "jump to window")
const event = process.argv[2];

fs.mkdirSync(sessDir, { recursive: true });

const running = () => { try { cp.execSync(`pgrep -x ${EXEC}`, { stdio: "ignore" }); return true; } catch { return false; } };
const safeId = (s) => String(s || "").replace(/[^A-Za-z0-9_.-]/g, "").slice(0, 64) || "unknown";

// Linux: resolve this session's `claude` PID by walking the hook's ancestry in /proc
// (node → shell → claude). Stored in the marker so a later SessionStart can reap
// markers whose process died without SessionEnd (killed terminal, crash, reboot).
// Returns 0 when unresolvable (non-Linux, unexpected comm) — the marker then stays
// empty and is never reaped, which is exactly the pre-reaper behavior.
function claudePid() {
  let pid = process.ppid;
  for (let i = 0; i < 20 && pid > 1; i++) {
    try {
      if (fs.readFileSync(`/proc/${pid}/comm`, "utf8").trim() === "claude") return pid;
      const stat = fs.readFileSync(`/proc/${pid}/stat`, "utf8");
      pid = parseInt(stat.slice(stat.lastIndexOf(")") + 2).split(" ")[1], 10);
    } catch { return 0; }
  }
  return 0;
}

const alive = (pid) => { try { return process.kill(pid, 0), true; } catch (e) { return e.code === "EPERM"; } };

// Linux/X11: remember which window hosts this session so the widget menu can jump to it.
// At SessionStart the terminal where `claude` was launched is the focused window, so the
// _NET_ACTIVE_WINDOW is that terminal. Stored as a decimal id matching awesome's c.window.
// (terminator & friends share one PID across windows, so we key on the window id, not pid.)
function captureWindow(id) {
  if (process.platform === "darwin") return;
  try {
    const out = cp.execSync("xprop -root _NET_ACTIVE_WINDOW", { stdio: ["ignore", "pipe", "ignore"] }).toString();
    const hex = out.match(/0x[0-9a-fA-F]+/);
    if (!hex) return;
    const wid = parseInt(hex[0], 16);
    if (!wid) return;
    fs.mkdirSync(winDir, { recursive: true });
    fs.writeFileSync(path.join(winDir, id), String(wid));
  } catch {}
}

let input = "", done = false;
process.stdin.on("data", (d) => (input += d));
process.stdin.on("end", () => run());
process.stdin.on("error", () => run());
setTimeout(run, 1000); // hooks always pipe stdin, but never hang the session

function run() {
  if (done) return; done = true;
  let id = "";
  try { id = JSON.parse(input).session_id; } catch {}
  id = safeId(id);

  if (event === "start") {
    // macOS only: the app process is the liveness signal, so if it isn't running any
    // leftover markers are stale (prior crash) — clear them so the count starts honest.
    // On Linux the indicator is the always-running awesomewm widget, so there is no
    // such "app restarted" moment; wiping here would drop other live sessions' markers.
    if (process.platform === "darwin") {
      if (!running()) {
        try { for (const f of fs.readdirSync(sessDir)) fs.rmSync(path.join(sessDir, f), { force: true }); } catch {}
        try { for (const f of fs.readdirSync(stateDir)) fs.rmSync(path.join(stateDir, f), { force: true }); } catch {}
      }
    } else {
      // Reap markers whose recorded claude PID is dead — their SessionEnd never fired.
      // Markers with no PID (legacy, or claudePid() failed at their start) are kept:
      // we can't tell dead from alive, and keeping them is the pre-reaper behavior.
      try {
        for (const f of fs.readdirSync(sessDir)) {
          const pid = parseInt(fs.readFileSync(path.join(sessDir, f), "utf8"), 10);
          if (pid > 0 && !alive(pid)) fs.rmSync(path.join(sessDir, f), { force: true });
        }
      } catch {}
      // Crash-safety: drop per-session state files that no longer have a live marker.
      try {
        const markers = new Set(fs.readdirSync(sessDir));
        for (const f of fs.readdirSync(stateDir)) {
          if (!markers.has(f.replace(/\.json$/, ""))) fs.rmSync(path.join(stateDir, f), { force: true });
        }
        for (const f of fs.readdirSync(winDir)) {
          if (!markers.has(f)) fs.rmSync(path.join(winDir, f), { force: true });
        }
      } catch {}
    }
    try { fs.writeFileSync(path.join(sessDir, id), String(claudePid() || "")); } catch {}
    captureWindow(id);
    // Launching the app is macOS-only: on Linux the indicator is an always-running
    // awesomewm widget polling state.json, so there is nothing to spawn here.
    if (process.platform === "darwin") {
      cp.spawn("open", ["-g", "-b", BUNDLE_ID], { stdio: "ignore", detached: true }).unref();
    }
  } else if (event === "end") {
    try { fs.rmSync(path.join(sessDir, id), { force: true }); } catch {}
    try { fs.rmSync(path.join(stateDir, id + ".json"), { force: true }); } catch {}
    try { fs.rmSync(path.join(winDir, id), { force: true }); } catch {}
  }
  process.exit(0);
}
