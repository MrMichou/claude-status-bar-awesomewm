#!/usr/bin/env python3
"""Pack the per-frame PNG animation sets into one horizontal sprite-strip per set.

Each animation set (e.g. frames/clawd/thinking/00.png … NN.png) becomes a single
strip frames/clawd/thinking.png laid out left-to-right in frame order, plus an
entry in frames/sprites.json giving the frame count and cell size. The awesomewm
widget slices the strip back into per-frame surfaces at load time — same pixels,
far fewer files in the repo.

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

# subdir (the key load_frame_dir() asks for) -> directory of NN.png frames.
SETS = [
    "web",
    "crab",
    "clawd/thinking",
    "clawd/typing",
    "clawd/walk",
    "clawd/listening",
    "clawd/birthday",
    "clawd/sleeping",
]


def frame_files(d):
    return sorted(f for f in os.listdir(d) if f.endswith(".png") and f[:-4].isdigit())


def pack():
    manifest = {}
    for key in SETS:
        src = os.path.join(FRAMES, key)
        if not os.path.isdir(src):
            print(f"skip {key}: no per-frame directory", file=sys.stderr)
            continue
        files = frame_files(src)
        if not files:
            print(f"skip {key}: no NN.png frames", file=sys.stderr)
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
        print(f"packed {key}: {len(imgs)} frames {w}x{h} -> {os.path.relpath(out)}")
    with open(os.path.join(FRAMES, "sprites.json"), "w") as f:
        json.dump(manifest, f, indent=2, sort_keys=True)
        f.write("\n")
    print(f"wrote {os.path.join(FRAMES, 'sprites.json')}")


if __name__ == "__main__":
    pack()
