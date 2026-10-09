import SwiftUI
import AppKit
import AnalogCore

@MainActor
final class TVTXInstrumentState: ObservableObject {
    @Published var reading: TVTransmitterTelemetry?
}

/// Frame-rate observations belong to the preview, transport and receiver views.
/// They must not invalidate the entire workspace, its layout and configuration.
@MainActor
final class TVPreviewState: ObservableObject {
    @Published var original: NSImage?
    @Published var processed: NSImage?
    @Published var time = 0.0
    @Published var status = ""
}

/// Receiver telemetry has its own cadence; image/time updates do not redraw
/// the spectrum and its text labels at the full video frame rate.
@MainActor
final class TVReceptionState: ObservableObject {
    @Published var soundCarrierDB: Float = -120
    @Published var lock: TelevisionLock = .searching
    @Published var synchronization = TelevisionSynchronization()
    @Published var agcDB: Float = 0
    @Published var carrierErrorHz = 0.0
    @Published var syncConfidence: Float = 0
    @Published var recoveredLines = 0
}

struct TVStatusText: View {
    @ObservedObject var state: TVPreviewState
    var body: some View {
        Text(state.status).font(.caption).foregroundStyle(.secondary)
            .lineLimit(1).textSelection(.enabled).help(state.status)
    }
}

struct TVLockText: View {
    @ObservedObject var state: TVReceptionState
    let model: PreviewModel
    var body: some View { Text("\(model.terrestrialSystem.rawValue) · \(model.tvLockDescription)") }
}

struct PreviewCanvasView: View {
    @ObservedObject var model: PreviewModel
    @ObservedObject var tvState: TVPreviewState
    init(model: PreviewModel) { self.model = model; tvState = model.tvPreviewState }
    var body: some View {
        ZStack {
            Color.black.opacity(0.3)
            if let before = model.displayOriginal, let after = model.processed {
                ComparisonView(before: before,after: after,
                    scanProgress: model.transmitting ? CGFloat(model.receivedRows)/CGFloat(model.sstvSettings.mode.height) : nil,
                    pasteImage: { model.pasteImage() },pasteEnabled: !model.busy).padding(12)
            } else {
                VStack(spacing: 10) {
                    Image(systemName: model.tool == .tv ? "film" : "photo.badge.plus").font(.system(size: 30))
                    Text(model.busy || model.rendering ? L("Generating processed result…") : model.tool == .tv ? L("Drop a video here to start") : L("Drop an image here, or press ⌘V to paste"))
                    Text(model.tool == .tv ? L("You can also click “Choose Video…” above") : L("You can also click “Choose Image…” above")).font(.caption)
                }.foregroundStyle(.secondary)
            }
        }
    }
}
