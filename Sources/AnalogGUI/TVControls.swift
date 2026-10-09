import SwiftUI
import AnalogCore

struct TVControls: View {
    @ObservedObject var model: PreviewModel
    private var defaults: TerrestrialSettings { TerrestrialSettings(system: model.terrestrialSystem) }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                GroupBox(L("Broadcast standard")) {
                    VStack(alignment: .leading, spacing: 8) {
                        Picker(L("Broadcast standard"), selection: $model.tvStandard) {
                            Text("PAL-D/K").tag(TVStandard.pal)
                            Text("NTSC-M").tag(TVStandard.ntsc)
                        }
                        .pickerStyle(.segmented).labelsHidden()
                        .accessibilityLabel(L("Broadcast standard"))
                        .frame(maxWidth: .infinity)
                        Text(model.tvStandard == .pal ? "625 / 50 · 8 MHz" : "525 / 59.94 · 6 MHz")
                            .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                        Text(L("VSB vision · complex RF envelope"))
                            .font(.caption2).foregroundStyle(.secondary)
                    }.frame(maxWidth: .infinity, alignment: .leading).padding(.top, 6)
                }
                GroupBox(L("RF channel")) {
                    VStack(spacing: 12) {
                        ParameterSlider(name: L("Signal level · dB"), value: $model.tvChannel.signalDB,
                            defaultValue: defaults.signalDB, range: -60...12)
                        ParameterSlider(name: L("Reference C/N · dB"), value: $model.tvChannel.carrierToNoiseDB,
                            defaultValue: defaults.carrierToNoiseDB, range: 5...60)
                        Text(L("C/N is referenced to the signal at 0 dB. Lower signal levels also reduce reception quality."))
                            .font(.caption2).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                        ParameterSlider(name: L("Echo amplitude"), value: $model.tvChannel.echoGain,
                            defaultValue: defaults.echoGain, range: 0...0.9, percent: true)
                        ParameterSlider(name: L("Echo delay · μs"), value: $model.tvChannel.echoDelayMicroseconds,
                            defaultValue: defaults.echoDelayMicroseconds, range: 0...20)
                        ParameterSlider(name: L("Echo phase · °"), value: $model.tvChannel.echoPhaseDegrees,
                            defaultValue: defaults.echoPhaseDegrees, range: -180...180)
                    }.padding(.top, 6)
                }.disabled(model.tvDuration <= 0)
                GroupBox(L("Tuner / receiver")) {
                    VStack(alignment: .leading, spacing: 12) {
                        ParameterSlider(name: L("Tuning offset · kHz"), value: $model.tvChannel.tuningOffsetKHz,
                            defaultValue: defaults.tuningOffsetKHz, range: -1500...1500)
                        ParameterSlider(name: L("IF bandwidth · MHz"), value: $model.tvChannel.rfBandwidthMHz,
                            defaultValue: defaults.rfBandwidthMHz, range: 1...10)
                        Toggle(L("Automatic fine tuning"), isOn: $model.tvChannel.automaticFineTuning)
                        Toggle(L("Automatic gain control"), isOn: $model.tvChannel.automaticGain)
                        if !model.tvChannel.automaticGain {
                            ParameterSlider(name: L("Receiver gain · dB"), value: $model.tvChannel.manualGainDB,
                                defaultValue: defaults.manualGainDB, range: -12...60)
                        }
                        Button(L("Reset reception")) { model.tvChannel = defaults }
                    }.padding(.top, 6)
                }.disabled(model.tvDuration <= 0)
                GroupBox(L("Reception")) {
                    VStack(spacing: 8) {
                        metric(L("Receiver lock"), model.tvDuration > 0 ? model.tvLockDescription : "—")
                        metric("AGC", String(format: "%+.1f dB", model.tvAGCDB))
                        metric(L("Carrier error"), String(format: "%+.0f Hz", model.tvCarrierErrorHz))
                        metric(L("Sync confidence"), String(format: "%.0f%%", model.tvSyncConfidence*100))
                        metric(L("Recovered lines"), "\(model.tvRecoveredLines) / \(model.tvStandard.height)")
                    }.padding(.top, 6)
                }
                Text(L("Video passes through VSB modulation, RF multipath and noise, tuning, AGC and sync recovery. Audio is the original soundtrack."))
                    .font(.caption2).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading).padding(.trailing, 8)
        }
    }

    private func metric(_ label: String, _ value: String) -> some View {
        HStack { Text(label).foregroundStyle(.secondary); Spacer(); Text(value).monospacedDigit() }
            .font(.caption)
    }
}
