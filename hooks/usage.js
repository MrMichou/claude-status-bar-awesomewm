#!/usr/bin/env node
// Fetches Claude rate-limit utilization from Anthropic's OAuth usage endpoint and
// writes ~/.claude/statusbar/quota.json for the widget's quota gauge (issue #68).
// Spawned detached by update.js while sessions are active; throttled here too so
// concurrent triggers collapse into one fetch. The access token is read from
// Claude Code's own credentials and sent ONLY to the hardcoded Anthropic host —
// never logged, never written anywhere else. No refresh logic: an expired token
// just marks the data stale (Claude Code refreshes it while you work, which is
// exactly when quota matters).

const fs = require("fs");
const os = require("os");
const path = require("path");

// Hardcoded on purpose (SSRF guard) — same rule as the widget's service_url.
const USAGE_URL = "https://api.anthropic.com/api/oauth/usage";
const BETA_HEADER = "oauth-2025-04-20";
const THROTTLE_SECONDS = 45; // quota.json fresher than this → skip entirely
const FETCH_TIMEOUT_MS = 10000;

const dir = path.join(os.homedir(), ".claude", "statusbar");
const quotaPath = path.join(dir, "quota.json");
const credsPath = path.join(os.homedir(), ".claude", ".credentials.json");

// True when quota.json is fresh enough that fetching again would be wasteful.
function shouldSkip(now = Date.now()) {
  try { return now - fs.statSync(quotaPath).mtimeMs < THROTTLE_SECONDS * 1000; }
  catch { return false; }
}

function readPrevious() {
  try { return JSON.parse(fs.readFileSync(quotaPath, "utf8")); } catch { return {}; }
}

// Map the endpoint's response to the widget's schema. Times become epoch seconds
// (Lua-friendly); unknown keys are ignored. Windows without a utilization are dropped.
function mapResponse(body, now = Date.now()) {
  const win = (w) => {
    if (!w || typeof w.utilization !== "number") return undefined;
    const reset = Date.parse(w.resets_at || "");
    return { pct: w.utilization, resetsAt: Number.isFinite(reset) ? Math.floor(reset / 1000) : 0 };
  };
  const out = { fetchedAt: Math.floor(now / 1000), error: null };
  const fiveHour = win(body.five_hour);
  const sevenDay = win(body.seven_day);
  const sevenDayOpus = win(body.seven_day_opus);
  if (fiveHour) out.fiveHour = fiveHour;
  if (sevenDay) out.sevenDay = sevenDay;
  if (sevenDayOpus) out.sevenDayOpus = sevenDayOpus;
  return out;
}

// Atomic write, same tmp+rename idiom as update.js's state writes.
function writeQuota(data) {
  fs.mkdirSync(dir, { recursive: true });
  const tmp = quotaPath + "." + process.pid + ".tmp";
  fs.writeFileSync(tmp, JSON.stringify(data));
  fs.renameSync(tmp, quotaPath);
}

// Keep the previous windows (the countdown stays computable from their absolute
// reset times) but flag why they stopped updating.
function writeError(error, now = Date.now()) {
  const prev = readPrevious();
  writeQuota({ ...prev, error, checkedAt: Math.floor(now / 1000) });
}

function readAccessToken(now = Date.now()) {
  let creds;
  try { creds = JSON.parse(fs.readFileSync(credsPath, "utf8")); } catch { return null; }
  const oauth = creds && creds.claudeAiOauth;
  if (!oauth || !oauth.accessToken) return null;
  if (typeof oauth.expiresAt === "number" && oauth.expiresAt <= now) return null;
  return oauth.accessToken;
}

async function fetchUsage(token, doFetch = fetch) {
  const ctl = new AbortController();
  const timer = setTimeout(() => ctl.abort(), FETCH_TIMEOUT_MS);
  try {
    const res = await doFetch(USAGE_URL, {
      headers: {
        Authorization: `Bearer ${token}`,
        Accept: "application/json",
        "anthropic-beta": BETA_HEADER,
      },
      signal: ctl.signal,
    });
    if (res.status !== 200) return { error: `http_${res.status}` };
    return { body: await res.json() };
  } catch {
    return { error: "network" };
  } finally { clearTimeout(timer); }
}

async function main() {
  if (shouldSkip()) return;
  const token = readAccessToken();
  if (!token) { writeError("no_token"); return; }
  const r = await fetchUsage(token);
  if (r.error) { writeError(r.error); return; }
  writeQuota(mapResponse(r.body));
}

module.exports = { shouldSkip, mapResponse, writeQuota, writeError, readAccessToken, fetchUsage, quotaPath };

if (require.main === module) main().then(() => process.exit(0), () => process.exit(0));
