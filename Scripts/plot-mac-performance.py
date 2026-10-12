#!/usr/bin/env python3
"""Draw the M3 Max engine chart: worst production frame per 30 s / 180 s run.

Every number is read back from the rows the playback harness wrote, so the
figure cannot drift from the raw data. Run:

    python3 Scripts/plot-mac-performance.py

Writes Assets/mac-performance.png. Needs Pillow only.
"""
import json
from pathlib import Path

from PIL import Image, ImageDraw, ImageFont

ROOT = Path(__file__).resolve().parent.parent
SOURCE = ROOT / "Docs/Benchmarks/M3Max-playback-duration.json"
OUT = ROOT / "Assets/mac-performance.png"

S = 2  # supersample factor; the image is drawn large and reduced at the end
W, H = 1680, 1020

INK = "#1c2530"
MUTED = "#5b6673"
GRID = "#e3e7ec"
BUDGET = "#d43f3a"
SHORT = "#2f7fd0"
LONG = "#e8802a"

FONT_PATH = "/System/Library/Fonts/Hiragino Sans GB.ttc"


def font(size, bold=False):
    return ImageFont.truetype(FONT_PATH, size * S, index=1 if bold else 0)


def load():
    """Return {(system, scenario, seconds): (worst_ms, over, frames)}."""
    report = json.loads(SOURCE.read_text())
    out = {}
    for key, seconds in (("default_30s", 30), ("damaged_30s", 30),
                         ("default_180s", 180), ("damaged_180s", 180)):
        scenario = "damaged" if key.startswith("damaged") else "default"
        for row in report[key]:
            out[(row["system"], scenario, seconds)] = (
                row["maximum_production_ms"],
                row["production_deadline_misses"],
                row["produced_frames"],
            )
    return out


data = load()

SCENARIOS = [
    ("PAL-D/K", "default", "PAL-D/K", "默认"),
    ("PAL-D/K", "damaged", "PAL-D/K", "损伤"),
    ("NTSC-M", "default", "NTSC-M", "默认"),
    ("NTSC-M", "damaged", "NTSC-M", "损伤"),
]

# label, colour, seconds
SERIES = [
    ("30 s 回放", SHORT, 30),
    ("180 s 回放", LONG, 180),
]

BUDGETS = {"PAL-D/K": 40.0, "NTSC-M": 1000 / 29.97}

# ---------------------------------------------------------------- geometry
PLOT_L, PLOT_R = 120, W - 60
PLOT_T, PLOT_B = 230, H - 250
Y_MAX = 60.0
Y_TICKS = list(range(0, 61, 10))

image = Image.new("RGB", (W * S, H * S), "#ffffff")
draw = ImageDraw.Draw(image)


def x(v):
    return round(v * S)


def p(v):
    """Absolute position in the 1x layout, in pixels."""
    return round(v * S)


def y(v):
    return round((PLOT_B - (v / Y_MAX) * (PLOT_B - PLOT_T)) * S)


def dashed(p1, p2, dash, gap, fill, width):
    (x1, y1), (x2, y2) = p1, p2
    length = ((x2 - x1) ** 2 + (y2 - y1) ** 2) ** 0.5
    if length == 0:
        return
    ux, uy = (x2 - x1) / length, (y2 - y1) / length
    pos = 0.0
    while pos < length:
        end = min(pos + dash, length)
        draw.line([(x(x1 + ux * pos), y(y1 + uy * pos)),
                   (x(x1 + ux * end), y(y1 + uy * end))], fill=fill, width=width * S)
        pos = end + gap


# ------------------------------------------------------------------ title
draw.text((x(PLOT_L), p(46)), "M3 Max 地面电视引擎：每帧最慢生成耗时",
          font=font(30, True), fill=INK)
draw.text((x(PLOT_L), p(100)),
          "1× 实时回放 Rickroll · 无窗口 · 每制式连续跑 30 s / 180 s · 柱越短越好",
          font=font(17), fill=MUTED)
draw.text((x(PLOT_L), p(134)),
          "柱为本次运行中最慢的一帧，因此跑得越久越容易采到慢帧；括注为超出该制式帧预算的帧数",
          font=font(15), fill=MUTED)

# ------------------------------------------------------------------- grid
for tick in Y_TICKS:
    draw.line([(x(PLOT_L), y(tick)), (x(PLOT_R), y(tick))], fill=GRID, width=1 * S)
    draw.text((x(PLOT_L) - 18 * S, y(tick)), f"{tick}",
              font=font(15), fill=MUTED, anchor="rm")
draw.text((x(PLOT_L) - 18 * S, y(Y_MAX) - 26 * S), "ms",
          font=font(15), fill=MUTED, anchor="rm")

draw.line([(x(PLOT_L), y(0)), (x(PLOT_R), y(0))], fill="#b6bec7", width=2 * S)

# ------------------------------------------------------------------- bars
slot = (PLOT_R - PLOT_L) / len(SCENARIOS)
bar_w = 76
gap = 14
total_w = len(SERIES) * bar_w + (len(SERIES) - 1) * gap

for index, (system, scenario, sys_label, scen_label) in enumerate(SCENARIOS):
    center = PLOT_L + slot * (index + 0.5)
    left = center - total_w / 2
    for s_index, (label, colour, seconds) in enumerate(SERIES):
        worst, over, frames = data[(system, scenario, seconds)]
        bx0 = left + s_index * (bar_w + gap)
        bx1 = bx0 + bar_w
        draw.rounded_rectangle([x(bx0), y(worst), x(bx1), y(0)],
                               radius=4 * S, fill=colour)
        draw.text(((x(bx0) + x(bx1)) / 2, y(worst) - 12 * S), f"{worst:.2f}",
                  font=font(16, True), fill=INK, anchor="mb")
        draw.text(((x(bx0) + x(bx1)) / 2, y(worst) - 36 * S), f"超 {over}/{frames}",
                  font=font(13, True), fill=BUDGET if over else MUTED, anchor="mb")
    draw.text((x(center), y(0) + 16 * S), sys_label,
              font=font(18, True), fill=INK, anchor="ma")
    draw.text((x(center), y(0) + 44 * S), scen_label,
              font=font(16), fill=MUTED, anchor="ma")

# ----------------------------------------------------------- budget steps
slot_span = {"PAL-D/K": (PLOT_L, PLOT_L + slot * 2),
             "NTSC-M": (PLOT_L + slot * 2, PLOT_R)}
for system, (lo, hi) in slot_span.items():
    budget = BUDGETS[system]
    dashed((lo + 4, budget), (hi - 4, budget), 13, 8, BUDGET, 2)
    draw.text(((x(lo) + x(hi)) / 2, y(budget) - 12 * S),
              f"{system} 预算 {budget:.2f} ms",
              font=font(15, True), fill=BUDGET, anchor="mb")

# ----------------------------------------------------------------- legend
legend_y = y(0) + 112 * S
entries = [(label, colour) for label, colour, _ in SERIES]
widths = [draw.textlength(label, font=font(16)) + 46 * S for label, _ in entries]
total = sum(widths) + 26 * S * (len(entries) - 1)
cursor = x(W / 2) - total / 2
for (label, colour), entry_w in zip(entries, widths):
    draw.rounded_rectangle([cursor, legend_y - 11 * S, cursor + 26 * S, legend_y + 5 * S],
                           radius=3 * S, fill=colour)
    draw.text((cursor + 38 * S, legend_y), label, font=font(16), fill=INK, anchor="lm")
    cursor += entry_w + 26 * S

# ---------------------------------------------------------------- footnote
draw.text((x(PLOT_L), H * S - 50 * S),
          "逐行重算：Docs/Benchmarks/M3Max-playback-duration.json；生成脚本 Scripts/plot-mac-performance.py",
          font=font(13), fill=MUTED)

image.resize((W, H), Image.LANCZOS).save(OUT)
print(f"wrote {OUT.relative_to(ROOT)}")
