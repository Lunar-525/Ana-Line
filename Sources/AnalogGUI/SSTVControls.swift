import SwiftUI
import AnalogCore

struct SSTVControls: View {
    @ObservedObject var model: PreviewModel
    var body: some View {
        ScrollView {
            VStack(alignment: .leading,spacing: 16) {
                GroupBox(L("SSTV · Mode")) {
                    VStack(alignment: .leading,spacing: 10) {
                        Picker(L("Mode"),selection: $model.sstvSettings.mode) {
                            ForEach(SSTVMode.allCases,id: \.self) { mode in Text(mode.rawValue).tag(mode) }
                        }
                        Text("\(model.sstvSettings.mode.dimensions) · 12 kHz · \(model.sstvSettings.mode.duration,specifier: "%.1f") s").font(.caption).foregroundStyle(.secondary)
                        ParameterSlider(name: L("SSTV Mix"),value: $model.sstvSettings.mix,defaultValue: SSTVSettings().mix,range: 0...1,percent: true)
                        Text(L("The input is scaled to fit with letterboxing; transparent areas are composited onto black.")).font(.caption2).foregroundStyle(.secondary)
                        HStack {
                            Button(L("Weak signal")) {
                                var s = SSTVSettings(); s.mode = model.sstvSettings.mode; s.seed = model.sstvSettings.seed
                                s.noise = 0.35; s.dropout = 0.18; s.interference = 0.12; s.variation = 0.65
                                model.sstvSettings = s
                            }
                            Button(L("Drift")) {
                                var s = SSTVSettings(); s.mode = model.sstvSettings.mode; s.seed = model.sstvSettings.seed
                                s.drift = 120; s.clockPPM = 600; s.variation = 0.5
                                model.sstvSettings = s
                            }
                        }.controlSize(.small)
                    }.padding(.top,6)
                }
                GroupBox(L("TX → RX · Transceiver")) {
                    VStack(alignment: .leading,spacing: 10) {
                        HStack {
                            Button(model.transmitting ? L("Send again") : L("Start TX/RX")) { model.startTransmission() }
                                .buttonStyle(.borderedProminent)
                            Button(L("Stop")) { model.stopTransmission() }.disabled(!model.transmitting)
                        }
                        ProgressView(value: model.transmissionProgress).tint(.orange)
                        Text(model.transmitting && model.receivedRows == 0 ? "Sending VIS header…" : "RX \(model.receivedRows) / \(model.sstvSettings.mode.height) rows")
                            .font(.caption).monospacedDigit()
                        Picker(L("Speed"),selection: $model.playbackSpeed) {
                            Text("1×").tag(1.0); Text("4×").tag(4.0); Text("16×").tag(16.0)
                        }.pickerStyle(.segmented)
                        Toggle(L("Monitor TX audio (1×)"),isOn: $model.monitorTX).disabled(model.playbackSpeed != 1)
                        Button(L("Preview complete result")) { model.stopTransmission(); model.updateSelection() }
                            .controlSize(.small)
                        Text(L("Parameter changes during transmission affect subsequent scan lines. Stopping preserves received rows.")).font(.caption2).foregroundStyle(.secondary)
                    }.padding(.top,6)
                }
                GroupBox(L("Channel · Impairment")) {
                    VStack(spacing: 12) {
                        ParameterSlider(name: "Variation",value: $model.sstvSettings.variation,defaultValue: SSTVSettings().variation,range: 0...1,percent: true)
                        ParameterSlider(name: "Variation time · s",value: $model.sstvSettings.variationSeconds,defaultValue: SSTVSettings().variationSeconds,range: 0.2...8)
                        Text(L("Values below are baseline settings. Variation changes noise, frequency offset, clock, and interference, with fading and short bursts; 0% is fixed.")).font(.caption2).foregroundStyle(.secondary)
                        if model.transmitting {
                            Text(model.channelReadout).font(.caption2).monospacedDigit().foregroundStyle(.orange)
                        }
                        ParameterSlider(name: L("Noise"),value: $model.sstvSettings.noise,defaultValue: SSTVSettings().noise,range: 0...1,percent: true)
                        ParameterSlider(name: L("Frequency Offset · Hz"),value: $model.sstvSettings.frequencyOffset,defaultValue: SSTVSettings().frequencyOffset,range: -400...400)
                        ParameterSlider(name: L("Drift · Hz"),value: $model.sstvSettings.drift,defaultValue: SSTVSettings().drift,range: -400...400)
                        ParameterSlider(name: L("Clock Error · ppm"),value: $model.sstvSettings.clockPPM,defaultValue: SSTVSettings().clockPPM,range: -3000...3000)
                        ParameterSlider(name: L("Dropout"),value: $model.sstvSettings.dropout,defaultValue: SSTVSettings().dropout,range: 0...0.6,percent: true)
                        ParameterSlider(name: L("Interference"),value: $model.sstvSettings.interference,defaultValue: SSTVSettings().interference,range: 0...1,percent: true)
                        ParameterSlider(name: L("Interference Tone · Hz"),value: $model.sstvSettings.interferenceHz,defaultValue: SSTVSettings().interferenceHz,range: 1000...2800)
                    }.padding(.top,6)
                }
                GroupBox(L("MIC → Channel")) {
                    VStack(alignment: .leading,spacing: 10) {
                        Toggle(L("Enable microphone noise"),isOn: Binding(get: { model.microphoneEnabled },set: { value in
                            if value != model.microphoneEnabled { model.toggleMicrophone() }
                        }))
                        ProgressView(value: Double(model.microphoneLevel)).tint(.green)
                            .accessibilityLabel(L("Microphone input level"))
                        ParameterSlider(name: L("Mic Gain"),value: $model.microphoneGain,defaultValue: PreviewModel.defaultMicrophoneGain,range: 0...20)
                        Text(model.microphoneStatus).font(.caption2).foregroundStyle(.secondary)
                        Text(L("After starting TX/RX, speak or make sounds into the microphone. At higher speeds the latest audio is looped; the microphone is disabled when transmission ends.")).font(.caption2).foregroundStyle(.secondary)
                        if model.monitorTX {
                            Text(L("Speaker TX audio is also picked up by the microphone; use headphones to avoid feedback.")).font(.caption2).foregroundStyle(.orange)
                        }
                    }.padding(.top,6)
                }
                GroupBox(L("Receiver")) {
                    VStack(alignment: .leading,spacing: 10) {
                        Toggle(L("Track local sync"),isOn: $model.sstvSettings.trackSync)
                        Text(L("Disable tracking to preserve clock-error skew. The mode and start are known; recording import, automatic VIS detection, and reacquisition after a complete loss of lock are not supported yet.")).font(.caption2).foregroundStyle(.secondary)
                    }.padding(.top,6)
                }
                HStack {
                    Text("Seed \(model.sstvSettings.seed)").font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button(L("New impairment")) { model.sstvSettings.seed &+= 1 }.controlSize(.small)
                }
                Button(L("Reset SSTV")) { model.sstvSettings = SSTVSettings() }.frame(maxWidth: .infinity)
            }.padding(.trailing,8)
        }
    }
}
