import XCTest
import Foundation
import AnalogCore
@testable import AnalogImaging

private final class CacheProgress: @unchecked Sendable {
    private let lock = NSLock()
    private var events = [TVPreparationProgress]()
    func append(_ value: TVPreparationProgress) { lock.withLock { events.append(value) } }
    var values: [TVPreparationProgress] { lock.withLock { events } }
}

final class TVMediaCacheTests: XCTestCase {
    private func folder() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("AnaLine-cache-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root,withIntermediateDirectories: true)
        return root
    }
    func testContentIdentityFollowsRenameAndDetectsChangedBytes() throws {
        let root = try folder(); defer { try? FileManager.default.removeItem(at: root) }
        let one = root.appendingPathComponent("one.mp4"),two = root.appendingPathComponent("two.mp4")
        try Data(repeating: 7,count: 2_100_000).write(to: one)
        let before = try TVMediaCache.key(for: one)
        try FileManager.default.moveItem(at: one,to: two)
        XCTAssertEqual(try TVMediaCache.key(for: two),before)
        let handle = try FileHandle(forWritingTo: two)
        try handle.seek(toOffset: 1_050_000); try handle.write(contentsOf: Data([8])); try handle.close()
        XCTAssertNotEqual(try TVMediaCache.key(for: two),before,"A middle-of-file change must invalidate the cache even with unchanged length")
    }
    func testLRUEvictionProtectsLiveEntriesAndHonorsReducedLimitOnRelease() throws {
        let root = try folder(); defer { try? FileManager.default.removeItem(at: root) }
        let cache = root.appendingPathComponent("cache")
        let configuration = TVMediaCacheConfiguration(directory: cache,maximumBytes: 100_000)
        let sources = Dictionary(uniqueKeysWithValues: TVStandard.allCases.map { ($0,root.appendingPathComponent("\($0.rawValue).mp4")) })
        for url in sources.values { try Data(repeating: 1,count: 128).write(to: url) }
        let durations: [TVStandard:Double] = [.pal: 1,.ntsc: 1]
        var live = TVMediaCache.store(key: String(repeating: "1",count: 64),videos: sources,durations: durations,audio: nil,configuration: configuration)
        let livePath = try XCTUnwrap(live?.directory)
        let second = try XCTUnwrap(TVMediaCache.store(key: String(repeating: "2",count: 64),videos: sources,durations: durations,audio: nil,configuration: configuration)?.directory)
        let third = try XCTUnwrap(TVMediaCache.store(key: String(repeating: "3",count: 64),videos: sources,durations: durations,audio: nil,configuration: configuration)?.directory)
        for (index,url) in [livePath,second,third].enumerated() {
            try FileManager.default.setAttributes([.modificationDate:Date(timeIntervalSince1970: Double(index))],ofItemAtPath: url.path)
        }
        let bytes = try FileManager.default.contentsOfDirectory(at: third,includingPropertiesForKeys: [.fileSizeKey])
            .reduce(Int64(0)) { try $0+Int64($1.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0) }
        let unrelated = cache.appendingPathComponent(String(repeating: "a",count: 64))
        try FileManager.default.createDirectory(at: unrelated,withIntermediateDirectories: true)
        withExtendedLifetime(live) {
            TVMediaCacheConfiguration(directory: cache,maximumBytes: bytes*2).trim()
            XCTAssertTrue(FileManager.default.fileExists(atPath: livePath.path))
            XCTAssertFalse(FileManager.default.fileExists(atPath: second.path))
            XCTAssertTrue(FileManager.default.fileExists(atPath: third.path))
            TVMediaCacheConfiguration(directory: cache,maximumBytes: 0).trim()
            XCTAssertTrue(FileManager.default.fileExists(atPath: livePath.path))
            XCTAssertFalse(FileManager.default.fileExists(atPath: third.path))
        }
        live = nil
        XCTAssertFalse(FileManager.default.fileExists(atPath: livePath.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: unrelated.path),"Only the dedicated Terrestrial cache namespace is managed")
        XCTAssertNil(TVMediaCache.store(key: String(repeating: "4",count: 64),videos: sources,durations: durations,audio: nil,
            configuration: TVMediaCacheConfiguration(directory: cache,maximumBytes: 10)))
    }
    func testPersistentHitNeverLaunchesTranscoderAndCorruptEntryIsRebuilt() async throws {
        let root = try folder(); defer { try? FileManager.default.removeItem(at: root) }
        let configuration = TVMediaCacheConfiguration(directory: root.appendingPathComponent("cache"),maximumBytes: 50_000_000)
        let source = root.appendingPathComponent("source.mp4")
        let process = Process(); process.executableURL = try XCTUnwrap(TVExecutableResolver.find("ffmpeg",path: "/usr/bin:/bin"))
        process.arguments = ["-hide_banner","-loglevel","error","-y","-f","lavfi","-i","testsrc2=size=160x120:rate=25",
            "-f","lavfi","-i","sine=frequency=440:sample_rate=48000","-t","0.4","-c:v","libx264","-pix_fmt","yuv420p","-c:a","aac",source.path]
        process.standardOutput = FileHandle.nullDevice; process.standardError = FileHandle.nullDevice
        try process.run(); process.waitUntilExit(); XCTAssertEqual(process.terminationStatus,0)
        let renderer = TVRenderer(executableSearchPath: "/usr/bin:/bin"),progress = CacheProgress()
        _ = try await renderer.loadVideo(source,cache: configuration) { progress.append($0) }
        let palValue = await renderer.normalizedVideoURL(standard: .pal)
        let ntscValue = await renderer.normalizedVideoURL(standard: .ntsc)
        let audioValue = await renderer.normalizedAudioURL()
        let pal = try XCTUnwrap(palValue),ntsc = try XCTUnwrap(ntscValue),audio = try XCTUnwrap(audioValue)
        await renderer.unloadVideo()
        for url in [pal,ntsc,audio] { XCTAssertTrue(FileManager.default.fileExists(atPath: url.path)) }
        let values = progress.values.compactMap(\.fraction)
        XCTAssertEqual(values.last,1); XCTAssertEqual(values,values.sorted())
        // Deliberately unusable executable: a cache hit must never launch it.
        let bin = root.appendingPathComponent("bin")
        try FileManager.default.createDirectory(at: bin,withIntermediateDirectories: true)
        let fake = bin.appendingPathComponent("ffmpeg")
        try Data("#!/bin/sh\nexit 99\n".utf8).write(to: fake)
        try FileManager.default.setAttributes([.posixPermissions:0o755],ofItemAtPath: fake.path)
        let hit = TVRenderer(executableSearchPath: bin.path),hitProgress = CacheProgress()
        _ = try await hit.loadVideo(source,standard: .ntsc,cache: configuration) { hitProgress.append($0) }
        XCTAssertTrue(hitProgress.values.contains { $0.stage == .cached })
        let reused = await hit.normalizedVideoURL(standard: .ntsc),hasAudio = await hit.hasAudioTrack()
        XCTAssertEqual(reused,ntsc); XCTAssertTrue(hasAudio)
        _ = try await hit.selectStandard(.pal)
        await hit.unloadVideo()
        try Data([0]).write(to: pal)
        let repaired = CacheProgress()
        _ = try await renderer.loadVideo(source,cache: configuration) { repaired.append($0) }
        XCTAssertFalse(repaired.values.contains { $0.stage == .cached })
        XCTAssertGreaterThan(try pal.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0,1)
        _ = try await renderer.render(time: 0)
        await renderer.unloadVideo()
        // Entries larger than the limit remain transient and are cleaned up.
        _ = try await renderer.loadVideo(source,cache: TVMediaCacheConfiguration(directory: configuration.directory,maximumBytes: 1))
        let scratchValue = await renderer.normalizedVideoURL(standard: .pal)
        let scratch = try XCTUnwrap(scratchValue)
        XCTAssertFalse(scratch.path.hasPrefix(configuration.directory.path))
        await renderer.unloadVideo()
        XCTAssertFalse(FileManager.default.fileExists(atPath: scratch.path))
    }
}
