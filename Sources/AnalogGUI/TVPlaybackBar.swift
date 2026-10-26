import SwiftUI
import AppKit

struct TVPlayerView: View {
    @ObservedObject var model: PreviewModel
    @StateObject private var osd: TVOSDState
    @AppStorage("tvCRTEnabled") private var crtEnabled = false
    @State private var hovering = false
    @State private var scrubbing = false

    init(model: PreviewModel) {
        self.model = model
        _osd = StateObject(wrappedValue: TVOSDState(maxLines: Double(model.tvStandard.height)))
    }

    private var controlsVisible: Bool { hovering || scrubbing }

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            monitor
            TVPVMControlPanel(state: osd)
        }
        .frame(height: 480)
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .clipped()
        .background { keyboardShortcuts }
        .onAppear { syncOSD() }
        .onChange(of: model.tvStandard.height) { _ in syncOSD() }
        .onChange(of: crtEnabled) { enabled in
            if !enabled { osd.forcePowerOff() }
        }
    }

    /// MENU/BACK = ←, selection = ↑/↓, ENTER = Return or →.
    @ViewBuilder private var keyboardShortcuts: some View {
        Button("") { osd.menu() }
            .keyboardShortcut(.leftArrow, modifiers: [])
            .frame(width: 0, height: 0).opacity(0).accessibilityHidden(true)
        if osd.isOpen {
            Button("") { osd.up() }
                .keyboardShortcut(.upArrow, modifiers: [])
                .frame(width: 0, height: 0).opacity(0).accessibilityHidden(true)
            Button("") { osd.down() }
                .keyboardShortcut(.downArrow, modifiers: [])
                .frame(width: 0, height: 0).opacity(0).accessibilityHidden(true)
            Button("") { osd.enter() }
                .keyboardShortcut(.return, modifiers: [])
                .frame(width: 0, height: 0).opacity(0).accessibilityHidden(true)
            Button("") { osd.enter() }
                .keyboardShortcut(.rightArrow, modifiers: [])
                .frame(width: 0, height: 0).opacity(0).accessibilityHidden(true)
        }
    }

    private var monitor: some View {
        ZStack {
            PreviewCanvasView(model: model, osdOverlay: osdOverlayImage)
        }
        .frame(width: 640, height: 480)
        .overlay(alignment: .top) {
            if !osd.isOpen { TVMoireWarningView(model: model) }
        }
        .overlay(alignment: .bottom) {
            if !osd.isOpen {
                // Keep the bar mounted so Space still works when the pointer is outside.
                TVPlaybackBar(model: model, controlsVisible: controlsVisible) { scrubbing = $0 }
                    .padding(12)
                    .opacity(controlsVisible ? 1 : 0)
                    .allowsHitTesting(controlsVisible)
                    .accessibilityHidden(!controlsVisible)
                    .animation(.easeOut(duration: 0.12), value: controlsVisible)
            }
        }
    }

    private var osdOverlayImage: NSImage? {
        guard osd.isOpen else { return nil }
        return TVCRTOSDImage.make(state: osd)
    }

    private func syncOSD() {
        osd.maxLines = Double(model.tvStandard.height)
        osd.reload()
    }
}

struct TVPlaybackBar: View {
    @ObservedObject var model: PreviewModel
    @ObservedObject var state: TVPreviewState
    let controlsVisible: Bool
    let onScrubbingChanged: (Bool) -> Void
    init(model: PreviewModel, controlsVisible: Bool = true, onScrubbingChanged: @escaping (Bool) -> Void = { _ in }) {
        self.model = model
        state = model.tvPreviewState
        self.controlsVisible = controlsVisible
        self.onScrubbingChanged = onScrubbingChanged
    }
    @State private var scrubbing = false

    private var enabled: Bool { model.tvDuration > 0 && !model.busy }

    var body: some View {
        HStack(spacing: 0) {
            Button { model.toggleTVPlayback() } label: {
                Image(systemName: model.tvPlaying ? "pause.fill" : "play.fill")
                    .font(.system(size: 15, weight: .semibold))
                    .frame(width: 56, height: 48)
                    .background {
                        Rectangle().fill(model.tvPlaying ? EditingTool.tv.logoAccentColor : .clear)
                            .shadow(color: .black.opacity(model.tvPlaying ? 0.22 : 0), radius: 4, y: 2)
                    }
            }
            .buttonStyle(ToolModeButtonStyle())
            .keyboardShortcut(.space, modifiers: [])
            .help(model.tvPlaying ? L("Pause") : L("Play"))
            .accessibilityLabel(model.tvPlaying ? L("Pause") : L("Play"))

            Rectangle().fill(.black.opacity(0.12)).frame(width: 1, height: 20)
            seekTrack.padding(.horizontal, 20)
            Text("\(timecode(model.tvTime)) / \(timecode(model.tvDuration))")
                .font(.system(size: 12, weight: .medium, design: .monospaced))
                .monospacedDigit().foregroundStyle(.black)
                .fixedSize().padding(.trailing, 16)
            Rectangle().fill(.black.opacity(0.12)).frame(width: 1, height: 20)

            Button { model.tvMuted.toggle() } label: {
                Image(systemName: model.tvMuted ? "speaker.slash.fill" : "speaker.wave.2.fill")
                    .font(.system(size: 14, weight: .medium))
                    .frame(width: 48, height: 48)
            }
            .buttonStyle(ToolModeButtonStyle())
            .help(model.tvMuted ? L("Unmute") : L("Mute"))
            .accessibilityLabel(model.tvMuted ? L("Unmute") : L("Mute"))
        }
        .frame(height: 48)
        .background {
            Rectangle().fill(.white)
                .shadow(color: .black.opacity(0.35), radius: 5, y: 2)
        }
        .disabled(!enabled)
        .opacity(enabled ? 1 : 0.4)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(L("Playback controls"))
    }

    private var seekTrack: some View {
        GeometryReader { geometry in
            let progress = model.tvDuration > 0 ? min(1, max(0, model.tvTime / model.tvDuration)) : 0
            ZStack(alignment: .leading) {
                Rectangle().fill(.black.opacity(0.15)).frame(height: 4)
                Rectangle().fill(EditingTool.tv.logoAccentColor)
                    .frame(width: geometry.size.width * progress, height: 4)
                Rectangle().fill(.black).frame(width: 6, height: 18)
                    .offset(x: min(max(0, geometry.size.width * progress - 3), max(0, geometry.size.width - 6)))
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0)
                .onChanged { value in
                    guard enabled, geometry.size.width > 0 else { return }
                    if !scrubbing {
                        scrubbing = true
                        onScrubbingChanged(true)
                        model.beginTVScrubbing()
                    }
                    model.seekTV(to: min(1, max(0, value.location.x / geometry.size.width)) * model.tvDuration)
                }
                .onEnded { _ in
                    if scrubbing {
                        scrubbing = false
                        model.endTVScrubbing()
                        onScrubbingChanged(false)
                    }
                })
            .focusable(enabled && controlsVisible)
            .onMoveCommand { direction in
                guard enabled else { return }
                if direction == .left { model.seekTV(to: model.tvTime - 5) }
                if direction == .right { model.seekTV(to: model.tvTime + 5) }
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(L("Playback position"))
            .accessibilityValue("\(timecode(model.tvTime)) / \(timecode(model.tvDuration))")
            .accessibilityAdjustableAction { direction in
                guard enabled else { return }
                model.seekTV(to: model.tvTime + (direction == .increment ? 5 : -5))
            }
        }.frame(height: 48)
    }

    private func timecode(_ time: Double) -> String {
        let seconds = max(0, Int(time))
        if seconds >= 3600 {
            return String(format: "%d:%02d:%02d", seconds / 3600, seconds / 60 % 60, seconds % 60)
        }
        return String(format: "%02d:%02d", seconds / 60, seconds % 60)
    }
}
