#!/usr/bin/env python3
"""Render the Setlist app icon and pack it into macos/Resources/AppIcon.icns.

The icon is drawn from the same palette as the app (SetlistTheme.swift):
an obsidian squircle with a warm cherry glow, and a "setlist" of three
paper-colored track lines with a cherry cue marker on the current one.

Usage: python3 scripts/make_icon.py   (needs Pillow; run from any cwd)
"""
from __future__ import annotations

import shutil
import subprocess
import sys
import tempfile
from pathlib import Path

from PIL import Image, ImageDraw, ImageFilter

ROOT = Path(__file__).resolve().parent.parent
OUTPUT = ROOT / "macos" / "Resources" / "AppIcon.icns"

# SetlistTheme colours, 0-255.
OBSIDIAN = (19, 16, 16)
WARM_BLACK = (27, 22, 22)
CHERRY = (184, 33, 51)
PAPER = (245, 232, 214)
MUTED_PAPER = (184, 168, 156)

# macOS icon grid: the artwork sits on an 824pt squircle inside a 1024pt
# canvas, leaving the standard transparent margin.
CANVAS = 1024
SHAPE = 824
RADIUS = 186
SCALE = 4  # supersample for clean edges


def rounded_mask(size: int, radius: int) -> Image.Image:
    mask = Image.new("L", (size, size), 0)
    ImageDraw.Draw(mask).rounded_rectangle(
        (0, 0, size - 1, size - 1), radius=radius, fill=255
    )
    return mask


def render_master() -> Image.Image:
    s = SCALE
    canvas = CANVAS * s
    shape = SHAPE * s
    offset = (canvas - shape) // 2

    # Background: vertical obsidian → warm black gradient.
    tile = Image.new("RGB", (shape, shape), OBSIDIAN)
    gradient = ImageDraw.Draw(tile)
    for y in range(shape):
        t = y / (shape - 1)
        colour = tuple(
            round(OBSIDIAN[i] + (WARM_BLACK[i] - OBSIDIAN[i]) * t) for i in range(3)
        )
        gradient.line([(0, y), (shape, y)], fill=colour)

    # Cherry glow in the top-left, like SetlistDetailBackground.
    glow = Image.new("RGBA", (shape, shape), (0, 0, 0, 0))
    glow_draw = ImageDraw.Draw(glow)
    glow_radius = int(shape * 0.62)
    glow_draw.ellipse(
        (-glow_radius // 2, -glow_radius // 2, glow_radius, glow_radius),
        fill=CHERRY + (110,),
    )
    glow = glow.filter(ImageFilter.GaussianBlur(shape * 0.11))
    tile = Image.alpha_composite(tile.convert("RGBA"), glow)

    # Setlist lines: three tracks, the middle one "playing".
    draw = ImageDraw.Draw(tile)
    line_h = int(shape * 0.085)
    gap = int(shape * 0.115)
    left = int(shape * 0.20)
    first_top = (shape - (3 * line_h + 2 * gap)) // 2
    lengths = (0.58, 0.44, 0.52)
    for index, length in enumerate(lengths):
        top = first_top + index * (line_h + gap)
        right = left + int(shape * length)
        colour = PAPER if index == 1 else MUTED_PAPER
        draw.rounded_rectangle(
            (left, top, right, top + line_h), radius=line_h // 2, fill=colour
        )

    # Cue marker: a cherry disc leading the active line.
    marker = line_h + int(shape * 0.02)
    marker_top = first_top + (line_h + gap) - (marker - line_h) // 2
    marker_left = left - marker - int(shape * 0.045)
    draw.ellipse(
        (marker_left, marker_top, marker_left + marker, marker_top + marker),
        fill=CHERRY,
    )

    # Hairline top edge for depth.
    draw.line([(0, 0), (shape, 0)], fill=(255, 255, 255, 28), width=s * 2)

    # Clip to the squircle and centre on the transparent canvas.
    icon = Image.new("RGBA", (canvas, canvas), (0, 0, 0, 0))
    icon.paste(tile, (offset, offset), rounded_mask(shape, RADIUS * s))
    return icon.resize((CANVAS, CANVAS), Image.LANCZOS)


def build_icns(master: Image.Image, output: Path) -> None:
    if shutil.which("iconutil") is None:
        sys.exit("iconutil not found; this script must run on macOS")

    with tempfile.TemporaryDirectory() as tmp:
        iconset = Path(tmp) / "AppIcon.iconset"
        iconset.mkdir()
        for points in (16, 32, 128, 256, 512):
            for scale in (1, 2):
                pixels = points * scale
                suffix = "" if scale == 1 else "@2x"
                master.resize((pixels, pixels), Image.LANCZOS).save(
                    iconset / f"icon_{points}x{points}{suffix}.png"
                )
        output.parent.mkdir(parents=True, exist_ok=True)
        subprocess.run(
            ["iconutil", "-c", "icns", str(iconset), "-o", str(output)],
            check=True,
        )


def main() -> None:
    master = render_master()
    build_icns(master, OUTPUT)
    preview = OUTPUT.with_suffix(".png")
    master.resize((256, 256), Image.LANCZOS).save(preview)
    print(f"Wrote {OUTPUT} and {preview}")


if __name__ == "__main__":
    main()
