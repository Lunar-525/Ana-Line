import SwiftUI

/// Live camera through the whole chain: what the camera sees, as the receiver
/// would show it. Real time first, so the frame rate and the number of dropped
/// frames are on screen rather than hidden.
struct CameraView: View {
    @StateObject private var camera = MobileCamera()
    @State private var standard = TVStandard.ntsc
    private let onClose: () -> Void

    init(standard: TVStandard = .ntsc, onClose: @escaping () -> Void) {
        self._standard = State(initialValue: standard)
        self.onClose = onClose
    }

    /// The executable's own timestamp, so which build is on the phone is never a
    /// guess — useful when a fix is being checked on a device.
    private var buildStamp: String {
        guard let url = Bundle.main.executableURL,
              let date = try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
        else { return "" }
        let formatter = DateFormatter()
        formatter.dateFormat = "MM-dd HH:mm"
        return "构建 " + formatter.string(from: date)
    }

    var body: some View {
        VStack(spacing: 12) {
            ZStack {
                Color.black
                if let image = camera.simulated {
                    Image(uiImage: image)
                        .resizable()
                        .interpolation(.none)
                        .aspectRatio(4.0/3.0, contentMode: .fit)
                } else {
                    ProgressView().tint(.white)
                }
            }
            .frame(maxHeight: .infinity)

            HStack(spacing: 16) {
                Picker("制式", selection: $standard) {
                    ForEach(TVStandard.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .onChange(of: standard) { _, value in
                    camera.setStandard(value, settings: TerrestrialSettings(system: TerrestrialSystem(video: value)))
                }
            }

            // Plain buttons, not a menu picker: a menu needs a custom Binding whose
            // selection state can lag the observable, which made a tap appear to do
            // nothing until it was repeated. The active preset is highlighted, so
            // whether a tap registered is visible at a glance.
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(LivePreset.allCases) { item in
                        Button { camera.apply(item) } label: {
                            Text(item.rawValue)
                                .font(.system(size: 13, weight: camera.preset == item ? .semibold : .regular))
                                .padding(.horizontal, 12).padding(.vertical, 6)
                                .background(camera.preset == item ? Color.accentColor : Color.white.opacity(0.14),
                                            in: Capsule())
                                .foregroundStyle(camera.preset == item ? Color.black : Color.white)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.vertical, 2)
            }
            HStack {
                Text(String(format: "%.1f fps · %.0f ms · 丢帧 %d · 伴音补零 %d",
                            camera.fps, camera.processingMS, camera.dropped, camera.audioGaps))
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.secondary)
                Spacer()
                Button(camera.recording ? "停止并存入相册" : "开始录制") {
                    camera.recording ? camera.endRecording() : camera.beginRecording()
                }
                .buttonStyle(.borderedProminent)
                .tint(camera.recording ? .red : .accentColor)
                Button("关闭") { onClose() }
            }
            Text(buildStamp).font(.caption2).foregroundStyle(.tertiary)
            Text(camera.message.isEmpty
                 ? "实时优先：跟不上的帧直接丢弃、不排队；伴音走电视伴音载波回来，录进文件的是接收机听到的声音。"
                 : camera.message)
                .font(.caption2).foregroundStyle(.secondary)
        }
        .padding()
        .background(Color.black.ignoresSafeArea())
        .preferredColorScheme(.dark)
        .task {
            await camera.start(standard: standard,
                               settings: TerrestrialSettings(system: TerrestrialSystem(video: standard)))
        }
        .onDisappear { camera.stop() }
    }
}
