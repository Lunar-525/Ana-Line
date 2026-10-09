import SwiftUI
import AnalogCore

struct TVTransmitterControls: View {
    @ObservedObject var state: TVControlState
    let instruments: TVTXInstrumentState
    init(model: PreviewModel) {
        model.tvControlState.bind(model)
        state = model.tvControlState; instruments = model.tvTXInstrumentState
    }
    var body: some View {
        VStack(alignment: .leading,spacing: 8) {
            Text(L("01 · Encoding / transmitter")).font(.system(size: 12,weight: .semibold))
                .foregroundStyle(.white.opacity(0.7))
            TVEncoderRack(state: state)
            TVFilterRack(state: state)
            TVPowerAmplifierRack(state: state,instruments: instruments)
        }.frame(minWidth: 340,maxWidth: 420).environment(\.colorScheme,.dark)
            .disabled(state.busy).frame(maxWidth: .infinity,alignment: .leading)
    }
}
struct TVReceiverControls: View {
    let model: PreviewModel
    var body: some View {
        TVSignalPanel(title: "03 · Receiver / reconstruction") {
            HStack(alignment: .top,spacing: 16) {
                VStack(spacing: 16) {
                    TVTunerControls(model: model)
                    TVAGCControls(model: model)
                }.frame(maxWidth: .infinity)
                TVSyncControls(model: model).frame(maxWidth: .infinity)
                TVYCControls(model: model).frame(maxWidth: .infinity)
            }
        }
    }
}
struct TVAGCControls: View {
    @ObservedObject var model: TVControlState
    init(model: PreviewModel) { model.tvControlState.bind(model); self.model = model.tvControlState }
    var body: some View {
        GroupBox(L("AGC dynamics")) {
            VStack(spacing: 10) {
                Toggle(L("Slow / underdamped AGC"),isOn: $model.tvChannel.receiverDamage.agcEnabled)
                VStack(spacing: 10) {
                    ParameterSlider(name: L("AGC response · ms"),value: $model.tvChannel.receiverDamage.agcResponseMS,defaultValue: 250,range: 10...1000)
                    ParameterSlider(name: L("AGC overshoot"),value: $model.tvChannel.receiverDamage.agcOvershoot,defaultValue: 0,range: 0...1,percent: true)
                    ParameterSlider(name: L("Picture-sensitive AGC"),value: $model.tvChannel.receiverDamage.agcPictureSensitivity,defaultValue: 0,range: 0...1,percent: true)
                }.disabled(!model.tvChannel.receiverDamage.agcEnabled || !model.tvChannel.automaticGain)
            }.padding(.top,6)
        }
    }
}
struct TVSyncControls: View {
    @ObservedObject var model: TVControlState
    init(model: PreviewModel) { model.tvControlState.bind(model); self.model = model.tvControlState }
    var body: some View {
        GroupBox(L("H / V oscillator and PLL")) {
            VStack(spacing: 10) {
                Toggle(L("Sync circuit aging"),isOn: $model.tvChannel.receiverDamage.syncEnabled)
                VStack(spacing: 10) {
                    ParameterSlider(name: L("H response · ms"),value: $model.tvChannel.receiverDamage.horizontalResponseMS,defaultValue: 1,range: 0.05...50)
                    ParameterSlider(name: L("H dead zone · μs"),value: $model.tvChannel.receiverDamage.horizontalDeadZoneUS,defaultValue: 0,range: 0...5)
                    ParameterSlider(name: L("H jitter · μs"),value: $model.tvChannel.receiverDamage.horizontalJitterUS,defaultValue: 0,range: 0...8)
                    ParameterSlider(name: L("H oscillator · ppm"),value: $model.tvChannel.receiverDamage.horizontalOscillatorPPM,defaultValue: 0,range: -500...500)
                    ParameterSlider(name: L("V hold error · Hz"),value: $model.tvChannel.receiverDamage.verticalHoldHz,defaultValue: 0,range: -2...2)
                    ParameterSlider(name: L("V capture window · lines"),value: $model.tvChannel.receiverDamage.verticalCaptureLines,defaultValue: 8,range: 0...40)
                }.disabled(!model.tvChannel.receiverDamage.syncEnabled)
            }.padding(.top,6)
        }
    }
}
struct TVYCControls: View {
    @ObservedObject var model: TVControlState
    init(model: PreviewModel) { model.tvControlState.bind(model); self.model = model.tvControlState }
    var body: some View {
        GroupBox(L("Y/C separation")) {
            VStack(spacing: 10) {
                Picker(L("Separation"),selection: $model.tvChannel.decoder.separation) {
                    Text(L("Notch")).tag(TVSeparation.notch)
                    Text(L("Comb")).tag(TVSeparation.comb)
                }.pickerStyle(.segmented)
                Toggle(L("PAL delay line"),isOn: $model.tvChannel.decoder.palDelayLine).disabled(model.tvStandard != .pal)
                ParameterSlider(name: L("Comb failure"),value: $model.tvChannel.decoder.combFailure,defaultValue: 0,range: 0...1,percent: true)
                    .disabled(model.tvChannel.decoder.separation != .comb)
                ParameterSlider(name: L("Chroma leakage into luma"),value: $model.tvChannel.decoder.chromaLeakage,defaultValue: 0,range: 0...1,percent: true)
            }.padding(.top,6)
        }
    }
}
