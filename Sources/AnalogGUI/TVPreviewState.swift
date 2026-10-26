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
    @Published var crtHistoryID: UInt64 = 0
    @Published var crtBrightness: TVCRTBrightnessReading?
    @Published var crtDrawableSize: CGSize = .zero
    @Published var original: NSImage?
    @Published var processed: NSImage?
    @Published var time = 0.0
    @Published var status = ""
    @Published var playbackRate: Float = 1
    @Published var droppedFrames: Int64 = 0
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
        HStack(spacing: 6) {
            Text(state.status).foregroundStyle(.secondary).lineLimit(1).textSelection(.enabled).help(state.status)
            Text(String(format: "%.1fx",state.playbackRate))
                .monospacedDigit().fixedSize()
                .foregroundStyle(Self.isNormalSpeed(state.playbackRate) ? Color.green : .red)
            if state.droppedFrames > 0 {
                Text("⚠ DROP \(state.droppedFrames)").foregroundStyle(.red)
                    .monospacedDigit().fixedSize()
                    .accessibilityLabel(L("Frames dropped") + " \(state.droppedFrames)")
            }
        }.font(.caption)
    }
    static func isNormalSpeed(_ rate: Float) -> Bool { rate.isFinite && abs(rate-1) < 0.005 }
}

struct PreviewCanvasView: View {
    @AppStorage("tvCRTEnabled") private var crtEnabled = false
    @AppStorage("tvCRTHDR") private var crtHDR = true
    @AppStorage("tvCRTBrightness") private var crtBrightness = 2.0
    @AppStorage("tvCRTAutomaticLines") private var crtAutomaticLines = true
    @AppStorage("tvCRTLines") private var crtLines = 240.0
    @AppStorage("tvCRTMaskStrength") private var crtMaskStrength = 0.8
    @AppStorage("tvCRTMaskType") private var crtMaskType = TVCRTMaskType.apertureGrille.rawValue
    @AppStorage("tvCRTScanlines") private var crtScanlines = 480.0
    @ObservedObject var model: PreviewModel
    @ObservedObject var tvState: TVPreviewState
    init(model: PreviewModel) { self.model = model; tvState = model.tvPreviewState }
    var body: some View {
        ZStack {
            if model.tool != .tv { Color.black.opacity(0.3) }
            if model.tool == .tv && model.tvDuration <= 0 {
                TVNoSignalView(standard: model.tvStandard,preparing: model.busy)
            } else if let before = model.displayOriginal, let after = model.processed {
                ComparisonView(before: before,after: after,
                    scanProgress: model.transmitting ? CGFloat(model.receivedRows)/CGFloat(model.sstvSettings.mode.height) : nil,
                    crtEnabled: model.tool == .tv && crtEnabled, crtHDR: crtHDR, crtBrightness: crtBrightness,
                    crtScanlines: crtAutomaticLines ? 0 : crtScanlines,
                    crtLines: crtLines, crtMaskStrength: crtMaskStrength,
                    crtMaxLines: Double(model.tvStandard.height),
                    crtMaskType: crtMaskType,
                    crtHistoryID: tvState.crtHistoryID,
                    onCRTBrightness: { tvState.crtBrightness = $0 },
                    onCRTDrawableSize: { tvState.crtDrawableSize = $0 },
                    pasteImage: { model.pasteImage() },pasteEnabled: !model.busy).padding(model.tool == .tv ? 0 : 12)
            } else if model.tool == .tv {
                TVNoSignalView(standard: model.tvStandard,preparing: model.busy || model.rendering)
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
