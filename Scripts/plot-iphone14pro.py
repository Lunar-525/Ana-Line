#!/usr/bin/env python3
"""Draw the iPhone 14 Pro performance chart (cold burst vs sustained heat).

Every number is recomputed from the per-frame samples of the reports the
benchmark app wrote, so the figure cannot drift from the raw data. Run:

    python3 Scripts/plot-iphone14pro.py

Writes Assets/iphone14pro-performance.png. Needs Pillow only.
"""
import json
import statistics
from pathlib import Path

from PIL import Image, ImageDraw, ImageFont

ROOT = Path(__file__).resolve().parent.parent
REPORTS = ROOT / "iOS/Reports"
OUT = ROOT / "Assets/iphone14pro-performance.png"

S = 2  # supersample factor; the image is drawn large and reduced at the end
W, H = 1680, 1020

INK = "#1c2530"
MUTED = "#5b6673"
GRID = "#e3e7ec"
BUDGET = "#d43f3a"
COLD = "#2f7fd0"
HOT = "#e8802a"
BASE_QUICK = "#c3cbd4"
BASE_SUSTAINED = "#7c8894"

FONT_PATH = "/System/Library/Fonts/Hiragino Sans GB.ttc"


def font(size, bold=False):
    return ImageFont.truetype(FONT_PATH, size * S, index=1 if bold else 0)


def load(name):
    """Return {(system, scenario): (mean, p95, over_budget_frames, frames)}."""
    report = json.loads((REPORTS / f"{name}.json").read_text())
    out = {}
    for case in report["cases"]:
        samples = case["samples"]
        if not samples:
            continue
        values = sorted(s["processingMS"] for s in samples)
        count = len(values)
        p95 = values[min(count - 1, int((count - 1) * 0.95))]
        over = sum(v > case["budgetMS"] for v in values)
        out[(case["system"], case["scenario"])] = (
            statistics.mean(values), p95, over, count, case["budgetMS"])
    return out


SCENARIOS = [
    ("PAL-D/K", "default", "PAL-D/K", "默认"),
    ("PAL-D/K", "damaged", "PAL-D/K", "损伤"),
    ("NTSC-M", "default", "NTSC-M", "默认"),
    ("NTSC-M", "damaged", "NTSC-M", "损伤"),
]

SERIES = [
    ("冷机 8 s · mobile＋流水线", COLD, "s3-pipe-a"),
    ("持续热透 180 s · mobile＋流水线", HOT, "sustained-3stage"),
    ("优化前 30 s · full＋顺序", BASE_QUICK, "iphone14pro-quick"),
    ("优化前 180 s · full＋顺序", BASE_SUSTAINED, "iphone14pro-sustained"),
]

data = {label: load(name) for label, _, name in SERIES}

# ---------------------------------------------------------------- geometry
PLOT_L, PLOT_R = 120, W - 60
PLOT_T, PLOT_B = 210, H - 240
Y_MAX = 85.0
Y_TICKS = list(range(0, 86, 10))

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
draw.text((x(PLOT_L), p(46)), "iPhone 14 Pro（A16）每帧墙钟耗时",
          font=font(30, True), fill=INK)
draw.text((x(PLOT_L), p(100)),
          "冷机爆发 vs 持续热透 · Release 真机 / iOS 27.0 · 每例 8 / 30 / 180 秒，丢弃 3 个预热帧 · 柱越短越好",
          font=font(17), fill=MUTED)

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
bar_w = 54
gap = 10
total_w = len(SERIES) * bar_w + (len(SERIES) - 1) * gap

for index, (system, scenario, sys_label, scen_label) in enumerate(SCENARIOS):
    center = PLOT_L + slot * (index + 0.5)
    left = center - total_w / 2
    for s_index, (label, colour, _) in enumerate(SERIES):
        mean, p95, over, count, _budget = data[label][(system, scenario)]
        bx0 = left + s_index * (bar_w + gap)
        bx1 = bx0 + bar_w
        draw.rounded_rectangle([x(bx0), y(mean), x(bx1), y(0)],
                               radius=4 * S, fill=colour)
        draw.text(((x(bx0) + x(bx1)) / 2, y(mean) - 12 * S), f"{mean:.2f}",
                  font=font(15, True), fill=INK, anchor="mb")
        if over and "流水线" in label and "冷机" not in label:
            draw.text(((x(bx0) + x(bx1)) / 2, y(mean) - 36 * S),
                      f"超 {over / count:.0%}", font=font(13, True),
                      fill=BUDGET, anchor="mb")
    # group label
    draw.text((x(center), y(0) + 16 * S), sys_label,
              font=font(18, True), fill=INK, anchor="ma")
    draw.text((x(center), y(0) + 44 * S), scen_label,
              font=font(16), fill=MUTED, anchor="ma")

# ----------------------------------------------------------- budget steps
pal_budget = data[SERIES[0][0]][("PAL-D/K", "default")][4]
ntsc_budget = data[SERIES[0][0]][("NTSC-M", "default")][4]
pal_span = (PLOT_L, PLOT_L + slot * 2)
ntsc_span = (PLOT_L + slot * 2, PLOT_R)
for span, budget, caption in ((pal_span, pal_budget, f"PAL 预算 {pal_budget:.2f} ms"),
                              (ntsc_span, ntsc_budget, f"NTSC 预算 {ntsc_budget:.2f} ms")):
    dashed((span[0] + 4, budget), (span[1] - 4, budget), 13, 8, BUDGET, 2)
    draw.text(((x(span[0]) + x(span[1])) / 2, y(budget) - 12 * S), caption,
              font=font(15, True), fill=BUDGET, anchor="mb")

# ----------------------------------------------------------------- legend
legend_y = y(0) + 108 * S
entries = [(label, colour) for label, colour, _ in SERIES]
widths = [draw.textlength(label, font=font(16)) + 46 * S for label, _ in entries]
total = sum(widths) + 30 * S * (len(entries) - 1)
cursor = x(W / 2) - total / 2
for (label, colour), entry_w in zip(entries, widths):
    draw.rounded_rectangle([cursor, legend_y - 11 * S, cursor + 26 * S, legend_y + 5 * S],
                           radius=3 * S, fill=colour)
    draw.text((cursor + 38 * S, legend_y), label, font=font(16), fill=INK, anchor="lm")
    cursor += entry_w + 30 * S

# ---------------------------------------------------------------- footnote
draw.text((x(PLOT_L), H * S - 54 * S),
          "数据由 iOS/Reports 的逐帧 JSON 重算：s3-pipe-a / sustained-3stage / iphone14pro-quick / iphone14pro-sustained；"
          "生成脚本 Scripts/plot-iphone14pro.py",
          font=font(13), fill=MUTED)

image.resize((W, H), Image.LANCZOS).save(OUT)
print(f"wrote {OUT.relative_to(ROOT)}")
