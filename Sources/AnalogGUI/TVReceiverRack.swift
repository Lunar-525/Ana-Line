import SwiftUI
import AnalogCore

/// Configuration-only rack faces; live reception instruments keep their own clock.
struct TVTunerAGCRack: View {
    @ObservedObject var state: TVControlState
    @State private var service = false
    private var defaults: TerrestrialSettings { TerrestrialSettings(system: state.terrestrialSystem) }
    private var aging: Bool { state.tvChannel.automaticGain && state.tvChannel.receiverDamage.agcEnabled }
    var body: some View {
        TVReceiverFace {
            HStack(spacing: 8) {
                TVRackHeader(name: "TUNER / AGC",subtitle: "RF / IF",service: $service)
                TVReceiverModeButton(name: "AFT",label: "Automatic fine tuning",enabled: $state.tvChannel.automaticFineTuning)
                TVReceiverModeButton(name: "AGC LAG",label: "Slow / underdamped AGC",enabled: $state.tvChannel.receiverDamage.agcEnabled)
                    .disabled(!state.tvChannel.automaticGain)
            }
            HStack(spacing: 8) {
                TVRackSwitch(enabled: $state.tvChannel.automaticGain,label: "Automatic gain control")
                TVRotaryParameter(name: "Tuning offset · kHz",value: $state.tvChannel.tuningOffsetKHz,
                    range: -1500...1500,initial: 0,step: 1,unit: "kHz",digits: 0,horizontal: true)
                TVRotaryParameter(name: "IF bandwidth · MHz",value: $state.tvChannel.rfBandwidthMHz,
                    range: 1...10,initial: defaults.rfBandwidthMHz,step: 0.05,unit: "MHz",digits: 2,horizontal: true)
                if state.tvChannel.automaticGain {
                    TVRotaryParameter(name: "AGC response · ms",value: $state.tvChannel.receiverDamage.agcResponseMS,
                        range: 10...1000,initial: 250,step: 5,unit: "ms",digits: 0,active: aging,horizontal: true)
                } else {
                    TVRotaryParameter(name: "Receiver gain · dB",value: $state.tvChannel.manualGainDB,
                        range: -12...60,initial: 0,step: 0.1,unit: "dB",horizontal: true)
                }
                TVRotaryParameter(name: "AGC overshoot",value: $state.tvChannel.receiverDamage.agcOvershoot,
                    range: 0...1,initial: 0,step: 0.01,digits: 0,percent: true,active: aging,horizontal: true)
            }
        }.popover(isPresented: $service) {
            TVServicePanel(title: "Tuner / AGC calibration") {
                Text(L("The left switch controls AGC. Bypass enables manual gain. AFT controls automatic fine tuning."))
                    .font(.system(size: 11)).foregroundStyle(.white.opacity(0.7))
                Toggle(L("Automatic fine tuning"),isOn: $state.tvChannel.automaticFineTuning)
                Toggle(L("Automatic gain control"),isOn: $state.tvChannel.automaticGain)
                Toggle(L("Slow / underdamped AGC"),isOn: $state.tvChannel.receiverDamage.agcEnabled)
                    .disabled(!state.tvChannel.automaticGain)
                HStack(spacing: 12) {
                    TVRotaryParameter(name: "Picture-sensitive AGC",value: $state.tvChannel.receiverDamage.agcPictureSensitivity,
                        range: 0...1,initial: 0,step: 0.01,digits: 0,percent: true,active: aging)
                    TVRotaryParameter(name: "Receiver gain · dB",value: $state.tvChannel.manualGainDB,
                        range: -12...60,initial: 0,step: 0.1,unit: "dB",active: !state.tvChannel.automaticGain)
                }
                Divider().overlay(.white.opacity(0.12))
                Text(L("Shared front end"))
                    .font(.system(size: 11)).foregroundStyle(.white.opacity(0.7))
                Toggle(L("Front-end overload / nonlinearity"),isOn: $state.tvChannel.frontEnd.enabled)
                Toggle(L("Common front-end AGC"),isOn: $state.tvChannel.frontEnd.agcEnabled)
                HStack(spacing: 12) {
                    TVRotaryParameter(name: "Front-end gain · dB",value: $state.tvChannel.frontEnd.gainDB,
                        range: -20...60,initial: 0,step: 0.5,unit: "dB",digits: 1)
                    TVRotaryParameter(name: "Input saturation · dB",value: $state.tvChannel.frontEnd.inputSaturationDB,
                        range: -40...60,initial: 12,step: 1,unit: "dB",digits: 0,active: state.tvChannel.frontEnd.enabled)
                    TVRotaryParameter(name: "IF saturation · dB",value: $state.tvChannel.frontEnd.ifSaturationDB,
                        range: -40...60,initial: 12,step: 1,unit: "dB",digits: 0,active: state.tvChannel.frontEnd.enabled)
                }
                Picker(L("Sound detection"),selection: $state.tvChannel.frontEnd.soundDetection) {
                    Text(L("Split sound")).tag(TVSoundDetectionMode.splitSound)
                    Text(L("Intercarrier")).tag(TVSoundDetectionMode.intercarrier)
                }.pickerStyle(.segmented)
                Picker(L("Sound notch"),selection: $state.tvChannel.frontEnd.soundNotchPolicy) {
                    Text(L("Suppress")).tag(TVSoundNotchPolicy.suppressed)
                    Text(L("Bypass")).tag(TVSoundNotchPolicy.bypassed)
                }.pickerStyle(.segmented)
            }
        }
    }
}

struct TVSyncYCRack: View {
    @ObservedObject var state: TVControlState
    @State private var service = false
    private var on: Bool { state.tvChannel.receiverDamage.syncEnabled }
    private var comb: Bool { state.tvChannel.decoder.separation == .comb }
    var body: some View {
        TVReceiverFace {
            HStack(spacing: 8) {
                TVRackHeader(name: "SYNC / Y-C",subtitle: "PLL / DECODER",service: $service)
                TVReceiverModeButton(name: comb ? "COMB" : "NOTCH",label: "Y/C separation",enabled:
                    Binding(get: { comb },set: { state.tvChannel.decoder.separation = $0 ? .comb : .notch }))
                    .accessibilityValue(L(comb ? "Comb" : "Notch"))
                TVReceiverModeButton(name: "PAL DELAY",label: "PAL delay line",enabled: $state.tvChannel.decoder.palDelayLine)
                    .disabled(state.tvStandard != .pal)
            }
            HStack(spacing: 8) {
                TVRackSwitch(enabled: $state.tvChannel.receiverDamage.syncEnabled,label: "Sync circuit aging")
                TVRotaryParameter(name: "H jitter · μs",value: $state.tvChannel.receiverDamage.horizontalJitterUS,
                    range: 0...8,initial: 0,step: 0.05,unit: "μs",digits: 2,active: on,horizontal: true)
                TVRotaryParameter(name: "V hold error · Hz",value: $state.tvChannel.receiverDamage.verticalHoldHz,
                    range: -2...2,initial: 0,step: 0.01,unit: "Hz",digits: 2,active: on,horizontal: true)
                TVRotaryParameter(name: "Comb failure",value: $state.tvChannel.decoder.combFailure,
                    range: 0...1,initial: 0,step: 0.01,digits: 0,percent: true,active: comb,horizontal: true)
                TVRotaryParameter(name: "Chroma leakage into luma",value: $state.tvChannel.decoder.chromaLeakage,
                    range: 0...1,initial: 0,step: 0.01,digits: 0,percent: true,horizontal: true)
            }
        }.popover(isPresented: $service) {
            TVServicePanel(title: "Sync / Y-C calibration") {
                HStack(spacing: 10) {
                    TVRotaryParameter(name: "H response · ms",value: $state.tvChannel.receiverDamage.horizontalResponseMS,
                        range: 0.05...50,initial: 1,step: 0.05,unit: "ms",digits: 2,active: on)
                    TVRotaryParameter(name: "H dead zone · μs",value: $state.tvChannel.receiverDamage.horizontalDeadZoneUS,
                        range: 0...5,initial: 0,step: 0.05,unit: "μs",digits: 2,active: on)
                }
                HStack(spacing: 10) {
                    TVRotaryParameter(name: "H oscillator · ppm",value: $state.tvChannel.receiverDamage.horizontalOscillatorPPM,
                        range: -500...500,initial: 0,step: 5,unit: "ppm",digits: 0,active: on)
                    TVRotaryParameter(name: "V capture window · lines",value: $state.tvChannel.receiverDamage.verticalCaptureLines,
                        range: 0...40,initial: 8,step: 1,digits: 0,active: on)
                }
                Picker(L("Y/C separation"),selection: $state.tvChannel.decoder.separation) {
                    Text(L("Comb")).tag(TVSeparation.comb)
                    Text(L("Notch")).tag(TVSeparation.notch)
                }.pickerStyle(.segmented)
                Toggle(L("PAL delay line"),isOn: $state.tvChannel.decoder.palDelayLine).disabled(state.tvStandard != .pal)
            }
        }
    }
}

private struct TVReceiverFace<Content: View>: View {
    @ViewBuilder var content: Content
    var body: some View {
        VStack(spacing: 4) { content }
            .padding(.horizontal,23).padding(.vertical,5).frame(height: 84)
            .background(TVRackHousing(finish: .transmitter))
    }
}

private struct TVReceiverModeButton: View {
    let name: String, label: String
    @Binding var enabled: Bool
    @Environment(\.isEnabled) private var available
    var body: some View {
        Button { enabled.toggle() } label: {
            HStack(spacing: 4) {
                Circle().fill(enabled ? Color(red: 0.9,green: 0.77,blue: 0.4) : Color(white: 0.2)).frame(width: 4,height: 4)
                Text(name).font(.system(size: 7,weight: .medium,design: .monospaced)).fixedSize()
            }.foregroundStyle(.white.opacity(0.75)).padding(.horizontal,5).frame(height: 16)
                .background(Color(white: 0.045)).overlay(Rectangle().stroke(.white.opacity(0.16),lineWidth: 0.5))
        }.buttonStyle(.plain).opacity(available ? 1 : 0.35).help(L(label))
            .accessibilityLabel(L(label)).accessibilityValue(enabled ? L("Active") : L("Bypass"))
    }
}
