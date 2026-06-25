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
});
