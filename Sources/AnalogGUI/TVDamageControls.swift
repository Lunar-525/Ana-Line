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
    @ObservedObject var state: TVControlState
    let model: PreviewModel
    init(model: PreviewModel) {
        self.model = model
        model.tvControlState.bind(model)
        state = model.tvControlState
    }
    var body: some View {
        VStack(alignment: .leading,spacing: 8) {
            HStack {
                Text(L("03 · Receiver / reconstruction")).font(.system(size: 12,weight: .semibold))
                Spacer()
                Button { state.resetReceiver() } label: {
                    Image(systemName: "arrow.counterclockwise")
                }.buttonStyle(.plain).help(L("Reset reception")).accessibilityLabel(L("Reset reception"))
            }
            .foregroundStyle(.white.opacity(0.7))
            TVTunerAGCRack(state: state)
            TVSyncYCRack(state: state)
            TVReceptionView(model: model)
        }.frame(minWidth: 340,maxWidth: .infinity).environment(\.colorScheme,.dark)
            .disabled(state.busy)
    }
}
