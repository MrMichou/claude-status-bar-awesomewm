import { describe, it, expect, beforeEach, afterEach } from "vitest";
import { createRequire } from "node:module";
import fs from "node:fs";
import path from "node:path";
import { tmpHome, runHook, HOOKS_DIR } from "./helpers.js";

// File-writing paths run the real script in a subprocess with HOME overridden (like the
// other hook tests); the pure functions (mapResponse, fetchUsage) are require()d in-process.
const { mapResponse, fetchUsage } = createRequire(import.meta.url)(path.join(HOOKS_DIR, "usage.js"));

describe("usage.js — quota fetch & mapping", () => {
  let h;
  beforeEach(() => { h = tmpHome(); });
  afterEach(() => h.cleanup());

  const quotaFile = () => path.join(h.statusbar, "quota.json");
  const credsFile = () => path.join(h.home, ".claude", ".credentials.json");
  const readQuota = () => JSON.parse(fs.readFileSync(quotaFile(), "utf8"));

  it("mapResponse maps windows to pct + epoch resetsAt and ignores unknown keys", () => {
    const now = Date.UTC(2026, 0, 1);
    const out = mapResponse({
      five_hour: { utilization: 12.5, resets_at: "2026-01-01T05:00:00.000Z" },
      seven_day: { utilization: 30, resets_at: "2026-01-07T00:00:00Z" },
      seven_day_sonnet: { utilization: 5 },
      extra_usage: { spend: 3 },
    }, now);
    expect(out.fiveHour).toEqual({ pct: 12.5, resetsAt: Date.UTC(2026, 0, 1, 5) / 1000 });
    expect(out.sevenDay.pct).toBe(30);
    expect(out.sevenDayOpus).toBeUndefined();
    expect(out.fetchedAt).toBe(now / 1000);
    expect(out.error).toBeNull();
    expect(out).not.toHaveProperty("seven_day_sonnet");
  });

  it("mapResponse drops windows without a numeric utilization", () => {
    const out = mapResponse({ five_hour: { resets_at: "2026-01-01T05:00:00Z" }, seven_day: null });
    expect(out.fiveHour).toBeUndefined();
    expect(out.sevenDay).toBeUndefined();
  });

  it("missing credentials → quota.json carries no_token but keeps previous windows", async () => {
    fs.mkdirSync(h.statusbar, { recursive: true });
    fs.writeFileSync(quotaFile(), JSON.stringify({ fiveHour: { pct: 40, resetsAt: 123 }, error: null }));
    // Age the file past the throttle so the run doesn't skip.
    const old = new Date(Date.now() - 120000);
    fs.utimesSync(quotaFile(), old, old);

    await runHook("usage.js", undefined, {}, { HOME: h.home });

    const q = readQuota();
    expect(q.error).toBe("no_token");
    expect(q.fiveHour).toEqual({ pct: 40, resetsAt: 123 }); // previous windows preserved
    expect(q.checkedAt).toBeGreaterThan(0);
  });

  it("expired token → no_token (no fetch attempted)", async () => {
    fs.mkdirSync(path.dirname(credsFile()), { recursive: true });
    fs.writeFileSync(credsFile(), JSON.stringify({
      claudeAiOauth: { accessToken: "sk-ant-oat-test", expiresAt: Date.now() - 1000 },
    }));
    await runHook("usage.js", undefined, {}, { HOME: h.home });
    expect(readQuota().error).toBe("no_token");
  });

  it("skips entirely when quota.json is fresher than the throttle", async () => {
    fs.mkdirSync(h.statusbar, { recursive: true });
    fs.writeFileSync(quotaFile(), JSON.stringify({ error: "sentinel" }));
    await runHook("usage.js", undefined, {}, { HOME: h.home });
    // A run would have rewritten error to no_token (no creds); the sentinel proves the skip.
    expect(readQuota().error).toBe("sentinel");
  });

  it("fetchUsage returns http_<code> on non-200 and network on throw", async () => {
    const r429 = await fetchUsage("tok", async () => ({ status: 429 }));
    expect(r429.error).toBe("http_429");
    const rNet = await fetchUsage("tok", async () => { throw new Error("boom"); });
    expect(rNet.error).toBe("network");
    const rOk = await fetchUsage("tok", async () => ({ status: 200, json: async () => ({ a: 1 }) }));
    expect(rOk.body).toEqual({ a: 1 });
  });
});
