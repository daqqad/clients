#!/usr/bin/env python3
"""Generate per-instance toolbar icons for the container-aware fork.

Reads apps/browser/instances.json and writes recolored copies of every
src/images/icon*.png and src/images/berry*.png into
src/images-instance/<instance-id>/, which the webpack build copies over
src/images when BW_INSTANCE is set.

Two treatments are applied so instances stay distinguishable in every state:
  1. saturated pixels are hue-shifted to the instance hue (the stock icon is a
     blue square with a white shield, so the shield is left alone), and
  2. a solid dot in the instance color is drawn in the bottom-right corner,
     which also survives the desaturated _gray / _locked variants.
"""

import json
import pathlib
import sys

from PIL import Image, ImageDraw

BROWSER_DIR = pathlib.Path(__file__).resolve().parent.parent
SRC = BROWSER_DIR / "src" / "images"
OUT_ROOT = BROWSER_DIR / "src" / "images-instance"
SATURATION_FLOOR = 60  # below this a pixel counts as white/gray and is left as-is


def recolor(path: pathlib.Path, hue: int, dot_color: str) -> Image.Image:
    img = Image.open(path).convert("RGBA")
    alpha = img.getchannel("A")

    h, s, v = img.convert("RGB").convert("HSV").split()
    h = h.point(lambda _, hue=hue: hue)
    mask = s.point(lambda p: 255 if p >= SATURATION_FLOOR else 0).convert("1")

    shifted = Image.merge("HSV", (h, s, v)).convert("RGB")
    out = Image.composite(shifted, img.convert("RGB"), mask).convert("RGBA")
    out.putalpha(alpha)

    size = min(out.size)
    d = max(4, round(size * 0.34))
    x1, y1 = out.width - 1, out.height - 1
    ImageDraw.Draw(out).ellipse([x1 - d, y1 - d, x1, y1], fill=dot_color)
    return out


def main() -> int:
    instances = json.loads((BROWSER_DIR / "instances.json").read_text())
    names = sys.argv[1:] or list(instances)

    for name in names:
        if name not in instances:
            print(f"unknown instance: {name}", file=sys.stderr)
            return 1
        cfg = instances[name]
        out_dir = OUT_ROOT / cfg["id"]
        out_dir.mkdir(parents=True, exist_ok=True)

        sources = sorted(
            p for p in SRC.iterdir() if p.suffix == ".png" and p.name.startswith(("icon", "berry"))
        )
        for src in sources:
            recolor(src, cfg["hue"], cfg["dotColor"]).save(out_dir / src.name)
        print(f"{cfg['id']}: wrote {len(sources)} icons to {out_dir.relative_to(BROWSER_DIR)}")

    return 0


if __name__ == "__main__":
    sys.exit(main())
