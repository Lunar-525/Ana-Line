import XCTest
import SwiftUI
import AppKit
import AnalogCore
@testable import AnalogGUI
@testable import AnalogImaging

@MainActor
final class TVBufferSettingsTests: XCTestCase {
    func testPreferencesPersistAndRejectInvalidStoredLimits() throws {
        let name = "AnaLine-test-\(UUID().uuidString)",defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let settings = TVPreferences(defaults: defaults)
        settings.cachePath = FileManager.default.temporaryDirectory.appendingPathComponent(name).path
        settings.bufferFrames = 3; settings.cacheLimitGB = 1.5
        let restored = TVPreferences(defaults: defaults)
        XCTAssertEqual(restored.bufferFrames,3); XCTAssertEqual(restored.cacheLimitGB,1.5)
        XCTAssertEqual(restored.configuration.maximumBytes,1_610_612_736)
        XCTAssertEqual(restored.cachePath,settings.cachePath)
        defaults.set(-10,forKey: "tvBufferFrames"); defaults.set(-5.0,forKey: "tvCacheLimitGB")
        let invalid = TVPreferences(defaults: defaults)
        XCTAssertEqual(invalid.bufferFrames,1); XCTAssertEqual(invalid.configuration.maximumBytes,0)
    }
    func testSmallBufferDropsFramesButKeepsRealtimeClockForBothStandards() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("AnaLine-buffer-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root,withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let name = root.lastPathComponent,defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let preferences = TVPreferences(defaults: defaults)
        preferences.cachePath = root.appendingPathComponent("cache").path
        preferences.cacheLimitGB = 1; preferences.bufferFrames = 1
        let source = root.appendingPathComponent("source.mp4")
        let process = Process(); process.executableURL = try XCTUnwrap(TVExecutableResolver.find("ffmpeg",path: "/usr/bin:/bin"))
        process.arguments = ["-hide_banner","-loglevel","error","-y","-f","lavfi","-i","testsrc2=size=160x120:rate=25",
            "-f","lavfi","-i","sine=frequency=440:sample_rate=48000","-t","8","-c:v","libx264","-pix_fmt","yuv420p","-c:a","aac",source.path]
        process.standardOutput = FileHandle.nullDevice; process.standardError = FileHandle.nullDevice
        try process.run(); process.waitUntilExit(); XCTAssertEqual(process.terminationStatus,0)
        let model = PreviewModel(tvPreferences: preferences); model.started = true; model.tvMuted = true
        defer { model.pauseTVPlayback() }
        model.load(source)
        try await wait { !model.busy && !model.rendering }
        XCTAssertGreaterThan(model.tvDuration,7,model.status)
        for standard in TVStandard.allCases {
            model.tvStandard = standard
            try await wait { !model.busy && !model.rendering }
            model.seekTV(to: 0); try await wait { !model.rendering }
            model.tvPlaybackRenderHook = { _ in try await Task.sleep(for: .milliseconds(80)) }
            model.toggleTVPlayback()
            try await wait { model.tvAudioMediaSeconds > 0.2 }
            let clock = ContinuousClock.now,media = model.tvAudioMediaSeconds
            try await Task.sleep(for: .seconds(2))
            let wall = TVPlaybackMetrics.seconds(clock.duration(to: .now))
            let speed = (model.tvAudioMediaSeconds-media)/wall
            XCTAssertTrue(model.tvPlaying,model.status)
            XCTAssertEqual(model.tvPlaybackRate,1)
            XCTAssertEqual(speed,1,accuracy: 0.04)
            XCTAssertGreaterThan(model.tvPlaybackMetrics.skippedFrames,0)
            XCTAssertGreaterThan(model.tvPreviewState.droppedFrames,0)
            XCTAssertEqual(model.tvPreviewState.droppedFrames,model.tvPlaybackMetrics.skippedFrames)
            XCTAssertGreaterThan(model.tvTime,1.5)
            XCTAssertGreaterThan(model.tvPlaybackMetrics.presentedFrames,5,"Overload must still show useful frames, not drop every result")
            print("Fixed-clock small buffer",standard.rawValue,"speed",speed,"drops",model.tvPlaybackMetrics.skippedFrames)
            model.pauseTVPlayback()
        }
    }
    func testDroppedFramesCountOnceIncludingFirstFrameAfterSeek() {
        var metrics = TVPlaybackMetrics(firstFrame: 100)
        metrics.dropped(through: 102); metrics.dropped(through: 102)
        metrics.presented(frame: 104,lateness: 0)
        XCTAssertEqual(metrics.skippedFrames,4)
        metrics.dropped(through: 103)
        XCTAssertEqual(metrics.skippedFrames,4)
        metrics.presented(frame: 105,lateness: 0)
        XCTAssertEqual(metrics.skippedFrames,4)
    }
    func testSettingsAndProgressFitNativePanels() async throws {
        guard ProcessInfo.processInfo.environment["ANALINE_CAPTURE_CACHE_UI"] == "1" else { return }
        _ = NSApplication.shared
        let settings = NSHostingView(rootView: AnaLineSettingsView(languageStore: LanguageStore()))
        settings.frame = NSRect(x: 0,y: 0,width: 480,height: 440)
        let model = PreviewModel()
        let progress = NSHostingView(rootView: TVPreparationBar(model: model))
        progress.frame = NSRect(x: 0,y: 0,width: 800,height: 44)
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        for (name,view) in [("settings",settings as NSView),("progress",progress as NSView)] {
            let window = NSWindow(contentRect: view.frame,styleMask: [.titled],backing: .buffered,defer: false)
            window.isReleasedWhenClosed = false; window.contentView = view; window.orderFront(nil)
            try await Task.sleep(for: .milliseconds(250))
            let bitmap = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
            view.cacheDisplay(in: view.bounds,to: bitmap)
            try XCTUnwrap(bitmap.representation(using: .png,properties: [:])).write(to: root.appendingPathComponent("build/TV-cache-\(name).png"))
            window.orderOut(nil); window.contentView = nil; window.close()
        }
    }
    private func wait(_ predicate: () -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(30))
        while !predicate() {
            guard ContinuousClock.now < deadline else { throw CocoaError(.userCancelled) }
            try await Task.sleep(for: .milliseconds(10))
        }
    }
}
