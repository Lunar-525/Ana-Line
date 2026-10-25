# CHOW Tape Model attribution

Upstream: https://github.com/jatinchowdhury18/AnalogTapeModel

Author: Jatin Chowdhury and upstream contributors.

Reference commit: `604372e4ffd9690c3e283362e4598cb43edbb475` (retrieved 2026-10-15).

License: GNU General Public License version 3. The upstream LICENSE is included
verbatim here. Ana-Line's original code remains AGPLv3. GPLv3 section 13 and
AGPLv3 section 13 permit their combination; this notice does not relicense
upstream code as AGPL or MPL.

`Sources/CTapeDSP/TapeDSP.cpp` adapts the magnetic hysteresis derivative,
alpha-transform differentiation and RK4 integration from:

- `Plugin/Source/Processors/Hysteresis/HysteresisOps.h`
- `Plugin/Source/Processors/Hysteresis/HysteresisProcessing.h`
- `Plugin/Source/Processors/Hysteresis/HysteresisProcessing.cpp`

Modifications by Ana-Line, 2026-10-15: dependency-free scalar C++17 port,
Taylor evaluation around zero, symmetric finite-state protection, independent
stereo state, FIR oversampling, C ABI, effective CHF profile, emphasis/de-emphasis,
noise, independent L/R recording gains, parameter smoothing and bypass. These adaptations remain GPLv3.

JUCE, chowdsp_utils, xsimd, RTNeural, STN weights, GUI artwork and upstream
plugin wrappers are not bundled. The cassette graphic is native SwiftUI artwork.
This is not an official Sony product or an endorsement by Sony or CHOW.

Redistributions of binaries must provide corresponding source, including the
modified DSP, integration and build scripts, under the applicable licenses.
See the included LICENSE and repository-level LICENSE and THIRD_PARTY_NOTICES.md.
