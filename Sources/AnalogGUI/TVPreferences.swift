import SwiftUI
import AppKit
import AnalogImaging

@MainActor
final class TVPreferences: ObservableObject {
    static let shared = TVPreferences()
    static var defaultDirectory: URL {
        (FileManager.default.urls(for: .cachesDirectory,in: .userDomainMask).first ?? FileManager.default.temporaryDirectory)
            .appendingPathComponent("AnaLine/Media",isDirectory: true)
    }
    private let defaults: UserDefaults
    @Published var cachePath: String { didSet { defaults.set(cachePath,forKey: "tvCachePath"); trim() } }
    @Published var cacheLimitGB: Double { didSet {
        let valid = cacheLimitGB.isFinite ? min(1000,max(0,cacheLimitGB)) : 20
        if cacheLimitGB != valid { cacheLimitGB = valid; return }
        defaults.set(cacheLimitGB,forKey: "tvCacheLimitGB"); trim()
    } }
    @Published var bufferFrames: Int { didSet {
        let valid = min(60,max(1,bufferFrames))
        if bufferFrames != valid { bufferFrames = valid; return }
        defaults.set(bufferFrames,forKey: "tvBufferFrames")
    } }
    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        let path = defaults.string(forKey: "tvCachePath")
        cachePath = path?.hasPrefix("/") == true ? path! : Self.defaultDirectory.path
        let size = defaults.object(forKey: "tvCacheLimitGB") as? Double ?? 20
        cacheLimitGB = size.isFinite ? min(1000,max(0,size)) : 20
        bufferFrames = min(60,max(1,defaults.object(forKey: "tvBufferFrames") as? Int ?? 8))
    }
    var configuration: TVMediaCacheConfiguration {
        let size = cacheLimitGB.isFinite ? min(1000,max(0,cacheLimitGB)) : 20
        return TVMediaCacheConfiguration(directory: URL(fileURLWithPath: cachePath),maximumBytes: Int64(size*1_073_741_824))
    }
    private func trim() {
        let configuration = configuration
        Task.detached(priority: .utility) { configuration.trim() }
    }
    func chooseDirectory() {
        let panel = NSOpenPanel(); panel.canChooseFiles = false; panel.canChooseDirectories = true
        panel.canCreateDirectories = true; panel.directoryURL = configuration.directory
        if panel.runModal() == .OK,let url = panel.url { cachePath = url.path }
    }
}

struct TVPreferencesView: View {
    @ObservedObject var preferences: TVPreferences
    var body: some View {
        VStack(alignment: .leading,spacing: 12) {
            Text(L("Terrestrial cache & playback")).font(.headline)
            HStack(alignment: .top) {
                VStack(alignment: .leading,spacing: 4) {
                    Text(L("Cache location"))
                    Text(preferences.cachePath).font(.caption).foregroundStyle(.secondary)
                        .textSelection(.enabled).fixedSize(horizontal: false,vertical: true)
                }.frame(maxWidth: .infinity,alignment: .leading)
                Button(L("Choose…")) { preferences.chooseDirectory() }.fixedSize()
            }
            HStack {
                Text(L("Maximum cache size")); Spacer()
                TextField("",value: $preferences.cacheLimitGB,format: .number.precision(.fractionLength(0...1)))
                    .labelsHidden().textFieldStyle(.roundedBorder)
                    .frame(width: 65).multilineTextAlignment(.trailing)
                Text("GiB")
            }
            Text(L("Oldest unused entries are removed first. 0 disables disk caching. Files in use remain protected until released."))
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false,vertical: true)
            Stepper(value: $preferences.bufferFrames,in: 1...60) {
                HStack { Text(L("Playback buffer")); Spacer(); Text("\(preferences.bufferFrames) " + L("frames")) }
            }
            Text(L("Applied on next playback. Small buffers reduce startup delay but increase frame drops. Playback always runs at 1×."))
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false,vertical: true)
        }
    }
}
