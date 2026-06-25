import { describe, it, expect } from "vitest";
import fs from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";

const root = path.join(path.dirname(fileURLToPath(import.meta.url)), "..");
const readJSON = (rel) => JSON.parse(fs.readFileSync(path.join(root, rel), "utf8"));

describe("config files are valid JSON and coherent", () => {
  it("plugin.json parses and has a semver version", () => {
    const p = readJSON(".claude-plugin/plugin.json");
    expect(p.name).toBeTruthy();
    expect(p.version).toMatch(/^\d+\.\d+\.\d+/);
  });

  it("marketplace.json parses and lists the plugin", () => {
    const m = readJSON(".claude-plugin/marketplace.json");
    expect(Array.isArray(m.plugins)).toBe(true);
    expect(m.plugins.length).toBeGreaterThan(0);
  });

  it("plugin.json and marketplace.json agree on name + version", () => {
    const p = readJSON(".claude-plugin/plugin.json");
    const m = readJSON(".claude-plugin/marketplace.json");
    const entry = m.plugins.find((x) => x.name === p.name);
    expect(entry, "marketplace has no entry matching plugin.json name").toBeTruthy();
    expect(entry.version).toBe(p.version);
  });

  it("hooks.json parses and every hook is a node command", () => {
    const h = readJSON("hooks/hooks.json");
    const commands = Object.values(h.hooks)
      .flat().flatMap((e) => e.hooks || []).map((hk) => hk.command);
    expect(commands.length).toBeGreaterThan(0);
    for (const c of commands) expect(c).toMatch(/^node /);
  });
});
