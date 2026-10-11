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
    private var configuration: String {
        #if DEBUG
        return "Debug · DSP unoptimized"
        #else
        return "Release · DSP optimized"
        #endif
    }
    private var version: String? {
        let info = Bundle.main.infoDictionary ?? [:]
        let build = info["CFBundleVersion"] as? String
        let buildTime = info["AnaLineBuildTime"] as? String
        guard let build else { return nil }
        if let buildTime { return "Build \(build) · \(buildTime)" }
        return "Build \(build)"
    }

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
        }
        .padding(40)
        .frame(width: 440)
        .preferredColorScheme(.dark)
    }
}
