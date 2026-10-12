#!/usr/bin/env python3
"""Draw the engine throughput chart: mean per-frame cost, M3 Max vs A16.

Both platforms run the same `full` sequential engine on the same 30 s / 180 s
protocol, so the bars are directly comparable in intent. Every number is
recomputed from the per-frame reports, so the figure cannot drift from the
raw data:

    python3 Scripts/plot-engine-performance.py

Writes Assets/engine-performance.png. Needs Pillow only.
"""
import json
import statistics
from pathlib import Path

from PIL import Image, ImageDraw, ImageFont

ROOT = Path(__file__).resolve().parent.parent
MAC_SOURCE = ROOT / "Docs/Benchmarks/M3Max-playback-duration.json"
A16_SOURCES = {
    30: ROOT / "iOS/Reports/iphone14pro-quick.json",
    180: ROOT / "iOS/Reports/iphone14pro-sustained.json",
}
OUT = ROOT / "Assets/engine-performance.png"

S = 2  # supersample factor; the image is drawn large and reduced at the end
W, H = 1680, 1080

INK = "#1c2530"
MUTED = "#5b6673"
GRID = "#e3e7ec"
BUDGET = "#d43f3a"
MAC_SHORT = "#2f7fd0"
MAC_LONG = "#e8802a"
A16_SHORT = "#7b5ea7"
A16_LONG = "#9aa4ae"

FONT_PATH = "/System/Library/Fonts/Hiragino Sans GB.ttc"

BUDGETS = {"PAL-D/K": 40.0, "NTSC-M": 1000 / 29.97}

MAC_KEYS = {(30, "default"): "default_30s", (30, "damaged"): "damaged_30s",
            (180, "default"): "default_180s", (180, "damaged"): "damaged_180s"}


def font(size, bold=False):
    return ImageFont.truetype(FONT_PATH, size * S, index=1 if bold else 0)


def load_mac():
    """Return {(system, scenario, seconds): (mean_ms, over, frames)}."""
    report = json.loads(MAC_SOURCE.read_text())
    out = {}
    for (seconds, scenario), key in MAC_KEYS.items():
        for row in report[key]:
            out[(row["system"], scenario, seconds)] = (
                row["mean_production_ms"],
                row["production_deadline_misses"],
                row["produced_frames"],
            )
    return out


def load_a16():
    """Return {(system, scenario, seconds): (mean_ms, over, frames)}.

    The mean is recomputed from the per-frame samples rather than read from the
    report summary, so the bar and the table cannot disagree.
    """
    out = {}
    for seconds, path in A16_SOURCES.items():
        report = json.loads(path.read_text())
        for case in report["cases"]:
            samples = [s["processingMS"] for s in case["samples"]]
            if not samples:
                continue
            out[(case["system"], case["scenario"], seconds)] = (
                statistics.mean(samples),
                sum(v > case["budgetMS"] for v in samples),
                len(samples),
            )
    return out


data = {"M3 Max": load_mac(), "A16": load_a16()}

SCENARIOS = [
    ("PAL-D/K", "default", "PAL-D/K", "默认"),
    ("PAL-D/K", "damaged", "PAL-D/K", "损伤"),
    ("NTSC-M", "default", "NTSC-M", "默认"),
    ("NTSC-M", "damaged", "NTSC-M", "损伤"),
]

# label, colour, platform, seconds
SERIES = [
    ("M3 Max · 30 s", MAC_SHORT, "M3 Max", 30),
    ("M3 Max · 180 s", MAC_LONG, "M3 Max", 180),
    ("A16 · 30 s", A16_SHORT, "A16", 30),
    ("A16 · 180 s", A16_LONG, "A16", 180),
]

# ---------------------------------------------------------------- geometry
PLOT_L, PLOT_R = 120, W - 60
PLOT_T, PLOT_B = 250, H - 250
Y_MAX = 85.0
Y_TICKS = list(range(0, 81, 10))

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
draw.text((x(PLOT_L), p(46)), "地面电视引擎每帧平均耗时：M3 Max 与 iPhone 14 Pro（A16）",
          font=font(29, True), fill=INK)
draw.text((x(PLOT_L), p(100)),
          "1× 回放 30 s / 180 s · 同为 full＋顺序引擎 · 柱越短越好 · 虚线为该制式帧预算",
          font=font(17), fill=MUTED)
draw.text((x(PLOT_L), p(132)),
          "M3 Max：macOS 回放 Rickroll，无窗口、音频按真实时钟消费；A16：基准 App 彩条，音频只计算不播放",
          font=font(15), fill=MUTED)
draw.text((x(PLOT_L), p(158)),
          "两者都是每帧平均处理耗时，但测法不同，跨平台只宜看趋势与余量",
          font=font(15), fill=MUTED)

# ------------------------------------------------------------------- grid
for tick in Y_TICKS:
    draw.line([(x(PLOT_L), y(tick)), (x(PLOT_R), y(tick))], fill=GRID, width=1 * S)
    draw.text((x(PLOT_L) - 18 * S, y(tick)), f"{tick}",
              font=font(15), fill=MUTED, anchor="rm")
draw.text((x(PLOT_L) - 18 * S, y(Y_MAX) - 26 * S), "ms",
          font=font(15), fill=MUTED, anchor="rm")

draw.line([(x(PLOT_L), y(0)), (x(PLOT_R), y(0))], fill="#b6bec7", width=2 * S)


def over_label(over, count):
    """Over-budget annotation: stay compact, never round a real miss to 0%."""
    if not over:
        return ""
    share = over / count
    return "超 <1%" if share < 0.01 else f"超 {share:.0%}"


# ------------------------------------------------------------------- bars
slot = (PLOT_R - PLOT_L) / len(SCENARIOS)
bar_w = 54
gap = 10
total_w = len(SERIES) * bar_w + (len(SERIES) - 1) * gap

for index, (system, scenario, sys_label, scen_label) in enumerate(SCENARIOS):
    center = PLOT_L + slot * (index + 0.5)
    left = center - total_w / 2
    for s_index, (label, colour, platform, seconds) in enumerate(SERIES):
        mean, over, count = data[platform][(system, scenario, seconds)]
        bx0 = left + s_index * (bar_w + gap)
        bx1 = bx0 + bar_w
        draw.rounded_rectangle([x(bx0), y(mean), x(bx1), y(0)], radius=4 * S, fill=colour)
        draw.text(((x(bx0) + x(bx1)) / 2, y(mean) - 11 * S), f"{mean:.2f}",
                  font=font(15, True), fill=INK, anchor="mb")
        note = over_label(over, count)
        if note:
            draw.text(((x(bx0) + x(bx1)) / 2, y(mean) - 34 * S), note,
                      font=font(12, True), fill=BUDGET, anchor="mb")
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
    draw.text(((x(lo) + x(hi)) / 2, y(budget) - 11 * S),
              f"{system} 预算 {budget:.2f} ms",
              font=font(15, True), fill=BUDGET, anchor="mb")

# ----------------------------------------------------------------- legend
legend_y = y(0) + 112 * S
entries = [(label, colour) for label, colour, _, _ in SERIES]
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
          "逐帧重算：Docs/Benchmarks/M3Max-playback-duration.json（M3 Max）与 iOS/Reports/"
          "iphone14pro-quick.json、iphone14pro-sustained.json（A16）；生成脚本 Scripts/plot-engine-performance.py",
          font=font(13), fill=MUTED)

image.resize((W, H), Image.LANCZOS).save(OUT)
print(f"wrote {OUT.relative_to(ROOT)}")
