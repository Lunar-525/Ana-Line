import XCTest
import AppKit
import AnalogCore
@testable import AnalogGUI
@testable import AnalogImaging

@MainActor
final class TVSessionTests: XCTestCase {
    private func folder() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("AnaLine-session-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url,withIntermediateDirectories: true)
        return url
    }
    private func document(video: URL? = nil,at url: URL,standard: TVStandard = .pal) -> TVSessionDocument {
        var channel = TerrestrialSettings(system: TerrestrialSystem(video: standard))
        channel.seed = UInt64.max
        channel.transmitter.enabled = true; channel.transmitter.powerDB = 3
        channel.transmitter.encoder.enabled = true; channel.transmitter.encoder.burstDriftDegrees = 13
        channel.transmitter.vsb.enabled = true; channel.transmitter.vsb.groupDelayNS = 110
        channel.propagation.antenna = .logPeriodic
        channel.propagation.ridgeEnabled = false
        channel.propagation.weather.enabled = true
        channel.propagation.weather.lightning = 0.8; channel.propagation.weather.lightningRatePerMinute = 17
        channel.receiverDamage.syncEnabled = true; channel.receiverDamage.horizontalJitterUS = 0.2
        channel.decoder.separation = .comb; channel.decoder.combFailure = 0.3
        return TVSessionDocument(video: video.map { .init(video: $0,session: url) },standard: standard,
            channel: channel,position: 0.72,muted: true,bypassedEchoGain: 0.65)
    }
    func testRoundTripPreservesBothStandardsAndNestedLinkSettings() throws {
        let root = try folder(); defer { try? FileManager.default.removeItem(at: root) }
        for standard in TVStandard.allCases {
            let url = root.appendingPathComponent("\(standard.rawValue).analine")
            let saved = document(video: root.appendingPathComponent("video.mp4"),at: url,standard: standard)
            try saved.write(to: url)
            XCTAssertEqual(try TVSessionDocument.read(from: url),saved)
            let json = try String(contentsOf: url,encoding: .utf8)
            XCTAssertTrue(json.contains("lightningRatePerMinute"))
            XCTAssertFalse(json.contains("AnaLine-TV-"),"Temporary transcoding outputs do not belong in a session")
        }
    }
    func testRelativeReferenceFollowsMovedFolderAndFallsBackToOriginal() throws {
        let root = try folder(); defer { try? FileManager.default.removeItem(at: root) }
        let original = root.appendingPathComponent("original")
        let media = original.appendingPathComponent("media")
        let sessions = original.appendingPathComponent("sessions")
        try FileManager.default.createDirectory(at: media,withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: sessions,withIntermediateDirectories: true)
        let source = media.appendingPathComponent("片 源.mp4")
        try Data([1,2,3]).write(to: source)
        let url = sessions.appendingPathComponent("scene.analine")
        let saved = document(video: source,at: url)
        try saved.write(to: url)
        XCTAssertEqual(saved.video?.relativePath,"../media/片 源.mp4")
        XCTAssertEqual(saved.video?.resolve(relativeTo: root.appendingPathComponent("elsewhere.analine")),source)
        let moved = root.appendingPathComponent("moved")
        try FileManager.default.moveItem(at: original,to: moved)
        let relocated = moved.appendingPathComponent("sessions/scene.analine")
        let decoded = try TVSessionDocument.read(from: relocated)
        XCTAssertEqual(decoded.video?.resolve(relativeTo: relocated),moved.appendingPathComponent("media/片 源.mp4"))
        try FileManager.default.removeItem(at: moved.appendingPathComponent("media/片 源.mp4"))
        XCTAssertNil(decoded.video?.resolve(relativeTo: relocated))
    }
    func testInvalidDocumentCannotOverwriteValidSavedFile() throws {
        let root = try folder(); defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("scene.analine"),good = document(at: root)
        try good.write(to: url)
        var invalid = good; invalid.channel.propagation.weather.lightningRatePerMinute = 121
        XCTAssertThrowsError(try invalid.write(to: url))
        XCTAssertEqual(try TVSessionDocument.read(from: url),good)
        invalid = good; invalid.position = .infinity
        XCTAssertThrowsError(try invalid.validate())
        invalid = good; invalid.version = 2
        try JSONEncoder().encode(invalid).write(to: url)
        XCTAssertThrowsError(try TVSessionDocument.read(from: url))
        try Data("{ broken JSON".utf8).write(to: url)
        XCTAssertThrowsError(try TVSessionDocument.read(from: url))
    }
    func testNoVideoRestoresPausedConfigurationAndBypassedReflection() async throws {
        let model = PreviewModel(); model.started = true; model.tvControlState.bind(model)
        let url = URL(fileURLWithPath: "/tmp/scene.analine")
        let saved = document(at: url,standard: .ntsc)
        try await model.restoreSession(saved,at: url,video: nil)
        XCTAssertEqual(model.tool,.tv); XCTAssertEqual(model.tvStandard,.ntsc)
        XCTAssertEqual(model.tvChannel,saved.channel)
        XCTAssertEqual(model.tvTime,0); XCTAssertEqual(model.tvDuration,0)
        XCTAssertFalse(model.tvPlaying); XCTAssertFalse(model.tvHasAudio); XCTAssertTrue(model.tvMuted)
        XCTAssertEqual(model.sessionURL,url)
        XCTAssertEqual(model.tvControlState.sceneEchoGain,0.65)
        model.tvControlState.setPropagationEnabled(true)
        XCTAssertEqual(model.tvChannel.echoGain,0.65)
    }
    func testMissingVideoAndFailedSaveLeaveCurrentSessionIntact() async throws {
        let root = try folder(); defer { try? FileManager.default.removeItem(at: root) }
        let model = PreviewModel(); model.started = true
        let current = root.appendingPathComponent("current.analine")
        try await model.restoreSession(document(at: current),at: current,video: nil)
        let before = model.sessionSnapshot(at: current)
        let missing = document(video: root.appendingPathComponent("missing.mp4"),at: current,standard: .ntsc)
        do { try await model.restoreSession(missing,at: current,video: nil); XCTFail("Missing media must be resolved first") }
        catch {}
        XCTAssertEqual(model.sessionSnapshot(at: current),before)
        XCTAssertThrowsError(try model.writeSession(to: root.appendingPathComponent("missing/scene.analine")))
        XCTAssertEqual(model.sessionURL,current)
        model.busy = true
        XCTAssertThrowsError(try model.writeSession(to: current))
        model.busy = false
    }
    func testVideoSessionRebuildsDualCachesAndRestoresFrameAndAudioPaused() async throws {
        let root = try folder(); defer { try? FileManager.default.removeItem(at: root) }
        let executable = try XCTUnwrap(TVExecutableResolver.find("ffmpeg",path: "/usr/bin:/bin"))
        let source = root.appendingPathComponent("video.mp4")
        let process = Process(); process.executableURL = executable
        process.arguments = ["-hide_banner","-loglevel","error","-y","-f","lavfi","-i",
            "testsrc2=size=160x120:rate=25","-f","lavfi","-i","sine=frequency=440:sample_rate=48000",
            "-t","1.2","-c:v","libx264","-pix_fmt","yuv420p","-c:a","aac",source.path]
        process.standardOutput = FileHandle.nullDevice; process.standardError = FileHandle.nullDevice
        try process.run(); process.waitUntilExit(); XCTAssertEqual(process.terminationStatus,0)
        for standard in TVStandard.allCases {
            let url = root.appendingPathComponent("\(standard.rawValue).analine")
            let original = PreviewModel(); original.started = true; original.tvControlState.bind(original)
            let fixture = document(video: source,at: url,standard: standard)
            try await original.restoreSession(fixture,at: url,video: source)
            try await ready(original)
            try original.writeSession(to: url)
            let saved = try TVSessionDocument.read(from: url)
            XCTAssertEqual(saved.video?.path,source.path)
            let reopened = PreviewModel(); reopened.started = true; reopened.tvControlState.bind(reopened)
            try await reopened.restoreSession(saved,at: url,video: saved.video?.resolve(relativeTo: url))
            try await ready(reopened)
            XCTAssertEqual(reopened.tvChannel,saved.channel)
            XCTAssertEqual(reopened.tvStandard,standard)
            XCTAssertEqual(reopened.tvTime,saved.position,accuracy: 1e-6)
            XCTAssertFalse(reopened.tvPlaying); XCTAssertTrue(reopened.tvHasAudio); XCTAssertTrue(reopened.tvMuted)
            XCTAssertNotNil(reopened.tvOriginal); XCTAssertNotNil(reopened.processed)
            // Both standards must already be usable without another FFmpeg prepare.
            reopened.tvStandard = standard == .pal ? .ntsc : .pal
            XCTAssertFalse(reopened.tvPreparing)
            try await ready(reopened)
            XCTAssertGreaterThan(reopened.tvDuration,1)
            XCTAssertFalse(reopened.tvPreparing)
            var beyondEnd = saved; beyondEnd.position = 1e30
            try await reopened.restoreSession(beyondEnd,at: url,video: source)
            try await ready(reopened)
            XCTAssertGreaterThanOrEqual(reopened.tvTime,0)
            XCTAssertLessThan(reopened.tvTime,reopened.tvDuration)
            // Failed FFmpeg preparation must preserve the working video and parameters.
            let bad = root.appendingPathComponent("corrupt.mp4")
            try Data("not a video".utf8).write(to: bad)
            let before = reopened.sessionSnapshot(at: url)
            do { try await reopened.restoreSession(fixture,at: url,video: bad); XCTFail("Corrupt media must fail") }
            catch {}
            XCTAssertEqual(reopened.sessionSnapshot(at: url),before)
            reopened.seekTV(to: 0); try await ready(reopened)
            XCTAssertFalse(reopened.status.contains("failed"),reopened.status)
        }
    }
    private func ready(_ model: PreviewModel) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(30))
        while model.busy || model.rendering {
            guard ContinuousClock.now < deadline else { throw CocoaError(.userCancelled) }
            try await Task.sleep(for: .milliseconds(10))
        }
    }
}
