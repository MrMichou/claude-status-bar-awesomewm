import { describe, it, expect, beforeEach, afterEach } from "vitest";
import fs from "node:fs";
import path from "node:path";
import { tmpHome, runHook, exists } from "./helpers.js";

const OUR_EVENTS = [
  "UserPromptSubmit", "PreToolUse", "PostToolUse", "Notification",
  "PermissionRequest", "Stop", "SessionStart", "SessionEnd",
];

describe("install.js — merging into settings.json", () => {
  let h, claudeDir, settingsPath;
  beforeEach(() => {
    h = tmpHome();
    claudeDir = path.join(h.home, ".claude");
    settingsPath = path.join(claudeDir, "settings.json");
    fs.mkdirSync(claudeDir, { recursive: true });
  });
  afterEach(() => h.cleanup());

  const install = () => runHook("install.js", "", "", { HOME: h.home });
  const readSettings = () => JSON.parse(fs.readFileSync(settingsPath, "utf8"));
  const ourHookCount = (s) =>
    OUR_EVENTS.flatMap((e) => s.hooks[e] || [])
      .flatMap((entry) => entry.hooks || [])
      .filter((hk) => (hk.command || "").includes("statusbar")).length;

  it("creates all 8 status-bar hooks and copies the scripts", async () => {
    await install();
    const s = readSettings();
    for (const e of OUR_EVENTS) expect(s.hooks[e], `missing ${e}`).toBeTruthy();
    expect(ourHookCount(s)).toBe(8);
    expect(exists(h.statusbar, "update.js")).toBe(true);
    expect(exists(h.statusbar, "lifecycle.js")).toBe(true);
  });

  it("installs the bundled completion sound", async () => {
    await install();
    expect(exists(h.statusbar, "completion.mp3")).toBe(true);
  });

  it("preserves a pre-existing third-party hook", async () => {
    const thirdParty = {
      hooks: {
        PreToolUse: [
          { matcher: "*", hooks: [{ type: "command", command: "/usr/bin/other-tool" }] },
        ],
      },
    };
    fs.writeFileSync(settingsPath, JSON.stringify(thirdParty));
    await install();
    const s = readSettings();
    const commands = s.hooks.PreToolUse.flatMap((e) => e.hooks).map((hk) => hk.command);
    expect(commands).toContain("/usr/bin/other-tool");
    expect(commands.some((c) => c.includes("statusbar"))).toBe(true);
  });

  it("is idempotent — re-running does not duplicate our hooks", async () => {
    await install();
    await install();
    await install();
    expect(ourHookCount(readSettings())).toBe(8);
  });

  it("backs up an existing settings.json exactly once", async () => {
    fs.writeFileSync(settingsPath, JSON.stringify({ hooks: {} }));
    const bak = settingsPath + ".bak-statusbar";
    await install();
    expect(fs.existsSync(bak)).toBe(true);
    const firstBak = fs.readFileSync(bak, "utf8");
    await install(); // second run must not overwrite the original backup
    expect(fs.readFileSync(bak, "utf8")).toBe(firstBak);
  });

  it("writes commands that invoke the copied scripts with node", async () => {
    await install();
    const s = readSettings();
    const stop = s.hooks.Stop[0].hooks[0].command;
    expect(stop).toMatch(/update\.js stop$/);
    const start = s.hooks.SessionStart[0].hooks[0].command;
    expect(start).toMatch(/lifecycle\.js start$/);
  });
});
