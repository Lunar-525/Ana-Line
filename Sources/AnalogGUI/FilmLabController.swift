import SwiftUI
import AnalogCore

@MainActor
final class FilmLabController: ObservableObject {
    private struct Saved: Codable { var version = 1; var session: FilmLabSession; var source: String?; var preset: String?; var mix: Float? }
    @Published var session: FilmLabSession { didSet { persist() } }
    @Published private(set) var running = false
    @Published var speed: Float = 10
    @Published var scannerPreset = "none" { didSet { persist() } }
    @Published var scannerMix: Float = 1 { didSet { persist() } }
    @Published var persistenceError: String?
    private(set) var source: String?
    private let defaults: UserDefaults
    private var ticker: Task<Void,Never>?
    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        if let data = defaults.data(forKey: "filmLab.session.v1"),let saved = try? JSONDecoder().decode(Saved.self,from: data),saved.version == 1 {
            session = saved.session; source = saved.source
            scannerPreset = saved.preset ?? "none"; scannerMix = saved.mix ?? 1
        } else { session = FilmLabSession() }
    }
    private func persist() {
        do {
            let data = try JSONEncoder().encode(Saved(session: session,source: source,preset: scannerPreset,mix: scannerMix))
            defaults.set(data,forKey: "filmLab.session.v1")
        } catch { persistenceError = "无法保存暗房进度：\(error.localizedDescription)" }
    }
    private var cachedSource: URL {
        FileManager.default.urls(for: .applicationSupportDirectory,in: .userDomainMask)[0]
            .appendingPathComponent("AnaLine/FilmLab/source-image")
    }
    var resumeURL: URL? {
        if FileManager.default.fileExists(atPath: cachedSource.path) { return cachedSource }
        if let source, FileManager.default.fileExists(atPath: source) { return URL(fileURLWithPath: source) }
        return nil
    }
    func loaded(_ url: URL) {
        pause()
        let path = url.standardizedFileURL.path
        if path != cachedSource.path {
            do {
                let bytes = try Data(contentsOf: url)
                let cached = try? Data(contentsOf: cachedSource)
                if source != path || (cached != nil && cached != bytes) {
                    source = path; session = FilmLabSession()
                }
                try FileManager.default.createDirectory(at: cachedSource.deletingLastPathComponent(),withIntermediateDirectories: true)
                try bytes.write(to: cachedSource,options: .atomic)
            } catch { persistenceError = "原图缓存失败：\(error.localizedDescription)" }
        }
        persist()
    }
    func reset() { pause(); session = FilmLabSession() }
    func advance(_ seconds: Float) { session.advance(seconds: seconds) }
    func rewind(_ seconds: Float) { pause(); session.rewind(seconds: seconds) }
    func complete() { pause(); session.complete() }
    func undo() { pause(); session.undo() }
    func pause() { running = false; ticker?.cancel(); ticker = nil }
    func toggle() {
        if running { pause(); return }
        guard session.stage != .scan else { return }
        running = true
        ticker = Task { [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(for: .milliseconds(500)) } catch { break }
                guard let self, self.running else { break }
                let amount: Float = self.session.stage == .exposure ? 0.1 : self.speed*0.5
                self.advance(amount)
                if self.session.elapsed >= 7200 { self.pause(); break }
            }
        }
    }
}
