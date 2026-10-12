# AnaLine iOS core benchmark

Open `AnaLineBenchmark.xcodeproj` in Xcode, select the AnaLineBenchmark target and your personal development team under Signing & Capabilities, then select a physical iPhone and run **Release**. Minimum deployment target: iOS 17. This project compiles the existing `Sources/AnalogCore` files directly, without copying or modifying their algorithms. It is a diagnostic app, not the complete iOS port.

The app tests PAL-D/K and NTSC-M with default settings and a fixed damaged scenario. Every frame generates a continuous 1 kHz PCM tone, encodes 720-pixel color bars, runs `TVUnifiedChannelEngine` (vision and sound through a shared RF channel), and converts the result to RGBA. Three warmup frames are excluded. The damaged scenario includes echo, tuning offset, transmitter power/coupling, encoder/VSB/receiver damage and rainy propagation. Exact parameters are in `BenchmarkApp.swift`.

Quick: 30 seconds per case, approximately two minutes total. Sustained: 180 seconds per case, approximately twelve minutes total. The continuous engine state is retained frame to frame. Processing is paced to the standard when possible; when overloaded it retains consecutive source frames. No simulated frame skipping is added.

`processingMS` measures tone generation, CVBS encoding, RF reception, and RGBA conversion. It excludes sample validation, telemetry, report writing, UI presentation and pacing. `encodeMS` includes tone generation. The preview is updated once per second. Audio is computed and checked, but is not played through an audio device. Over-budget counts are **not** measured playback drops and this test does not establish audio/video synchronization. Color bars do not represent video decode cost. JSON contains every measured frame, lock/line recovery, memory footprint, and thermal state (0 nominal, 1 fair, 2 serious, 3 critical). Device temperature and clock frequency are not measured directly.

Reports are written atomically to the app's `Documents/benchmark.json` about once per second and at case completion. Use the share button to export. Cancellation/backgrounding preserves the latest checkpoint and marks the run incomplete. Starting another run replaces the previous report. Keep the phone connected, unlocked and the app in the foreground; record whether it was charging and its thermal state when comparing runs.

CLI build (substitute your own team identifier and device UDID):

```sh
xcodebuild -project iOS/AnaLineBenchmark.xcodeproj -scheme AnaLineBenchmark \
  -configuration Release -destination 'id=YOUR_DEVICE_UDID' \
  -derivedDataPath build/iOSBenchmark DEVELOPMENT_TEAM=YOUR_TEAM_ID \
  -allowProvisioningUpdates -allowProvisioningDeviceRegistration build
xcrun devicectl device install app --device YOUR_DEVICE_UDID \
  build/iOSBenchmark/Build/Products/Release-iphoneos/AnaLineBenchmark.app
xcrun devicectl device process launch --device YOUR_DEVICE_UDID \
  com.analine.benchmark --benchmark-quick
xcrun devicectl device copy from --device YOUR_DEVICE_UDID \
  --domain-type appDataContainer --domain-identifier com.analine.benchmark \
  --source Documents/benchmark.json --destination iOS/Reports/quick.json
python3 iOS/summarize.py iOS/Reports/quick.json
```

Use `--benchmark-sustained` for the sustained run. To compile without signing use `-sdk iphoneos CODE_SIGNING_ALLOWED=NO` in place of the device/signing arguments.

Schema 2 adds per-frame `stagesMS`: modulation, channel, tuner/IF, carrier estimation, PLL, synchronization, video decode, sound extraction and sound demodulation. `combinationIncluded` is already included in modulation and must not be added again. `--benchmark-profile` runs eight seconds per case for diagnosis; use the longer modes for sustained conclusions.

## Chain profile

The benchmark runs the phone-class chain profile `TVChainProfile.mobile` by default and records it as `chainProfile` in the report. Launch with `--benchmark-full` to measure the reference profile `TVChainProfile.full` with identical reporting overhead, then compare the two reports case by case. The profile only changes reduced-cost stages; the signal model, the sampling rates and the filter designs that are not named in `TVChainProfile` stay the same. `TVChainProfile.mobile` documents, per knob, what each reduction was measured to cost. The reference behaviour of every stage is unchanged when the profile is `full`, which is the default for all non-iOS callers and for sessions that predate the field.

## Hot-state profiling

`iOS/profile_symbols.py` aggregates an Instruments time-profile export by symbol and reports the achieved parallelism, the split across performance and efficiency cores, and self and inclusive time per symbol. Instruments interns processes, threads, cores and backtraces as ids defined in batches, so it parses the export twice:

```sh
xcrun xctrace record --template 'Time Profiler' --device <UDID> \
  --time-limit 180s --window 90s --output run.trace --launch -- com.analine.benchmark --benchmark-sustained
xcrun xctrace export --input run.trace \
  --xpath '/trace-toc/run[@number="1"]/data/table[@schema="time-profile"]' > tp.xml
xcrun xctrace export --input run.trace \
  --xpath '/trace-toc/run[@number="1"]/data/table[@schema="device-thermal-state-intervals"]'
python3 iOS/profile_symbols.py tp.xml 90
```

`--window` only sets the analysis window in Instruments; the exported table still covers the whole recording, so pass the second at which the device reached the thermal state of interest (the thermal table above says when) as the last argument. The device must be unlocked for a benchmark to start at all, including under xctrace. Findings are in `Reports/thermal-profile-14pro.md`.

## Reported performance parameters

Schema 3 stores a summary per case next to the raw per-frame samples, so a partial run still carries usable numbers and a raw report can be read without recomputing:

| Field | Meaning |
| --- | --- |
| `meanMS`, `medianMS`, `p95MS`, `peakMS` | Per-frame processing time. |
| `rateMeanPercent` | Nominal frame budget divided by the mean time. **Above 100% means the chain can outrun the standard**; this is independent of pacing. |
| `rateP95Percent` | The same against P95, i.e. the tail-safe rate. |
| `effectiveFPS`, `playbackRatePercent` | Frames actually produced per wall-second, against the standard's frame rate: what a viewer would get. |
| `lagMS` | Milliseconds the loop has fallen behind the ideal frame schedule. |
| `overBudget`, `overBudgetPercent` | Frames whose processing time exceeded the budget. These are diagnostic, not measured playback drops. |
| `lockedFrames`, `peakMemoryMB`, `measuredSeconds` | Lock count, peak footprint, case duration. |
| `thermalPercent` | Share of the case spent in each thermal state. |
| `stagesBudgetPercent` | Mean per-stage time as a percentage of the frame budget: which stage consumes it. |

`python3 iOS/summarize.py report.json` prints these as tables, recomputed from the samples so schema 1 and 2 reports still work, and warns if a stored summary disagrees with the samples.

Diagnostic launch arguments, all optional and immutable per process: `--benchmark-full` (reference chain profile), `--benchmark-workers N` (ceiling on the worker count of every parallel stage; default unlimited), `--benchmark-qos userInteractive|userInitiated|default|utility|background` (QoS the DSP runs at, so its parallel workers inherit it), `--benchmark-baseline` (bypass the cached decoder interpolation/pointer path and the parallel tuner), `--benchmark-profile` / `--benchmark-quick` / `--benchmark-sustained` (8 / 30 / 180 seconds per case).

`--benchmark-metal` (with any duration argument) runs a one-shot CPU-vs-GPU comparison for four kernels on the device itself — complex FIR, NCO mixing, the transmitter power amplifier and Gaussian noise — and writes it into `metalKernels` in the same report. It exists because a desktop part is a poor proxy for a phone: the Mac has many fast CPU cores beside a modest GPU slice. The accelerator prototype that it measures lives in `Sources/AnalogCore/TVMetalAccelerator.swift` and is not wired into the chain; the device measurements and the verdict are in `Reports/thermal-realtime-round2.md`. Note that the benchmark needs the app in the foreground, so the device must not be locked when a run starts.

For a paired A/B, alternate the two configurations back to back and compare the per-pair differences rather than absolute numbers: a single device drifts by more than 100% between sessions as it throttles, and `thermalPercent` shows how much of each case ran hot.

For an A/B diagnostic with the same telemetry overhead, append `--benchmark-baseline` to a launch. This bypasses only the cached decoder interpolation/pointer path and the parallel tuner; Accelerate FIR and all other signal settings stay the same. The mode is immutable per process, and new reports record `optimizationVariant`. Eight-second profiles diagnose individual stages, not long-term real-time behavior.
