#!/usr/bin/env python3
"""Compile the original portraits into a reproducible, video-style v1 atlas.

Requires Python 3.10+ and Pillow with WebP support (``python -m pip install Pillow``).
This is an asset compiler: source PNGs are never changed or redrawn. It resizes
each portrait about a fixed foot baseline, then packs the client's fixed rows.

Run from any directory::

    python codex/tools/build_video_style.py --output-dir /path/to/candidate

The default output is a review candidate outside the repository. Preview GIFs
are illustrative renders of these exact frames, not recordings of Codex. The
client owns interaction, window movement and timing. In animation.json,
durationMs retains the standalone app's existing tempo; nativeDurationMs
documents the native client's timing and does not override it.
"""

from __future__ import annotations

import argparse
import hashlib
import json
from dataclasses import dataclass
from pathlib import Path

from PIL import Image, ImageDraw, ImageFont


CELL_W, CELL_H = 192, 208
COLS, ROWS = 8, 9
BASE_HEIGHT, FOOT_Y = 170, 202
BACKGROUND = (248, 245, 239)


@dataclass(frozen=True)
class Sequence:
    state: str
    title: str
    sources: tuple[str, ...]
    scales_y: tuple[float, ...]
    scales_x: tuple[float, ...]
    duration_ms: tuple[int, ...]

    @property
    def total_ms(self) -> int:
        return sum(self.duration_ms)


def compensating_x(scales_y: tuple[float, ...], strength: float = 0.65) -> tuple[float, ...]:
    return tuple(round(1 / (value ** strength), 6) for value in scales_y)


def make_sequences() -> list[Sequence]:
    idle_y = (1.0, 1.02, 0.99, 1.07, 0.975, 1.0)
    move_y = (1.0, 1.10, 1.035, 0.96, 1.018, 0.996, 1.0, 1.0)
    wave_y = (1.10, 0.965, 1.015, 1.0)
    failure_y = (1.105, 0.965, 1.025, 0.99, 1.015, 0.995, 1.008, 1.0)
    waiting_y = (1.0, 1.016, 1.025, 1.014, 0.995, 1.0)
    working_y = (1.015, 0.985, 1.012, 0.988, 1.008, 1.0)
    review_y = (1.0, 1.012, 1.022, 1.014, 1.003, 1.0)
    return [
        Sequence("idle", "Idle", ("smile", "smile-closed", "smile", "confident", "confident", "smile"),
                 idle_y, compensating_x(idle_y), (1680, 660, 660, 840, 840, 1920)),
        Sequence("running-right", "Drag right", ("smile",) * 8,
                 move_y, compensating_x(move_y), (120, 120, 120, 120, 120, 120, 120, 220)),
        Sequence("running-left", "Drag left", ("smile",) * 8,
                 move_y, compensating_x(move_y), (120, 120, 120, 120, 120, 120, 120, 220)),
        Sequence("waving", "Greeting", ("knock",) * 4,
                 wave_y, compensating_x(wave_y), (140, 140, 140, 280)),
        Sequence("jumping", "Pointer reaction", ("knock",) * 5,
                 (1.13, 0.96, 1.02, 0.995, 1.0), (0.90, 1.05, 0.985, 1.005, 1.0),
                 (140, 140, 140, 140, 280)),
        Sequence("failed", "Failed", ("crying",) * 8,
                 failure_y, compensating_x(failure_y), (140, 140, 140, 140, 140, 140, 140, 240)),
        Sequence("waiting", "Waiting", ("smile-closed",) * 6,
                 waiting_y, compensating_x(waiting_y, 0.35), (150, 150, 150, 150, 150, 260)),
        Sequence("running", "Working", ("typing",) * 6,
                 working_y, compensating_x(working_y), (120, 120, 120, 120, 120, 220)),
        Sequence("review", "Review / thinking", ("notes",) * 6,
                 review_y, compensating_x(review_y, 0.35), (150, 150, 150, 150, 150, 280)),
    ]


def transparent_rgb_zero(image: Image.Image) -> Image.Image:
    """Retain partial alpha exactly, but clear RGB under alpha == 0."""
    result = Image.new("RGBA", image.size)
    result.paste(image, mask=image.getchannel("A").point(lambda alpha: 255 if alpha else 0))
    return result


def render_cell(source: Image.Image, sx: float, sy: float) -> Image.Image:
    base_w = source.width * BASE_HEIGHT / source.height
    size = (round(base_w * sx), round(BASE_HEIGHT * sy))
    if not (0 < size[0] < CELL_W and 0 < size[1] < FOOT_Y):
        raise ValueError(f"Scaled portrait would clip its cell: {size}")
    portrait = source.resize(size, Image.Resampling.LANCZOS)
    cell = Image.new("RGBA", (CELL_W, CELL_H))
    cell.alpha_composite(portrait, ((CELL_W - size[0]) // 2, FOOT_Y - size[1]))
    return transparent_rgb_zero(cell)


def frame_index(sequence: Sequence, time_ms: int) -> int:
    phase = time_ms % sequence.total_ms
    for index, duration in enumerate(sequence.duration_ms):
        if phase < duration:
            return index
        phase -= duration
    raise AssertionError("Invalid animation timing")


def font(size: int) -> ImageFont.ImageFont:
    try:
        return ImageFont.truetype("DejaVuSans.ttf", size)
    except OSError:
        try:
            return ImageFont.load_default(size=size)
        except TypeError:
            return ImageFont.load_default()


def save_gif(path: Path, frames: list[Image.Image], durations: list[int], atlas: Image.Image) -> None:
    palette_source = Image.new("RGB", atlas.size, BACKGROUND)
    palette_source.paste(atlas, mask=atlas.getchannel("A"))
    palette = palette_source.quantize(colors=255, method=Image.Quantize.MEDIANCUT)
    converted = [frame.convert("RGB").quantize(palette=palette, dither=Image.Dither.FLOYDSTEINBERG) for frame in frames]
    converted[0].save(path, save_all=True, append_images=converted[1:], duration=durations,
                      loop=0, optimize=True, disposal=1)


def native_preview(output: Path, sequences: list[Sequence], cells: list[list[Image.Image]], atlas: Image.Image) -> None:
    total = sequences[0].total_ms
    boundaries = {0, total}
    for sequence in sequences:
        elapsed = 0
        while elapsed < total:
            for duration in sequence.duration_ms:
                elapsed += duration
                if elapsed < total:
                    boundaries.add(elapsed)
    times = sorted(boundaries)
    frames, durations = [], []
    heading_font, label_font = font(16), font(12)
    for now, next_time in zip(times, times[1:]):
        canvas = Image.new("RGB", (680, 812), BACKGROUND)
        draw = ImageDraw.Draw(canvas)
        draw.text((16, 10), "Native timing: fixed-foot breathing and spring", font=heading_font, fill="#4c3a2b")
        draw.text((16, 31), "Idle is a real 6.60 s loop. Preview of compiled frames, not an app recording.", font=label_font, fill="#77675b")
        for row, sequence in enumerate(sequences):
            x, y = 12 + (row % 3) * 224, 56 + (row // 3) * 250
            draw.rounded_rectangle((x, y, x + 216, y + 240), radius=10, fill="#fffcf7", outline="#e6ded2")
            draw.text((x + 10, y + 8), f"{sequence.title}  ({sequence.total_ms / 1000:.2f}s)", font=label_font, fill="#514033")
            draw.line((x + 9, y + 28 + FOOT_Y, x + 207, y + 28 + FOOT_Y), fill="#ddd3c5")
            sprite = cells[row][frame_index(sequence, now)]
            canvas.paste(sprite, (x + 12, y + 28), sprite)
        frames.append(canvas)
        durations.append(next_time - now)
    save_gif(output / "accurate-native-preview.gif", frames, durations, atlas)


def interaction_preview(output: Path, sequences: list[Sequence], cells: list[list[Image.Image]], atlas: Image.Image) -> None:
    """Show a pointer reaction and host-style horizontal drag, without bobbing a window."""
    frames, durations = [], []
    for now in range(0, 9400, 40):
        row, phase, center_x = 0, now, 132.0
        title = "Idle: fixed-foot breathing"
        cursor = None
        if 2000 <= now < 2840:
            row, phase = 4, now - 2000
            title = "Pointer reaction: stretch, squash, settle"
            cursor = (center_x + 54, 162)
        elif 2840 <= now < 4000:
            phase = now - 2840
        elif 4000 <= now < 6120:
            row, phase = 1, now - 4000
            center_x += 370 * (now - 4000) / 2120
            title = "Drag right: standing pose, no running legs"
            cursor = (center_x + 20, 208)
        elif 6120 <= now < 7180:
            row, phase = 2, now - 6120
            center_x = 502 - 220 * (now - 6120) / 1060
            title = "Drag left: same face direction and fixed foot baseline"
            cursor = (center_x + 20, 208)
        elif now >= 7180:
            center_x, phase = 282, now - 7180
        canvas = Image.new("RGB", (660, 350), BACKGROUND)
        draw = ImageDraw.Draw(canvas)
        draw.text((14, 12), title, font=font(16), fill="#4c3a2b")
        draw.text((14, 35), "Illustration only; Codex controls pointer events and actual window dragging.", font=font(12), fill="#77675b")
        draw.line((22, 314, 638, 314), fill="#d6ccbd", width=1)
        sprite = cells[row][frame_index(sequences[row], phase)]
        canvas.paste(sprite, (round(center_x - CELL_W / 2), 112), sprite)
        if cursor is not None:
            x, y = cursor
            draw.polygon([(x, y), (x + 5, y + 19), (x + 9, y + 13), (x + 16, y + 12)],
                         fill="#477bb8", outline="#ffffff")
        frames.append(canvas)
        durations.append(40)
    save_gif(output / "hover-and-drag.gif", frames, durations, atlas)


def validate(atlas: Image.Image, sequences: list[Sequence], cells: list[list[Image.Image]], output: Path) -> dict:
    frame_reports = []
    for row, sequence in enumerate(sequences):
        for column in range(COLS):
            crop = atlas.crop((column * CELL_W, row * CELL_H, (column + 1) * CELL_W, (row + 1) * CELL_H))
            bbox = crop.getchannel("A").getbbox()
            if column >= len(sequence.sources):
                if crop.tobytes() != bytes(CELL_W * CELL_H * 4):
                    raise AssertionError(f"Unused cell {row},{column} is not zero RGBA")
                continue
            if bbox is None or bbox[3] != FOOT_Y or bbox[0] <= 0 or bbox[1] <= 0 or bbox[2] >= CELL_W:
                raise AssertionError(f"Used frame clips or moves foot baseline: {row},{column}: {bbox}")
            if crop.tobytes() != cells[row][column].tobytes():
                raise AssertionError("Atlas packing changed frame pixels")
            frame_reports.append({"row": row, "column": column, "state": sequence.state,
                                  "source": sequence.sources[column], "alpha_bbox": list(bbox),
                                  "footBaselineExclusiveY": FOOT_Y,
                                  "scaleX": sequence.scales_x[column], "scaleY": sequence.scales_y[column],
                                  "rgba_sha256": hashlib.sha256(crop.tobytes()).hexdigest()})
    if len(frame_reports) != 57 or cells[1] != cells[2]:
        raise AssertionError("Expected 57 used frames and identical left/right standing sequences")
    decoded_webp = Image.open(output / "spritesheet.webp").convert("RGBA")
    if decoded_webp.tobytes() != atlas.tobytes():
        raise AssertionError("Lossless WebP pixels differ from PNG")
    if len({frame.tobytes() for frame in cells[4]}) != 5:
        raise AssertionError("Pointer reaction must contain five distinct frames")
    return {"passed": True, "spriteVersionNumber": 1, "width": atlas.width, "height": atlas.height,
            "cellWidth": CELL_W, "cellHeight": CELL_H, "columns": COLS, "rows": ROWS,
            "usedFrames": 57, "unusedTransparentCells": 15, "footBaselineExclusiveY": FOOT_Y,
            "losslessWebpPixelIdentical": True, "leftRightPixelIdentical": True,
            "sourcePngsUnchanged": True, "frames": frame_reports}


def write_json(path: Path, data: dict) -> None:
    path.write_text(json.dumps(data, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")


def main() -> None:
    repo_default = Path(__file__).resolve().parents[2]
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--repo-root", type=Path, default=repo_default)
    parser.add_argument("--output-dir", type=Path)
    args = parser.parse_args()
    repo = args.repo_root.expanduser().resolve()
    output = (args.output_dir or repo.parent / "output/claude-codex-video-style/candidate").expanduser().resolve()
    output.mkdir(parents=True, exist_ok=True)
    sequences = make_sequences()
    source_names = sorted({name for sequence in sequences for name in sequence.sources})
    source_paths = {name: repo / "pet/sprites" / f"{name}.png" for name in source_names}
    source_hashes = {name: hashlib.sha256(path.read_bytes()).hexdigest() for name, path in source_paths.items()}
    sources = {name: Image.open(path).convert("RGBA") for name, path in source_paths.items()}
    cells = [[render_cell(sources[name], sx, sy) for name, sx, sy in
              zip(sequence.sources, sequence.scales_x, sequence.scales_y)] for sequence in sequences]
    atlas = Image.new("RGBA", (CELL_W * COLS, CELL_H * ROWS))
    for row, row_cells in enumerate(cells):
        for column, cell in enumerate(row_cells):
            atlas.alpha_composite(cell, (column * CELL_W, row * CELL_H))
    atlas.save(output / "Atlas.png", optimize=True)
    atlas.save(output / "spritesheet.webp", lossless=True, quality=100, method=6, exact=True)
    validation = validate(atlas, sequences, cells, output)
    if any(hashlib.sha256(path.read_bytes()).hexdigest() != source_hashes[name] for name, path in source_paths.items()):
        raise AssertionError("Source PNG changed during compilation")
    write_json(output / "validation.json", validation)
    metadata = {"spriteVersionNumber": 1, "width": atlas.width, "height": atlas.height,
                "columns": COLS, "rows": ROWS, "cellWidth": CELL_W, "cellHeight": CELL_H, "frameCount": 57,
                "animations": [{"row": row, "state": sequence.state, "frames": len(sequence.sources),
                                "durationMs": [value // 6 for value in sequence.duration_ms] if row == 0 else list(sequence.duration_ms),
                                "nativeDurationMs": list(sequence.duration_ms)} for row, sequence in enumerate(sequences)],
                "motionStyle": "fixed-foot-breathing-and-spring",
                "timingNote": "durationMs preserves the standalone app's existing tempo. nativeDurationMs records timing observed in the current Codex client and cannot override Codex timing."}
    write_json(output / "animation.json", metadata)
    write_json(output / "video-motion.json", {
        "sourceVideo": "https://www.bilibili.com/video/BV1NSnF6aE76/",
        "referenceClipSeconds": [6.4, 7.267],
        "referenceObservation": "A complete portrait is replaced, then stretches/squashes about a fixed foot baseline. Resting motion is tiny vertical breathing, not whole-window wandering.",
        "measurements": {"videoSize": [1920, 1080], "videoFps": 30, "footY": 1045,
                         "initialAtSeconds": 6.467, "initialWidthHeight": [234, 399],
                         "overshootAtSeconds": 6.667, "overshootWidthHeight": [275, 339],
                         "settledWidthHeight": [261, 354], "settlingSeconds": [0.7, 0.9]},
        "compiler": {"baseHeight": BASE_HEIGHT, "footBaselineExclusiveY": FOOT_Y, "sourceSha256": source_hashes,
                     "operation": "Technical resizing and packing of unchanged existing portraits; no AI redraw, leg animation, rotation or window-position code."},
        "nativeIdleLoopMs": 6600,
        "nativeLimits": "Fixed state rows and frame timing. These assets cannot add scripts, random click cycling or autonomous window movement.",
        "previewScope": "GIFs render the exact compiled cells. The nine-panel preview uses exact native frame durations. Hover-and-drag is an illustrative interaction sequence, not a desktop recording.",
        "sequences": [{"state": sequence.state, "sources": list(sequence.sources),
                       "scaleX": list(sequence.scales_x), "scaleY": list(sequence.scales_y),
                       "durationMs": list(sequence.duration_ms)} for sequence in sequences]})
    native_preview(output, sequences, cells, atlas)
    interaction_preview(output, sequences, cells, atlas)
    print(json.dumps({"output": str(output), "validation": "passed", "usedFrames": 57,
                      "nativeIdleLoopMs": 6600}, ensure_ascii=False))


if __name__ == "__main__":
    main()
