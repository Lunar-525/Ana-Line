import Foundation
import CryptoKit
import AnalogCore
import Darwin

public struct TVMediaCacheConfiguration: Sendable {
    public let directory: URL
    public let maximumBytes: Int64
    public init(directory: URL,maximumBytes: Int64) {
        self.directory = directory.standardizedFileURL.resolvingSymlinksInPath()
        self.maximumBytes = max(0,maximumBytes)
    }
    public func trim() { TVMediaCache.trim(self) }
    var storageDirectory: URL { directory.appendingPathComponent("Terrestrial-v\(TVMediaCache.revision)",isDirectory: true) }
}

/// Content-addressed, versioned conversion outputs. Only complete entries are
/// published. Live renderers lease entries so LRU eviction cannot break playback.
enum TVMediaCache {
    static let revision = 1
    private static let lock = NSLock()
    nonisolated(unsafe) private static var users = [String:Int]()
    nonisolated(unsafe) private static var limits = [String:TVMediaCacheConfiguration]()
    private static func identity(_ url: URL) -> String {
        // Foundation may retain /var for a newly created path while directory
        // enumeration reports /private/var. Resolve existing filesystem paths
        // at the point they enter the live-entry registry.
        guard let resolved = realpath(url.path,nil) else { return url.standardizedFileURL.path }
        defer { free(resolved) }
        return String(cString: resolved)
    }
    struct Manifest: Codable, Sendable {
        let revision: Int
        let durations: [String:Double]
        let sizes: [String:Int64]
        var hasAudio: Bool { sizes["audio.f32le"] != nil }
    }
    final class Lease: @unchecked Sendable {
        let directory: URL
        let manifest: Manifest
        private let registryKey: String
        private let parentKey: String
        init(directory: URL,manifest: Manifest) {
            self.directory = directory; self.manifest = manifest
            registryKey = identity(directory); parentKey = identity(directory.deletingLastPathComponent())
        }
        deinit { lock.withLock {
            let count = (users[registryKey] ?? 1)-1
            if count == 0 { users.removeValue(forKey: registryKey) } else { users[registryKey] = count }
            if let configuration = limits[parentKey] { prune(configuration,reserving: 0) }
        } }
        func video(_ standard: TVStandard) -> URL { directory.appendingPathComponent("\(standard.rawValue).mp4") }
        var audio: URL? { manifest.hasAudio ? directory.appendingPathComponent("audio.f32le") : nil }
    }
    static func key(for source: URL) throws -> String {
        let input = try FileHandle(forReadingFrom: source); defer { try? input.close() }
        var hash = SHA256(); hash.update(data: Data("AnaLine dual-standard conversion v\(revision)".utf8))
        while let bytes = try input.read(upToCount: 1_048_576),!bytes.isEmpty {
            try Task.checkCancellation(); hash.update(data: bytes)
        }
        return hash.finalize().map { String(format: "%02x",$0) }.joined()
    }
    private static func manifest(at directory: URL) -> Manifest? {
        guard let data = try? Data(contentsOf: directory.appendingPathComponent("manifest.json")),
              let value = try? JSONDecoder().decode(Manifest.self,from: data),value.revision == revision,
              Set(value.durations.keys) == Set(TVStandard.allCases.map(\.rawValue)),
              value.durations.values.allSatisfy({ $0.isFinite && $0 > 0 }),
              Set(value.sizes.keys) == Set(TVStandard.allCases.map { "\($0.rawValue).mp4" } + (value.hasAudio ? ["audio.f32le"] : []))
        else { return nil }
        for (file,size) in value.sizes {
            guard size > 0,let actual = try? directory.appendingPathComponent(file).resourceValues(forKeys: [.fileSizeKey,.isRegularFileKey]),
                  actual.isRegularFile == true,Int64(actual.fileSize ?? 0) == size else { return nil }
        }
        return value
    }
    private static func lease(_ directory: URL,_ manifest: Manifest) -> Lease {
        users[identity(directory),default: 0] += 1
        try? FileManager.default.setAttributes([.modificationDate:Date()],ofItemAtPath: directory.path)
        return Lease(directory: directory,manifest: manifest)
    }
    static func acquire(key: String,configuration: TVMediaCacheConfiguration) -> Lease? {
        lock.withLock {
            prune(configuration,reserving: 0)
            let directory = configuration.storageDirectory.appendingPathComponent(key,isDirectory: true)
            guard let value = manifest(at: directory) else { return nil }
            return lease(directory,value)
        }
    }
    static func trim(_ configuration: TVMediaCacheConfiguration) {
        lock.withLock { _ = prune(configuration,reserving: 0) }
    }
    /// Failure to cache is nonfatal: the renderer can still use its scratch files.
    static func store(key: String,videos: [TVStandard:URL],durations: [TVStandard:Double],audio: URL?,
                      configuration: TVMediaCacheConfiguration) -> Lease? {
        lock.withLock {
            let fm = FileManager.default, root = configuration.storageDirectory
            let directory = root.appendingPathComponent(key,isDirectory: true)
            if let existing = manifest(at: directory) { return lease(directory,existing) }
            var sources = Dictionary(uniqueKeysWithValues: videos.map { ("\($0.key.rawValue).mp4",$0.value) })
            if let audio { sources["audio.f32le"] = audio }
            let sizes = sources.mapValues { Int64((try? $0.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0) }
            let value = Manifest(revision: revision,durations: Dictionary(uniqueKeysWithValues: durations.map { ($0.key.rawValue,$0.value) }),sizes: sizes)
            guard let metadata = try? JSONEncoder().encode(value) else { return nil }
            let bytes = sizes.values.reduce(Int64(metadata.count),+)
            guard sizes.values.allSatisfy({ $0 > 0 }),bytes <= configuration.maximumBytes else { return nil }
            let staging = root.appendingPathComponent(".preparing-\(UUID().uuidString)",isDirectory: true)
            defer { try? fm.removeItem(at: staging) }
            do {
                try fm.createDirectory(at: root,withIntermediateDirectories: true)
                guard prune(configuration,reserving: bytes) else { return nil }
                try fm.createDirectory(at: staging,withIntermediateDirectories: true)
                for (name,source) in sources { try fm.copyItem(at: source,to: staging.appendingPathComponent(name)) }
                try metadata.write(to: staging.appendingPathComponent("manifest.json"),options: .atomic)
                if fm.fileExists(atPath: directory.path) { try fm.removeItem(at: directory) }
                try fm.moveItem(at: staging,to: directory)
                return lease(directory,value)
            } catch { return nil }
        }
    }
    @discardableResult
    private static func prune(_ configuration: TVMediaCacheConfiguration,reserving: Int64) -> Bool {
        let fm = FileManager.default
        limits[identity(configuration.storageDirectory)] = configuration
        let folders = (try? fm.contentsOfDirectory(at: configuration.storageDirectory,includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
        for folder in folders where folder.lastPathComponent.hasPrefix(".preparing-") {
            if let date = try? folder.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate,
               Date().timeIntervalSince(date) > 86_400 { try? fm.removeItem(at: folder) }
        }
        // Only our 64-character content keys are owned by the cache, even when
        // the user chooses a folder containing unrelated files.
        var entries = [(url:URL,bytes:Int64,date:Date)]()
        for folder in folders where folder.lastPathComponent.count == 64 && folder.lastPathComponent.allSatisfy({ $0.isHexDigit }) {
            if let value = manifest(at: folder) {
                let metadataSize = Int64((try? folder.appendingPathComponent("manifest.json").resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
                let size = value.sizes.values.reduce(metadataSize,+)
                entries.append((folder,size,(try? folder.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast))
            } else if users[identity(folder)] == nil { try? fm.removeItem(at: folder) }
        }
        var total = entries.reduce(Int64(0)) { $0+$1.bytes }
        for entry in entries.sorted(by: { $0.date < $1.date }) where total+reserving > configuration.maximumBytes {
            if users[identity(entry.url)] == nil {
                do { try fm.removeItem(at: entry.url); total -= entry.bytes } catch {}
            }
        }
        return total+reserving <= configuration.maximumBytes
    }
}
