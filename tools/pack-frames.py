#!/usr/bin/env python3
"""Pack the per-frame PNG animation sets into one horizontal sprite-strip per set.

Each animation set (e.g. frames/clawd/thinking/00.png … NN.png) becomes a single
strip frames/clawd/thinking.png laid out left-to-right in frame order, plus an
entry in frames/sprites.json giving the frame count and cell size. The awesomewm
widget slices the strip back into per-frame surfaces at load time — same pixels,
far fewer files in the repo.

Sets are discovered automatically: any directory under frames/ that holds NN.png
frames is packed, so adding a new animation needs no edit here.

Run from the repo root:  python3 tools/pack-frames.py
Re-run after editing the per-frame PNGs to regenerate the strips + manifest.
"""
import json
import os
import sys

from PIL import Image

ROOT = os.path.join(os.path.dirname(__file__), "..",
                    "linux", "awesomewm", "claude_status", "frames")
FRAMES = os.path.normpath(ROOT)

def frame_files(d):
    # Numeric sort so 100.png follows 99.png (lexicographic would put it after 10.png).
    return sorted((f for f in os.listdir(d) if f.endswith(".png") and f[:-4].isdigit()),
                  key=lambda f: int(f[:-4]))


def discover_sets(root):
    # Every directory holding NN.png frames, keyed the way load_frame_dir asks for it
    # (path relative to frames/, POSIX separators): e.g. "web", "crab", "clawd/thinking".
    sets = []
    for dirpath, _dirs, files in os.walk(root):
        if any(f.endswith(".png") and f[:-4].isdigit() for f in files):
            sets.append(os.path.relpath(dirpath, root).replace(os.sep, "/"))
    return sorted(sets)


def load_manifest(path):
    try:
        with open(path) as f:
            return json.load(f)
    except (OSError, ValueError):
        return {}


def pack():
    manifest_path = os.path.join(FRAMES, "sprites.json")
    # Merge into the existing manifest so packing a subset keeps the other sets' entries.
    manifest = load_manifest(manifest_path)
    packed = 0
    for key in discover_sets(FRAMES):
        src = os.path.join(FRAMES, key)
        files = frame_files(src)
        if not files:
            continue
        imgs = [Image.open(os.path.join(src, f)).convert("RGBA") for f in files]
        w, h = imgs[0].size
        if any(im.size != (w, h) for im in imgs):
            sys.exit(f"{key}: frames are not all {w}x{h}; uniform size required")
        strip = Image.new("RGBA", (w * len(imgs), h), (0, 0, 0, 0))
        for i, im in enumerate(imgs):
            strip.paste(im, (i * w, 0))
        out = os.path.join(FRAMES, key + ".png")
        strip.save(out)
        manifest[key] = {"n": len(imgs), "w": w, "h": h}
        packed += 1
        print(f"packed {key}: {len(imgs)} frames {w}x{h} -> {os.path.relpath(out)}")
    if packed == 0:
        sys.exit("no per-frame directories found; "
                 "refusing to overwrite sprites.json with an empty manifest")
    with open(manifest_path, "w") as f:
        json.dump(manifest, f, indent=2, sort_keys=True)
        f.write("\n")
    print(f"wrote {manifest_path}")


if __name__ == "__main__":
    pack()
