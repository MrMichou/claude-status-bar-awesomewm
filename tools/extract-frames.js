#!/usr/bin/env node
// Extracts the base64-encoded PNG frames embedded in the macOS Swift sources into
// real .png files for the Linux/awesomewm widget (which feeds them to an imagebox).
// Run from anywhere: `node tools/extract-frames.js`. Idempotent.
//
// Sources (one base64 PNG per match, in declaration order):
//   Sources/SparkFrames.swift  -> frames/web/NN.png   (alpha masks, tinted at runtime)
//   Sources/CrabFrames.swift   -> frames/crab/NN.png  (full color)
//   Sources/LogoFrame.swift    -> frames/logo.png     (alpha mask, resting icon)

const fs = require("fs");
const path = require("path");

const repo = path.resolve(__dirname, "..");
const srcDir = path.join(repo, "Sources");
const outDir = path.join(repo, "linux", "awesomewm", "claude_status", "frames");

// Every embedded PNG's base64 starts with the PNG signature "iVBOR".
const PNG_B64 = /"(iVBOR[A-Za-z0-9+/=]+)"/g;

function extract(file) {
  const text = fs.readFileSync(path.join(srcDir, file), "utf8");
  const out = [];
  let m;
  while ((m = PNG_B64.exec(text))) out.push(Buffer.from(m[1], "base64"));
  return out;
}

function writeSet(buffers, dir, single) {
  fs.mkdirSync(dir, { recursive: true });
  if (single) {
    fs.writeFileSync(path.join(dir, single), buffers[0]);
    return 1;
  }
  // Wipe stale frames so a shorter set doesn't leave orphans.
  for (const f of fs.readdirSync(dir)) if (f.endsWith(".png")) fs.rmSync(path.join(dir, f));
  buffers.forEach((b, i) => fs.writeFileSync(path.join(dir, String(i).padStart(2, "0") + ".png"), b));
  return buffers.length;
}

const web = extract("SparkFrames.swift");
const crab = extract("CrabFrames.swift");
const logo = extract("LogoFrame.swift");

const nWeb = writeSet(web, path.join(outDir, "web"));
const nCrab = writeSet(crab, path.join(outDir, "crab"));
writeSet(logo, outDir, "logo.png");

console.log(`web:  ${nWeb} frames -> ${path.join(outDir, "web")}`);
console.log(`crab: ${nCrab} frames -> ${path.join(outDir, "crab")}`);
console.log(`logo: 1 frame   -> ${path.join(outDir, "logo.png")}`);
if (!nWeb || !nCrab || !logo.length) {
  console.error("WARNING: a frame set came back empty — check the Swift source declarations.");
  process.exit(1);
}
