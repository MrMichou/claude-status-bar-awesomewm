// Shared test helpers. The hooks are CLI entry-points that read a JSON payload on
// stdin and write under $HOME/.claude/statusbar/. We exercise the real scripts in a
// subprocess with HOME pointed at a throwaway dir, so nothing touches the real ~/.claude.
import { spawn } from "node:child_process";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { fileURLToPath } from "node:url";

const __dirname = path.dirname(fileURLToPath(import.meta.url));
export const HOOKS_DIR = path.join(__dirname, "..", "hooks");

// Create an isolated fake HOME. Returns { home, statusbar, cleanup }.
export function tmpHome() {
  const home = fs.mkdtempSync(path.join(os.tmpdir(), "csb-test-"));
  return {
    home,
    statusbar: path.join(home, ".claude", "statusbar"),
    cleanup: () => fs.rmSync(home, { recursive: true, force: true }),
  };
}

// Run a hook script (e.g. "update.js") with an argv and a JSON payload on stdin.
// `env` is merged over a HOME-overridden environment. Resolves once the process exits.
export function runHook(script, arg, payload, env = {}) {
  return new Promise((resolve, reject) => {
    const args = [path.join(HOOKS_DIR, script)];
    if (arg) args.push(arg);
    const child = spawn(process.execPath, args, {
      env: { ...process.env, ...env },
      stdio: ["pipe", "pipe", "pipe"],
    });
    let stdout = "", stderr = "";
    child.stdout.on("data", (d) => (stdout += d));
    child.stderr.on("data", (d) => (stderr += d));
    child.on("error", reject);
    child.on("close", (code) => resolve({ code, stdout, stderr }));
    child.stdin.end(typeof payload === "string" ? payload : JSON.stringify(payload ?? {}));
  });
}

// Read+parse statusbar/state.json (null if absent).
export function readState(statusbar) {
  try { return JSON.parse(fs.readFileSync(path.join(statusbar, "state.json"), "utf8")); }
  catch { return null; }
}

// Read+parse a per-session state file (null if absent).
export function readSessionState(statusbar, sid) {
  try { return JSON.parse(fs.readFileSync(path.join(statusbar, "sessions-state", sid + ".json"), "utf8")); }
  catch { return null; }
}

export const exists = (...p) => fs.existsSync(path.join(...p));
