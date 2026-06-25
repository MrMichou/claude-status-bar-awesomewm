import { describe, it, expect, beforeEach, afterEach } from "vitest";
import fs from "node:fs";
import path from "node:path";
import { tmpHome, runHook } from "./helpers.js";

describe("uninstall.js — removing our hooks", () => {
  let h, settingsPath;
  beforeEach(() => {
    h = tmpHome();
    const claudeDir = path.join(h.home, ".claude");
    settingsPath = path.join(claudeDir, "settings.json");
    fs.mkdirSync(claudeDir, { recursive: true });
  });
  afterEach(() => h.cleanup());

  const install = () => runHook("install.js", "", "", { HOME: h.home });
  const uninstall = () => runHook("uninstall.js", "", "", { HOME: h.home });
  const readSettings = () => JSON.parse(fs.readFileSync(settingsPath, "utf8"));

  it("removes every status-bar hook while keeping third-party hooks", async () => {
    fs.writeFileSync(settingsPath, JSON.stringify({
      hooks: {
        PreToolUse: [{ matcher: "*", hooks: [{ type: "command", command: "/usr/bin/other-tool" }] }],
      },
    }));
    await install();
    await uninstall();
    const s = readSettings();
    const allCommands = Object.values(s.hooks || {})
      .flat().flatMap((e) => e.hooks || []).map((hk) => hk.command);
    expect(allCommands.some((c) => c.includes("statusbar"))).toBe(false);
    expect(allCommands).toContain("/usr/bin/other-tool");
  });

  it("drops event keys that become empty after removal", async () => {
    await install(); // adds our hooks to events that had none before
    await uninstall();
    const s = readSettings();
    // Stop only ever held our hook, so the key should be gone entirely.
    expect(s.hooks.Stop).toBeUndefined();
  });

  it("is a no-op with a helpful message when settings.json is absent", async () => {
    fs.rmSync(settingsPath, { force: true });
    const { code, stdout } = await uninstall();
    expect(code).toBe(0);
    expect(stdout.toLowerCase()).toContain("nothing to do");
  });
});
