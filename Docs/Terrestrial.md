# Terrestrial vision RF simulator

The shared CVBS encoder/decoder remains available. Terrestrial uses `VSBModulator`,
`TerrestrialRFChannel`, and `TerrestrialReceiver` instead of the old CVBS channel.

## Profiles and representation

- PAL-D/K: 625/50, nominal 8 MHz channel, 6 MHz vision bandwidth.
- NTSC-M: 525/59.94, nominal 6 MHz channel, 4.2 MHz vision bandwidth,
  7.5 IRE active-picture setup. The shared NTSC CVBS source remains zero-setup.
- Both profiles use a nominal 0.75 MHz VSB region.
- The original 4fsc CVBS rate is also sufficient for this **single vision-channel**
  complex-envelope model. A future sound/multichannel path needs its own bandwidth
  and rate planning; this does not assert 4fsc can carry an entire cable network.

The modulator maps CVBS sync=-0.3 V, blanking=0 V, white=0.7 V to carrier amplitudes
1.0, 0.7375, 0.125. Its asymmetric complex FIR retains the upper sideband and
suppresses the lower sideband above the vestigial region. Inside the video passband,
H(f)+H(-f)=2, preserving baseband amplitude after coherent detection. FIRs are causal,
with persistent history; the decoder recovers their timing delay from sync pulses.
These windowed finite filters approximate the nominal response, not a certified
transmitter spectral mask. The existing PAL picture encoder is limited to 5 MHz.

## Channel and controls

- Signal level: voltage gain `10^(dB/20)` relative to the nominal transmitter.
- Reference C/N: complex white Gaussian noise power referenced to an unattenuated
  blanking-level vision carrier, **over the RF sampling bandwidth**. It is not a
  measured post-IF C/N. Reducing signal level with a fixed noise floor reduces C/N.
- Multipath: one additional fractional-sample delayed complex path. Amplitude is a
  voltage ratio; phase is total relative phase at the carrier. Delay history crosses
  frame boundaries. A terrain solver or a many-path propagation model is not included.
- Tuning: receiver LO offset applied to I/Q before its complex IF filter. Filter lower
  edge is -1.25 MHz; upper edge is configured channel bandwidth minus 1.25 MHz.
  Tuning therefore affects both carrier capture and the received spectrum.
- AFC capture range: +/-150 kHz. Coarse frequency is measured from unwrapped received
  phase after the initial filter transient; a narrow proportional carrier PLL follows
  phase. The decoder does not receive transmitter carrier phase/frequency as an oracle.
- AGC: fast acquisition plus block-smoothed sync-tip quantile gain estimation,
  followed by a detected back-porch clamp. It cannot restore S/N erased by RF noise.
  Manual mode bypasses the automatic RF gain estimate.

## Sync and playback

A separate 700 kHz detector filter and hysteretic slicer protect sync detection from
chroma and sample noise. A train of three broad pulses establishes vertical timing;
valid horizontal intervals update the raster period. Lock requires >65% active-line
matches and carrier capture. Holdover lasts three frame blocks, followed by a
free-running raster until reacquisition. Loss is a status, not an exception.

The selected PAL/NTSC nominal raster is known, as in a manually selected receiver
standard. The shared color decoder still uses standard/frame-index PAL phase
conventions; it is not a universal decoder for unknown off-air recordings.

Playback preserves DSP state across consecutive frames. CPU-limited playback slows
video and source-audio clocks instead of dropping RF samples. A seek resets state;
two frozen-picture pre-roll frames warm the receiver. This reconstructs steady
reception at the seek position, not the exact historical receiver state before it.
Paused slider changes also reacquire from pre-roll. This CPU implementation is not a
real-time guarantee. Audio is **source audio**, not an RF sound-channel simulation.

## Validation

Tests cover positive/negative sideband rejection, carrier amplitude, clean PAL/NTSC
field/color recovery, attenuation and automatic gain, detuning and AFC, loss/holdover/
reacquisition, and RF multipath behavior. FFmpeg integration uses Assets/rickroll.mp4;
GUI checks cover seek/play/pause and source replacement. These tests are numerical
checks of the model, not validation against measured receiver hardware.

## References

- ITU-R BT.470, conventional analogue television systems:
  https://www.itu.int/rec/R-REC-BT.470/en
- ITU-R BT.1700, characteristics of composite video signals:
  https://www.itu.int/rec/R-REC-BT.1700/en

Historical analogue systems are intentional here. CATV, satellite FM/TVRO and
VHS/Video8 recording models are not part of this mode.
