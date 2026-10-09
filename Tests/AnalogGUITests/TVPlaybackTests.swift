import XCTest
import AnalogCore
@testable import AnalogGUI
@testable import AnalogImaging

@MainActor
final class TVPlaybackTests: XCTestCase {
    func testPlayPauseSeekScrubEndAndModeSwitch() async throws {
        let path = ProcessInfo.processInfo.environment["PATH", default: "/usr/bin:/bin"]
        guard TVExecutableResolver.find("ffmpeg", path: path) != nil else { throw XCTSkip("FFmpeg is required") }
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let model = PreviewModel()
        model.load(root.appendingPathComponent("Assets/rickroll.mp4"))
        try await waitUntil { !model.busy && !model.rendering }
        XCTAssertEqual(model.tool, .tv)
        XCTAssertGreaterThan(model.tvDuration, 200, model.status)

        model.seekTV(to: 10)
        try await waitUntil { !model.rendering }
        XCTAssertEqual(model.tvTime, 10, accuracy: model.tvStandard.frameDuration)
        XCTAssertEqual(model.tvLock, .locked, model.status)
        model.toggleTVPlayback()
        XCTAssertTrue(model.tvPlaying)
        try await waitUntil { model.tvTime > 10.15 }
        model.pauseTVPlayback()
        let pausedTime = model.tvTime
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertFalse(model.tvPlaying)
        XCTAssertEqual(model.tvTime, pausedTime)

        // Signal loss must remain a live receiver state, rather than stop playback.
        model.tvChannel.signalDB = -60
        model.tvChannel.carrierToNoiseDB = 5
        try await waitUntil { !model.rendering }
        XCTAssertNotEqual(model.tvLock, .locked)
        XCTAssertNotNil(model.processed)
        model.toggleTVPlayback()
        let lostTime = model.tvTime
        try await waitUntil { model.tvTime > lostTime + 0.1 }
        XCTAssertTrue(model.tvPlaying)
        model.tvChannel = TerrestrialSettings(system: model.terrestrialSystem)
        try await waitUntil { model.tvLock == .locked }
        XCTAssertTrue(model.tvPlaying)
        model.pauseTVPlayback()

        model.beginTVScrubbing()
        model.seekTV(to: 20)
        model.endTVScrubbing()
        try await waitUntil { !model.rendering }
        XCTAssertFalse(model.tvPlaying, "Scrubbing a paused video should leave it paused")
        XCTAssertEqual(model.tvTime, 20, accuracy: model.tvStandard.frameDuration)

        model.toggleTVPlayback()
        try await waitUntil { model.tvTime > 20.1 }
        model.beginTVScrubbing()
        XCTAssertFalse(model.tvPlaying)
        model.seekTV(to: 30)
        model.endTVScrubbing()
        XCTAssertTrue(model.tvPlaying)
        try await waitUntil { model.tvTime > 30.1 }

        model.tool = .film
        XCTAssertFalse(model.tvPlaying)
        let switchedTime = model.tvTime
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertEqual(model.tvTime, switchedTime)

        model.tool = .tv
        model.seekTV(to: model.tvDuration - 2 * model.tvStandard.frameDuration)
        try await waitUntil { !model.rendering }
        model.toggleTVPlayback()
        try await waitUntil { !model.tvPlaying }
        XCTAssertEqual(model.tvTime, model.tvDuration)
        model.toggleTVPlayback()
        XCTAssertTrue(model.tvPlaying)
        XCTAssertLessThan(model.tvTime, 1, "Play at the end should restart from the beginning")
        model.pauseTVPlayback()

        // Loading a still image releases the video's intermediate files and decoder.
        model.tool = .film
        model.load(root.appendingPathComponent("Assets/bliss.jpg"))
        try await waitUntil { !model.busy && !model.rendering }
        XCTAssertEqual(model.tvDuration, 0)
    }

    private func waitUntil(_ predicate: () -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(20))
        while !predicate() {
            if ContinuousClock.now >= deadline {
                XCTFail("Video playback did not reach the expected state")
                throw CocoaError(.coderInvalidValue)
            }
            try await Task.sleep(for: .milliseconds(20))
        }
    }
}
