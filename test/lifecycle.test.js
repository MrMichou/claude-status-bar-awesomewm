import { describe, it, expect, beforeEach, afterEach } from "vitest";
import { spawn } from "node:child_process";
import fs from "node:fs";
import path from "node:path";
import { tmpHome, runHook, exists, HOOKS_DIR } from "./helpers.js";

// lifecycle.js branches on platform. We force Linux behaviour (the macOS branch shells
// out to `open`/`launchctl`). The script reads process.platform, not an env var, so the
// tests below assert only the cross-platform file bookkeeping, which runs on every OS.
describe("lifecycle.js — session tracking", () => {
  let h;
  beforeEach(() => { h = tmpHome(); });
  afterEach(() => h.cleanup());

  const run = (arg, payload) => runHook("lifecycle.js", arg, payload, { HOME: h.home });
  const sessFile = (id) => path.join(h.statusbar, "sessions.d", id);
  const stateFile = (id) => path.join(h.statusbar, "sessions-state", id + ".json");
  const winFile = (id) => path.join(h.statusbar, "sessions-win", id);

  it("start creates a session marker", async () => {
    await run("start", { session_id: "s1" });
    expect(exists(sessFile("s1"))).toBe(true);
  });

  it("end removes marker, per-session state and window file", async () => {
    fs.mkdirSync(path.dirname(sessFile("s1")), { recursive: true });
    fs.mkdirSync(path.dirname(stateFile("s1")), { recursive: true });
    fs.mkdirSync(path.dirname(winFile("s1")), { recursive: true });
    fs.writeFileSync(sessFile("s1"), "");
    fs.writeFileSync(stateFile("s1"), "{}");
    fs.writeFileSync(winFile("s1"), "12345");

    await run("end", { session_id: "s1" });

    expect(exists(sessFile("s1"))).toBe(false);
    expect(exists(stateFile("s1"))).toBe(false);
    expect(exists(winFile("s1"))).toBe(false);
  });

  it("sanitizes the session id (no path escape, fallback to 'unknown')", async () => {
    await run("start", { session_id: "../../x y" });
    const files = fs.readdirSync(path.join(h.statusbar, "sessions.d"));
    expect(files).toHaveLength(1);
    expect(files[0]).not.toMatch(/[/ ]/);

    const h2 = tmpHome();
    await runHook("lifecycle.js", "start", {}, { HOME: h2.home });
    expect(fs.existsSync(path.join(h2.statusbar, "sessions.d", "unknown"))).toBe(true);
    h2.cleanup();
  });

  // Crash-safety (non-darwin branch): on start, per-session state with no live marker is
  // purged, but state that still has a marker survives.
  it("on start, purges orphaned per-session state but keeps live ones", async () => {
    if (process.platform === "darwin") return; // darwin takes a different cleanup path
    fs.mkdirSync(path.join(h.statusbar, "sessions.d"), { recursive: true });
    fs.mkdirSync(path.join(h.statusbar, "sessions-state"), { recursive: true });
    // live: marker + state
    fs.writeFileSync(sessFile("live"), "");
    fs.writeFileSync(stateFile("live"), "{}");
    // orphan: state but no marker
    fs.writeFileSync(stateFile("orphan"), "{}");

    await run("start", { session_id: "new" });

    expect(exists(stateFile("live"))).toBe(true);
    expect(exists(stateFile("orphan"))).toBe(false);
    expect(exists(sessFile("new"))).toBe(true);
  });

  // Reaper (non-darwin): a marker recording a dead claude PID is removed at start,
  // together with its per-session state; live-PID and legacy empty markers survive.
  it("on start, reaps markers whose recorded pid is dead, keeps live and pid-less ones", async () => {
    if (process.platform === "darwin") return;
    fs.mkdirSync(path.join(h.statusbar, "sessions.d"), { recursive: true });
    fs.mkdirSync(path.join(h.statusbar, "sessions-state"), { recursive: true });
    fs.mkdirSync(path.join(h.statusbar, "sessions-win"), { recursive: true });

    // A pid that existed but is guaranteed dead: spawn a no-op child and wait for it.
    const child = spawn(process.execPath, ["-e", ""], { stdio: "ignore" });
    const deadPid = child.pid;
    await new Promise((r) => child.on("close", r));

    fs.writeFileSync(sessFile("dead"), String(deadPid));
    fs.writeFileSync(stateFile("dead"), "{}");
    fs.writeFileSync(winFile("dead"), "12345");
    fs.writeFileSync(sessFile("alive"), String(process.pid));
    fs.writeFileSync(sessFile("legacy"), "");

    await run("start", { session_id: "new" });

    expect(exists(sessFile("dead"))).toBe(false);
    expect(exists(stateFile("dead"))).toBe(false);
    expect(exists(winFile("dead"))).toBe(false);
    expect(exists(sessFile("alive"))).toBe(true);
    expect(exists(sessFile("legacy"))).toBe(true);
  });

  // The marker records the PID of the nearest ancestor whose comm is "claude", found
  // by walking /proc. Simulated with a wrapper node process titled "claude" (node's
  // title setter uses prctl(PR_SET_NAME) on Linux, which is what /proc/<pid>/comm shows).
  it("start records the claude ancestor pid in the marker (Linux)", async () => {
    if (process.platform !== "linux") return;
    const hookPath = path.join(HOOKS_DIR, "lifecycle.js");
    const wrapperSrc = `
      process.title = "claude";
      const cp = require("child_process");
      const c = cp.spawn(process.execPath, [${JSON.stringify(hookPath)}, "start"],
        { env: process.env, stdio: ["pipe", "ignore", "ignore"] });
      c.stdin.end(JSON.stringify({ session_id: "pidtest" }));
      c.on("close", (code) => process.exit(code ?? 1));
    `;
    const wrapper = spawn(process.execPath, ["-e", wrapperSrc], {
      env: { ...process.env, HOME: h.home },
      stdio: "ignore",
    });
    await new Promise((r) => wrapper.on("close", r));

    const marker = fs.readFileSync(sessFile("pidtest"), "utf8");
    expect(marker).toBe(String(wrapper.pid));
  });
});
