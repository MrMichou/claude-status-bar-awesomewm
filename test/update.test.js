import { describe, it, expect, beforeEach, afterEach } from "vitest";
import fs from "node:fs";
import path from "node:path";
import { tmpHome, runHook, readState, readSessionState, exists } from "./helpers.js";

describe("update.js — event → state mapping", () => {
  let h;
  beforeEach(() => { h = tmpHome(); });
  afterEach(() => h.cleanup());

  const run = (arg, payload) => runHook("update.js", arg, payload, { HOME: h.home });

  it("prompt → thinking and stamps startedAt", async () => {
    await run("prompt", { session_id: "s1", cwd: "/tmp/myproj" });
    const s = readState(h.statusbar);
    expect(s.state).toBe("thinking");
    expect(s.label).toBe("Thinking…");
    expect(s.project).toBe("myproj");
    expect(s.startedAt).toBeGreaterThan(0);
  });

  it("registers an unknown session but never overwrites an existing marker's PID", async () => {
    const marker = path.join(h.statusbar, "sessions.d", "s1");
    await run("prompt", { session_id: "s1" });
    // Late registration: a PID if the test runner itself has a claude ancestor (tests
    // launched from a Claude session), empty otherwise — digits-only either way.
    expect(fs.readFileSync(marker, "utf8")).toMatch(/^\d*$/);
    fs.writeFileSync(marker, "12345"); // as written by lifecycle.js at SessionStart
    await run("pre", { session_id: "s1", tool_name: "Bash" });
    expect(fs.readFileSync(marker, "utf8")).toBe("12345"); // reaper PID preserved
  });

  // Late registration records the claude ancestor PID (like lifecycle.js does), so the
  // marker stays reapable. Simulated with a wrapper node process titled "claude".
  it("late registration records the claude ancestor pid (Linux)", async () => {
    if (process.platform !== "linux") return;
    const { spawn } = await import("node:child_process");
    const { HOOKS_DIR } = await import("./helpers.js");
    const hookPath = path.join(HOOKS_DIR, "update.js");
    const wrapperSrc = `
      process.title = "claude";
      const cp = require("child_process");
      const c = cp.spawn(process.execPath, [${JSON.stringify(hookPath)}, "prompt"],
        { env: process.env, stdio: ["pipe", "ignore", "ignore"] });
      c.stdin.end(JSON.stringify({ session_id: "latepid" }));
      c.on("close", (code) => process.exit(code ?? 1));
    `;
    const wrapper = spawn(process.execPath, ["-e", wrapperSrc], {
      env: { ...process.env, HOME: h.home },
      stdio: "ignore",
    });
    await new Promise((r) => wrapper.on("close", r));
    const marker = path.join(h.statusbar, "sessions.d", "latepid");
    expect(fs.readFileSync(marker, "utf8")).toBe(String(wrapper.pid));
  });

  // Quota-gauge trigger (#68): with show_quota enabled and no fresh quota.json, an event
  // spawns usage.js detached, which (with no credentials in the fake HOME) writes a
  // no_token quota.json. Without the opt-in, nothing is written.
  it("spawns the quota fetch when widget.json opts in, not otherwise", async () => {
    const quota = path.join(h.statusbar, "quota.json");
    const waitFor = async (pred, ms = 3000) => {
      const end = Date.now() + ms;
      while (Date.now() < end) {
        if (pred()) return true;
        await new Promise((r) => setTimeout(r, 50));
      }
      return pred();
    };

    await run("prompt", { session_id: "s1" }); // no widget.json → no fetch
    await new Promise((r) => setTimeout(r, 300));
    expect(fs.existsSync(quota)).toBe(false);

    fs.writeFileSync(path.join(h.statusbar, "widget.json"), JSON.stringify({ show_quota: true }));
    await run("prompt", { session_id: "s1" });
    expect(await waitFor(() => fs.existsSync(quota))).toBe(true);
    expect(JSON.parse(fs.readFileSync(quota, "utf8")).error).toBe("no_token");
  });

  it("notify_quota alone also opts into the quota fetch (#69)", async () => {
    const quota = path.join(h.statusbar, "quota.json");
    fs.mkdirSync(h.statusbar, { recursive: true });
    fs.writeFileSync(path.join(h.statusbar, "widget.json"), JSON.stringify({ notify_quota: true }));
    await run("prompt", { session_id: "s1" });
    const end = Date.now() + 3000;
    while (Date.now() < end && !fs.existsSync(quota)) await new Promise((r) => setTimeout(r, 50));
    expect(fs.existsSync(quota)).toBe(true);
  });

  it("pre with known tool → friendly verb", async () => {
    await run("pre", { session_id: "s1", tool_name: "Bash" });
    expect(readState(h.statusbar).label).toBe("Running command");
  });

  it("pre with Edit/Write/Read map to their verbs", async () => {
    await run("pre", { session_id: "s1", tool_name: "Edit" });
    expect(readState(h.statusbar).label).toBe("Editing");
    await run("pre", { session_id: "s1", tool_name: "Read" });
    expect(readState(h.statusbar).label).toBe("Reading");
  });

  it("pre with unknown / mcp tool → generic 'Using tool'", async () => {
    await run("pre", { session_id: "s1", tool_name: "mcp__server__method" });
    const s = readState(h.statusbar);
    expect(s.state).toBe("tool");
    expect(s.label).toBe("Using tool");
  });

  it("post → thinking", async () => {
    await run("post", { session_id: "s1" });
    expect(readState(h.statusbar).label).toBe("Thinking…");
  });

  it("permreq → permission, startedAt reset", async () => {
    await run("permreq", { session_id: "s1" });
    const s = readState(h.statusbar);
    expect(s.state).toBe("permission");
    expect(s.label).toBe("Awaiting permission");
    expect(s.startedAt).toBe(0);
  });

  it("stop → done", async () => {
    await run("stop", { session_id: "s1" });
    const s = readState(h.statusbar);
    expect(s.state).toBe("done");
    expect(s.label).toBe("Done");
  });

  describe("notify classification", () => {
    it("permission-ish message → permission", async () => {
      await run("notify", { session_id: "s1", message: "Claude needs your permission to use Bash" });
      const s = readState(h.statusbar);
      expect(s.state).toBe("permission");
      expect(s.label).toBe("Awaiting permission");
    });
    it("waiting message → waiting", async () => {
      await run("notify", { session_id: "s1", message: "Claude is waiting for your input" });
      expect(readState(h.statusbar).state).toBe("waiting");
    });
    it("free-form message → waiting with the message as label", async () => {
      await run("notify", { session_id: "s1", message: "Custom note" });
      const s = readState(h.statusbar);
      expect(s.state).toBe("waiting");
      expect(s.label).toBe("Custom note");
    });
  });

  it("unknown event writes nothing", async () => {
    await run("bogus", { session_id: "s1" });
    expect(readState(h.statusbar)).toBeNull();
  });

  it("registers the session marker and per-session state", async () => {
    await run("prompt", { session_id: "abc123" });
    expect(exists(h.statusbar, "sessions.d", "abc123")).toBe(true);
    expect(readSessionState(h.statusbar, "abc123").state).toBe("thinking");
  });

  it("sanitizes the session id used for filenames", async () => {
    await run("prompt", { session_id: "../../evil id!" });
    // the slashes/spaces/bang are stripped; nothing escapes sessions.d
    const dir = path.join(h.statusbar, "sessions.d");
    const files = fs.readdirSync(dir);
    expect(files).toHaveLength(1);
    expect(files[0]).not.toContain("/");
    expect(files[0]).not.toContain(" ");
  });

  it("carries startedAt and transcript forward from prior state", async () => {
    await run("prompt", { session_id: "s1", transcript_path: "/t/conv.jsonl" });
    const first = readState(h.statusbar);
    await run("pre", { session_id: "s1", tool_name: "Bash" });
    const second = readState(h.statusbar);
    expect(second.startedAt).toBe(first.startedAt);
    expect(second.transcript).toBe("/t/conv.jsonl");
  });

  it("writes a debug log when CLAUDE_STATUSBAR_DEBUG=1", async () => {
    await runHook("update.js", "prompt", { session_id: "s1" }, { HOME: h.home, CLAUDE_STATUSBAR_DEBUG: "1" });
    expect(exists(h.statusbar, "hooks.log")).toBe(true);
  });

  describe("token / cost from transcript (#21)", () => {
    // Write a JSONL transcript: a user prompt, then assistant turns carrying usage.
    const writeTranscript = (lines) => {
      const p = path.join(h.home, "conv.jsonl");
      fs.writeFileSync(p, lines.map((l) => JSON.stringify(l)).join("\n") + "\n");
      return p;
    };
    const usage = (u) => ({ type: "assistant", message: { model: "claude-opus-4-8", usage: u } });

    it("sums the current turn's output tokens and estimates cost", async () => {
      const tr = writeTranscript([
        { type: "user", message: { content: "do a thing" } },
        usage({ input_tokens: 100, output_tokens: 400, cache_read_input_tokens: 10000, cache_creation_input_tokens: 2000 }),
        usage({ input_tokens: 50, output_tokens: 600, cache_read_input_tokens: 12000, cache_creation_input_tokens: 0 }),
      ]);
      await run("post", { session_id: "s1", transcript_path: tr });
      const s = readState(h.statusbar);
      expect(s.tokens).toBe(1000); // 400 + 600 output tokens this turn
      // cost = (150*5 + 1000*25 + 2000*6.25 + 22000*0.5) / 1e6 USD
      const expected = (150 * 5 + 1000 * 25 + 2000 * 6.25 + 22000 * 0.5) / 1e6;
      expect(s.cost).toBeCloseTo(expected, 6);
    });

    it("counts only the latest turn (resets at the last user prompt)", async () => {
      const tr = writeTranscript([
        { type: "user", message: { content: "first turn" } },
        usage({ output_tokens: 5000 }),
        { type: "user", message: { content: "second turn" } },
        usage({ output_tokens: 700 }),
      ]);
      await run("post", { session_id: "s1", transcript_path: tr });
      expect(readState(h.statusbar).tokens).toBe(700);
    });

    it("does not count tool_result user messages as a turn boundary", async () => {
      const tr = writeTranscript([
        { type: "user", message: { content: "go" } },
        usage({ output_tokens: 300 }),
        { type: "user", message: { content: [{ type: "tool_result", tool_use_id: "t1", content: "ok" }] } },
        usage({ output_tokens: 200 }),
      ]);
      await run("post", { session_id: "s1", transcript_path: tr });
      expect(readState(h.statusbar).tokens).toBe(500); // both assistant turns counted
    });

    it("prompt resets tokens/cost to 0", async () => {
      await run("prompt", { session_id: "s1" });
      const s = readState(h.statusbar);
      expect(s.tokens).toBe(0);
      expect(s.cost).toBe(0);
    });
  });
});
