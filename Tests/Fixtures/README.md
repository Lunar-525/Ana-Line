# Robot36 independent encoder fixture

`robot36-pysstv-bars.json` contains run-length encoded frequency/duration pairs
from dnet/pySSTV's `Robot36(...).gen_freq_bits()`, generated on 2026-10-09.
The input is our own 320×240 test chart: eight 40-pixel-wide vertical bars,
white, yellow, cyan, green, magenta, red, blue, black. Pillow converts RGB to
integer YCbCr independently of AnaLine's floating point color conversion.
Durations are seconds. The fixture includes the VIS header and all 240 rows.

Reference: https://github.com/dnet/pySSTV (MIT), API version 0.5.9.
No Python source is included in the App or required to run the Swift tests.
The test checks AnaLine TX frequencies against this independent output and
feeds the reference frequencies to AnaLine's reconstruction. It does not
claim arbitrary real-audio receiver compatibility.
