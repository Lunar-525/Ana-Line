import SwiftUI

struct AnaLineAboutCommands: Commands {
    @Environment(\.openWindow) private var openWindow

    var body: some Commands {
        CommandGroup(replacing: .appInfo) {
            Button(L("About Ana-Line")) { openWindow(id: "about") }
        }
    }
}

struct AnaLineAboutView: View {
    // Build identity is read once in BuildStamp, so the About panel and the
    // workspace header always report the same number.
    private var configuration: String { BuildStamp.configuration }
    private var version: String? { BuildStamp.summary }

    var body: some View {
        VStack(spacing: 18) {
            AnaLineLogo(width: 310)
                .padding(.bottom, 4)
            Text("ANALOG IMAGE INSTRUMENTS")
                .font(.system(size: 11, weight: .medium, design: .monospaced))
                .tracking(2)
                .foregroundStyle(.secondary)
            if let version {
                Text(version)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Text(configuration)
                .font(.caption)
                .foregroundStyle(.secondary)
            Divider()
                .frame(width: 250)
                .padding(.top, 10)
            AsyncAlterMark(width: 210)
            Text("CVBS Engine powered by AsyncAlter")
                .font(.system(size: 11, weight: .regular, design: .monospaced))
                .tracking(1)
                .foregroundStyle(.secondary)
        }
        .padding(40)
        .frame(width: 440)
        .preferredColorScheme(.dark)
    }
}

#if DEBUG
/// Xcode's canvas renders this panel live: open Package.swift in Xcode, pick the
/// AnaLine (macOS) destination, and the About artwork, spacing and glow can be
/// adjusted while watching the result. The same view is also rendered headlessly
/// to a PNG by AnalogGUITests/TVAboutRenderTests.
#Preview("About") {
    AnaLineAboutView()
}

#Preview("AsyncAlter mark") {
    AsyncAlterMark(width: 210)
        .padding(24)
        .background(Color(red: 0.13, green: 0.13, blue: 0.14))
}
#endif
