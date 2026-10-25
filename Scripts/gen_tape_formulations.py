#!/usr/bin/env python3
"""Generate TapeFormulations.json from Audiochrome measurements.

All figures are relative to Maxell UR (1994), the deck's calibration reference.
Audiochrome method: Nakamichi BX-300E + audioTester; 200 nWb/m Dolby level.

drive is an effective hysteresis-drive calibration, not a measured constant.
It is mapped linearly from MOL400(3%) so each formulation reaches saturation at
roughly its measured headroom: drive = 2.5 - 0.24 * (MOL - 2.1). The reference
CHF (MOL +2.1) anchors drive 2.5; TDK B (MOL +6.0) gives 1.6.
"""
import json, collections

def drive_for(mol):
    return round(max(0.9, min(4.0, 2.5 - 0.24 * (mol - 2.1))), 3)

# (id, name, sensitivityDB, thdPercent, mol400_3DB, sol10kDB, noiseDB, sourceNote)
rows = [
    # ---- Sony (Audiochrome 2020-07-26) ----
    ("sony-ln-70",     "Sony Low Noise 1970",  -1.0, 1.6,  2.0, -2.8, -47.0, "Audiochrome, Sony Low Noise (1970)"),
    ("chf60",          "Sony CHF 60",          -0.8, 1.5,  2.1, -1.4, -47.6, "Audiochrome, Sony CHF (1978)"),
    ("sony-hf-85",     "Sony HF 1985",         -0.3, 0.60, 4.5, -1.4, -47.0, "Audiochrome, Sony HF (1985)"),
    ("sony-hf-88",     "Sony HF 1988",         -0.3, 0.45, 5.3, -1.1, -49.5, "Audiochrome, Sony HF (1988)"),
    ("sony-hf-95",     "Sony HF 1995",         -0.7, 0.31, 5.0, -0.1, -49.0, "Audiochrome, Sony HF (1995)"),
    ("sony-hf-2002",   "Sony HF 2002",         -0.8, 0.52, 4.5, -1.5, -48.5, "Audiochrome, Sony HF (2002)"),
    ("sony-bhf-82",    "Sony BHF 1982",         0.7, 0.50, 6.1, -0.4, -48.5, "Audiochrome, Sony BHF (1982)"),
    ("sony-hfs-85",    "Sony HF-S 1985",        0.5, 0.44, 6.3, -1.1, -50.6, "Audiochrome, Sony HF-S (1985)"),
    ("sony-hfs-88",    "Sony HF-S 1988",        0.7, 0.50, 7.0, -0.8, -49.6, "Audiochrome, Sony HF-S (1988)"),
    ("sony-hfes-86",   "Sony HF-ES 1986",       0.8, 0.27, 7.1, -0.4, -50.0, "Audiochrome, Sony HF-ES (1986)"),
    ("sony-hfes-88",   "Sony HF-ES 1988",       1.0, 0.45, 7.7, -0.3, -49.7, "Audiochrome, Sony HF-ES (1988)"),
    ("sony-fn-86",     "Sony FN 1986",          0.0, 0.35, 5.5, -0.3, -47.8, "Audiochrome, Sony FN (1986)"),
    ("sony-hdf-90",    "Sony HD-F 1990",       -0.5, 0.37, 4.5, -1.3, -49.7, "Audiochrome, Sony HD-F (1990)"),
    ("sony-fx-2004",   "Sony FX 2004",         -0.9, 0.51, 4.6, -1.1, -48.5, "Audiochrome, Sony FX (2004)"),
    # ---- TDK (Audiochrome 2020-12-04) ----
    ("tdk-d-79",       "TDK D 1979",           -0.6, 1.4,  1.9, -3.2, -48.4, "Audiochrome, TDK D (1979)"),
    ("tdk-d-86",       "TDK D 1986",           -0.9, 0.70, 3.7, -1.5, -49.5, "Audiochrome, TDK D (1986)"),
    ("tdk-d-90",       "TDK D 1990",            0.0, 0.40, 6.0, -1.4, -48.7, "Audiochrome, TDK D (1990)"),
    ("tdk-d-98",       "TDK D 1998",            1.0, 0.66, 6.8, -1.2, -49.5, "Audiochrome, TDK D (1998)"),
    ("tdkd60",         "TDK D 60",             -0.5, 1.2,  2.7, -2.6, -48.2, "Audiochrome, TDK D (1982)"),
    ("tdk-a-86",       "TDK A 1986",           -0.2, 0.40, 6.2, -1.0, -48.2, "Audiochrome, TDK A (1986)"),
    ("tdk-fe-95",      "TDK FE 1995",           0.4, 0.47, 6.8, -0.8, -49.1, "Audiochrome, TDK FE (1995)"),
    ("tdk-fe-2008",    "TDK FE 2008",          -0.4, 0.38, 5.0, -1.0, -47.5, "Audiochrome, TDK FE (2008)"),
    ("tdkb60",         "TDK B 60",              0.4, 0.53, 6.0, -1.8, -47.4, "Audiochrome, TDK B"),
    # ---- Maxell (Audiochrome 2019-01-30) ----
    ("maxell-ul-80",   "Maxell UL 1980",       -1.3, None,  1.7, None, -47.9, "Audiochrome, Maxell UL (1980)"),
    ("maxell-ul-85",   "Maxell UL 1985",        0.4, None,  4.8, None, -48.8, "Audiochrome, Maxell UL (1985)"),
    ("maxell-ln-85",   "Maxell LN 1985",        0.0, 0.70, 4.3, -0.9, -49.2, "Audiochrome, Maxell LN (1985)"),
    ("maxell-sln-90",  "Maxell S-LN 1990",     -0.2, 0.28, 4.9, -1.0, -49.2, "Audiochrome, Maxell S-LN (1990)"),
    ("maxell-ur-94",   "Maxell UR 1994",        0.0, 0.42, 5.3, -1.3, -49.5, "Audiochrome, Maxell UR (1994), calibration reference"),
    ("maxell-ur-97jp", "Maxell UR 1997 JP",    -0.2, 0.27, 4.9, -0.6, -49.2, "Audiochrome, Maxell UR (1997, Japan)"),
    ("maxell-ur-2012", "Maxell UR 2012",        0.7, 0.48, 5.6, -1.3, -47.3, "Audiochrome, Maxell UR (2012)"),
    # ---- Agfa (Audiochrome 2020-07-26) ----
    ("agfa-ln-72",     "Agfa Low Noise 1972",  -1.6, 5.4, -2.0, None, -50.1, "Audiochrome, Agfa Low Noise (1972)"),
    ("agfa-shd-72",    "Agfa Super High Dyn 1972", -1.2, 3.0, 0.0, -3.4, -48.1, "Audiochrome, Agfa Super High Dynamic (1972)"),
    ("agfa-ferro-79",  "Agfa Ferrocolor 1979",  0.0, 0.85, 3.7, -2.4, -48.0, "Audiochrome, Agfa Ferrocolor (1979)"),
    ("agfa-fei-82",    "Agfa FeI Ferrocolor HD 1982", -0.1, 1.6, 1.9, -2.2, -48.6, "Audiochrome, Agfa FeI Ferrocolor HD (1982)"),
    ("agfa-fdxi-87",   "Agfa F-DXI 1987",      -0.3, 0.55, 5.1, -1.5, -48.2, "Audiochrome, Agfa F-DXI (1987)"),
    ("agfa-hrxs-89",   "Agfa HR-XS 1989",       0.2, 1.4,  5.6, -1.0, -51.1, "Audiochrome, Agfa HR-XS (1989)"),
]

formulations = []
for rid, name, sens, thd, mol, sol, noise, note in rows:
    formulations.append(collections.OrderedDict([
        ("id", rid),
        ("name", name),
        ("sensitivityDB", sens),
        ("drive", drive_for(mol)),
        ("noiseDB", noise),
        ("thdPercent", thd),
        ("mol400_3DB", mol),
        ("sol10kDB", sol),
        ("sourceNote", note),
    ]))

doc = collections.OrderedDict([
    ("version", 1),
    ("referenceFormulation", "chf60"),
    ("note", "All measured figures from Audiochrome (Nakamichi BX-300E + audioTester), relative to Maxell UR 1994. "
             "sensitivityDB/noiseDB/thdPercent/mol400_3DB/sol10kDB are measured; drive is an effective calibration "
             "mapped from MOL400(3%) (drive = 2.5 - 0.24*(MOL-2.1)), not a measured constant. null = not measured."),
    ("formulations", formulations),
])

out = "/Users/fanxuancheng/Documents/Ana-LIne/Sources/AnalogCore/Resources/TapeFormulations.json"
with open(out, "w") as f:
    json.dump(doc, f, indent=2)
    f.write("\n")
print(f"Wrote {len(formulations)} formulations to {out}")
