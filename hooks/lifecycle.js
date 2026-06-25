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
const event = process.argv[2];

fs.mkdirSync(sessDir, { recursive: true });

const running = () => { try { cp.execSync(`pgrep -x ${EXEC}`, { stdio: "ignore" }); return true; } catch { return false; } };
const safeId = (s) => String(s || "").replace(/[^A-Za-z0-9_.-]/g, "").slice(0, 64) || "unknown";

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
      // Crash-safety: drop per-session state files that no longer have a live marker.
      try {
        const markers = new Set(fs.readdirSync(sessDir));
        for (const f of fs.readdirSync(stateDir)) {
          if (!markers.has(f.replace(/\.json$/, ""))) fs.rmSync(path.join(stateDir, f), { force: true });
        }
      } catch {}
    }
    try { fs.writeFileSync(path.join(sessDir, id), ""); } catch {}
    // Launching the app is macOS-only: on Linux the indicator is an always-running
    // awesomewm widget polling state.json, so there is nothing to spawn here.
    if (process.platform === "darwin") {
      cp.spawn("open", ["-g", "-b", BUNDLE_ID], { stdio: "ignore", detached: true }).unref();
    }
  } else if (event === "end") {
    try { fs.rmSync(path.join(sessDir, id), { force: true }); } catch {}
    try { fs.rmSync(path.join(stateDir, id + ".json"), { force: true }); } catch {}
  }
  process.exit(0);
}
