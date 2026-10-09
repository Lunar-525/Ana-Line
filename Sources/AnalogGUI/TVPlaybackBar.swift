import SwiftUI

struct TVPlaybackBar: View {
    @ObservedObject var model: PreviewModel
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
                    if !scrubbing { scrubbing = true; model.beginTVScrubbing() }
                    model.seekTV(to: min(1, max(0, value.location.x / geometry.size.width)) * model.tvDuration)
                }
                .onEnded { _ in
                    if scrubbing { scrubbing = false; model.endTVScrubbing() }
                })
            .focusable(enabled)
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
