import XCTest
import Combine
import AnalogCore
import Darwin
import SwiftUI
import AppKit
@testable import AnalogGUI
@testable import AnalogImaging

@MainActor
final class TVPlaybackTests: XCTestCase {
    func testM3MaxMaintainsNormalSpeedAndContinuousAudioForBothStandards() async throws {
        try await verifyRealtime(scene: false)
    }

    func testM3MaxMaintainsRealtimeWithPropagationWeatherAndPA() async throws {
        try await verifyRealtime(scene: true)
    }

    func testM3MaxRealtimeWithVisibleWindow() async throws {
        guard ProcessInfo.processInfo.environment["ANALINE_WINDOW_BENCHMARK"] == "1" else {
            throw XCTSkip("Opt-in: opens an independent native playback benchmark window")
        }
        try await verifyRealtime(scene: true,visibleWindow: true)
    }

    func testM3MaxPresentationSurvivesProducerStalls() async throws {
        try await verifyRealtime(scene: true,injectStalls: true)
    }

    private func verifyRealtime(scene: Bool, visibleWindow: Bool = false, injectStalls: Bool = false) async throws {
        var length = 0
        guard sysctlbyname("machdep.cpu.brand_string",nil,&length,nil,0) == 0 else {
            throw XCTSkip("Hardware identification is unavailable")
        }
        var name = [CChar](repeating: 0,count: length)
        let status = name.withUnsafeMutableBufferPointer { sysctlbyname("machdep.cpu.brand_string",$0.baseAddress,&length,nil,0) }
        guard status == 0, String(cString: name).contains("M3 Max") else {
            throw XCTSkip("This real-time acceptance check targets M3 Max")
        }
        let path = ProcessInfo.processInfo.environment["PATH",default: "/usr/bin:/bin"]
        guard TVExecutableResolver.find("ffmpeg",path: path) != nil else { throw XCTSkip("FFmpeg is required") }
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let model = PreviewModel(); model.tvMuted = true
        defer { model.pauseTVPlayback() }
        var window: NSWindow?
        if visibleWindow {
            _ = NSApplication.shared
            model.started = true // The harness supplies its video, not the startup image.
            let w = NSWindow(contentRect: NSRect(x: 60,y: 60,width: 1200,height: 1000),
                styleMask: [.titled,.closable,.resizable],backing: .buffered,defer: false)
            w.isReleasedWhenClosed = false
            w.title = "AnaLine · Playback performance verification"
            w.contentView = NSHostingView(rootView: ContentView(languageStore: LanguageStore(),model: model))
            w.orderFront(nil)
            window = w
        }
        defer { window?.orderOut(nil); window?.contentView = nil; window?.close() }
        if scene {
            model.tvChannel.propagation.distanceKm = 12
            model.tvChannel.propagation.ridgeEnabled = true; model.tvChannel.propagation.ridgeHeightM = 35
            model.tvChannel.propagation.groundReflection = 0.1
            model.tvChannel.propagation.weather.enabled = true
            model.tvChannel.propagation.weather.rainMMHour = 25
            model.tvChannel.propagation.weather.snowMMHour = 3; model.tvChannel.propagation.weather.fogGramsM3 = 0.1
            model.tvChannel.propagation.weather.humidityPercent = 70; model.tvChannel.propagation.weather.temperatureC = 25
            model.tvChannel.propagation.weather.sunlight = 0.7; model.tvChannel.propagation.weather.lightning = 0.5
            model.tvChannel.propagation.weather.ionization = 0.2
            model.tvChannel.transmitter.enabled = true; model.tvChannel.transmitter.phaseDegrees = 5
            model.tvChannel.transmitter.powerDB = 3 // Include the non-default RF drive scaling path.
            model.tvChannel.transmitter.sharedCoupling = 0.4; model.tvChannel.transmitter.audioDriveDB = 6
            model.tvChannel.transmitter.encoder.enabled = true
            model.tvChannel.transmitter.encoder.differentialGain = 0.2
            model.tvChannel.transmitter.encoder.differentialPhaseDegrees = 15
            model.tvChannel.transmitter.encoder.burstDriftDegrees = 10
            model.tvChannel.transmitter.vsb.enabled = true
            model.tvChannel.transmitter.vsb.groupDelayNS = 100; model.tvChannel.transmitter.vsb.peakingDB = 2
            model.tvChannel.receiverDamage.agcEnabled = true
            model.tvChannel.receiverDamage.agcOvershoot = 0.3; model.tvChannel.receiverDamage.agcPictureSensitivity = 0.2
            model.tvChannel.receiverDamage.syncEnabled = true
            model.tvChannel.receiverDamage.horizontalJitterUS = 0.3
            model.tvChannel.receiverDamage.horizontalOscillatorPPM = 30
            model.tvChannel.receiverDamage.verticalHoldHz = 0.05
            model.tvChannel.decoder.separation = .comb
            model.tvChannel.decoder.combFailure = 0.3; model.tvChannel.decoder.chromaLeakage = 0.1
        }
        if injectStalls {
            // Several deliberately late RF frames while all features are enabled.
            // This used to freeze presentation despite a healthy audio FIFO.
            model.tvPlaybackRenderHook = { frame in
                if frame % 60 == 0 { try await Task.sleep(for: .milliseconds(120)) }
            }
        }
        model.load(root.appendingPathComponent("Assets/rickroll.mp4"))
        try await waitUntil { !model.busy && !model.rendering }
        XCTAssertGreaterThan(model.tvDuration,0,model.status)
        guard model.tvDuration > 0 else { throw CocoaError(.fileReadCorruptFile) }
        var report = [[String:Any]]()
        let requested = ProcessInfo.processInfo.environment["ANALINE_BENCHMARK_SECONDS"].flatMap(Double.init)
        let seconds = requested ?? (visibleWindow ? 30 : injectStalls ? 10 : 5)
        for standard in TVStandard.allCases {
            model.tvStandard = standard
            try await waitUntil { !model.busy && !model.rendering }
            XCTAssertFalse(model.status.contains("failed"),model.status)
            model.seekTV(to: 10)
            try await waitUntil { !model.rendering }
            model.toggleTVPlayback()
            try await waitUntil { model.tvTime > 10.5 }
            let start = ContinuousClock.now, media = model.tvAudioMediaSeconds
            let underruns = model.tvAudioUnderrunSamples
            try await Task.sleep(for: .seconds(seconds))
            let elapsed = start.duration(to: .now).components
            let wall = Double(elapsed.seconds)+Double(elapsed.attoseconds)/1e18
            let speed = (model.tvAudioMediaSeconds-media)/wall
            let missing = model.tvAudioUnderrunSamples-underruns
            if visibleWindow {
                XCTAssertTrue(window?.isVisible == true)
                XCTAssertEqual(model.tvTime-10,model.tvAudioMediaSeconds,accuracy: 0.12,
                    "The displayed frame must continue to follow PCM with the native view attached")
            }
            XCTAssertTrue(model.tvPlaying,model.status)
            XCTAssertGreaterThanOrEqual(model.tvPlaybackRate,0.99)
            XCTAssertEqual(speed,1,accuracy: 0.03,"Playback must advance media time at real-time speed")
            XCTAssertEqual(missing,0,"There must be no PCM underruns during steady playback")
            let tails = model.tvPlaybackMetrics
            if !injectStalls {
                XCTAssertLessThanOrEqual(tails.maximumProductionSeconds,standard.frameDuration,
                    "Worst steady production frame must fit its own frame budget")
            }
            XCTAssertEqual(tails.skippedFrames,0,"Every RF frame must reach presentation, including during producer stalls")
            XCTAssertLessThanOrEqual(tails.maximumPresentationGap,standard.frameDuration*1.5,
                "One late frame must not block the independent presenter")
            XCTAssertLessThanOrEqual(tails.maximumPresentationLateness,standard.frameDuration*0.5,
                "Display lateness must stay below half a frame, not merely average out")
            if injectStalls { XCTAssertGreaterThan(tails.maximumProductionSeconds,0.12) }
            let row: [String:Any] = ["system":TerrestrialSystem(video: standard).rawValue,"wall_seconds":wall,
                "requested_seconds":seconds,
                "media_speed":speed,"playback_rate":model.tvPlaybackRate,"underrun_samples":missing,
                "visible_window":visibleWindow,"injected_stalls":injectStalls,
                "produced_frames":tails.producedFrames,"presented_frames":tails.presentedFrames,
                "mean_production_ms":tails.meanProductionSeconds*1000,
                "maximum_production_ms":tails.maximumProductionSeconds*1000,
                "maximum_render_ms":tails.maximumRenderSeconds*1000,
                "maximum_delivery_overhead_ms":tails.maximumDeliveryOverheadSeconds*1000,
                "worst_frame_source_encode_rf_image_ms":tails.worstFrameStages.map { $0*1000 },
                "worst_frame_vsb_pa_channel_tuner_carrier_sync_decode_sound_ms":tails.worstRFStages.map { $0*1000 },
                "production_deadline_misses":tails.productionDeadlineMisses,
                "maximum_presentation_gap_ms":tails.maximumPresentationGap*1000,
                "maximum_presentation_lateness_ms":tails.maximumPresentationLateness*1000,
                "skipped_frames":tails.skippedFrames]
            report.append(row); print("M3 Max playback",scene ? "scene + weather + PA" : "default",row)
            model.pauseTVPlayback()
            XCTAssertEqual(model.tvOriginal?.size.width,CGFloat(standard.squarePixelWidth))
            XCTAssertEqual(model.tvOriginal?.size.height,CGFloat(standard.height))
            if visibleWindow, ProcessInfo.processInfo.environment["ANALINE_CAPTURE_UI"] == "1",
               let view = window?.contentView, let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) {
                view.cacheDisplay(in: view.bounds,to: bitmap)
                let png = try XCTUnwrap(bitmap.representation(using: .png,properties: [:]))
                try png.write(to: root.appendingPathComponent("build/TV-workspace-\(standard.rawValue).png"))
                if standard == .ntsc, let window {
                    // Inspect the lower panels in the same owned test window after
                    // all playback measurements; no capture work affects timings.
                    window.contentView = NSHostingView(rootView:
                        VStack(spacing: 16) {
                            TVPropagationView(model: model)
                            TVReceiverControls(model: model)
                        }.padding(20).frame(width: 1200).background(Color.black))
                    window.setContentSize(NSSize(width: 1200,height: 1400))
                    try await Task.sleep(for: .milliseconds(200))
                    if let panel = window.contentView, let image = panel.bitmapImageRepForCachingDisplay(in: panel.bounds) {
                        panel.cacheDisplay(in: panel.bounds,to: image)
                        let data = try XCTUnwrap(image.representation(using: .png,properties: [:]))
                        try data.write(to: root.appendingPathComponent("build/TV-propagation-receiver.png"))
                    }
                }
            }
        }
        let base = injectStalls ? "Terrestrial-stalled-producer-playback" : visibleWindow ? "Terrestrial-visible-window-playback" : scene ? "Terrestrial-scene-M3Max-playback" : "Terrestrial-M3Max-playback"
        let durationSuffix = requested == nil ? "" : "-\(Int(seconds))s"
        try JSONSerialization.data(withJSONObject: report,options: [.prettyPrinted,.sortedKeys])
            .write(to: URL(fileURLWithPath: "/private/tmp/\(base)\(durationSuffix).json"))
    }

    func testStandardSwitchUsesImportCachesAndPreservesPlayhead() async throws {
        let path = ProcessInfo.processInfo.environment["PATH",default: "/usr/bin:/bin"]
        guard TVExecutableResolver.find("ffmpeg",path: path) != nil else { throw XCTSkip("FFmpeg is required") }
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let model = PreviewModel(); model.tvMuted = true
        defer { model.pauseTVPlayback() }
        model.load(root.appendingPathComponent("Assets/rickroll.mp4"))
        try await waitUntil { !model.busy && !model.rendering }
        XCTAssertGreaterThan(model.tvDuration,200,model.status)
        model.seekTV(to: 10)
        try await waitUntil { !model.rendering }
        var preparedAgain = false
        let subscription = model.$tvPreparing.sink { if $0 { preparedAgain = true } }
        for standard in [TVStandard.ntsc,.pal,.ntsc] {
            let start = ContinuousClock.now
            model.tvStandard = standard
            try await waitUntil { !model.busy && !model.rendering }
            XCTAssertFalse(preparedAgain,"Changing standards must never invoke import/transcode progress")
            XCTAssertEqual(model.tvTime,10,accuracy: standard.frameDuration)
            XCTAssertEqual(model.processed?.size.height,CGFloat(standard.height))
            XCTAssertTrue(model.tvHasAudio)
            XCTAssertEqual(model.tvLock,.locked,model.status)
            print("Cached standard switch including preview:",standard,start.duration(to: .now))
        }
        // Superseded requests must not leave the workspace busy or use the
        // cache of a different standard than the selector's final value.
        model.tvStandard = .pal; model.tvStandard = .ntsc; model.tvStandard = .pal
        try await waitUntil { !model.busy && !model.rendering }
        XCTAssertEqual(model.processed?.size.height,576)
        XCTAssertFalse(preparedAgain)
        withExtendedLifetime(subscription) {}
    }

    func testBufferedLightningFollowsDisplayedVideoAndFreezesOnPause() async throws {
        let path = ProcessInfo.processInfo.environment["PATH",default: "/usr/bin:/bin"]
        guard TVExecutableResolver.find("ffmpeg",path: path) != nil else { throw XCTSkip("FFmpeg is required") }
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let model = PreviewModel(); model.tvMuted = true
        defer { model.pauseTVPlayback() }
        model.tvChannel.propagation.weather.enabled = true
        model.tvChannel.propagation.weather.lightning = 1
        model.tvChannel.propagation.weather.lightningRatePerMinute = 120
        let event = try XCTUnwrap(TVLightningTimeline.events(time: 10,duration: 4,
            seed: model.tvChannel.seed,settings: model.tvChannel.propagation).first)
        model.load(root.appendingPathComponent("Assets/rickroll.mp4"))
        try await waitUntil { !model.busy && !model.rendering }
        XCTAssertGreaterThan(model.tvDuration,200,model.status)
        let frameTime = floor(event.time/model.tvStandard.frameDuration)*model.tvStandard.frameDuration
        model.seekTV(to: frameTime-0.08)
        try await waitUntil { !model.rendering }
        XCTAssertNil(model.tvLightningState.flash)
        var strikes = 0
        let observer = model.tvLightningState.$flash.sink { flash in
            guard let flash, flash.age == 0 else { return }
            strikes += 1
            XCTAssertGreaterThanOrEqual(flash.event.time+TVLightningEvent.pulseDuration,model.tvTime)
            XCTAssertLessThan(flash.event.time,model.tvTime+model.tvStandard.frameDuration,
                "A producer working eight frames ahead must not trigger the visible bolt")
        }
        model.toggleTVPlayback()
        try await waitUntil { model.tvTime > frameTime+0.4 }
        model.pauseTVPlayback()
        XCTAssertGreaterThan(strikes,0)
        // Another strike can occur during the first event's afterglow; inspect
        // the explicitly selected event below rather than assuming clear sky.
        model.seekTV(to: frameTime)
        try await waitUntil { !model.rendering }
        let frozen = try XCTUnwrap(model.tvLightningState.flash)
        XCTAssertEqual(frozen.event,event)
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertEqual(model.tvLightningState.flash,frozen,"Wall time cannot advance a paused strike")
        model.seekTV(to: frameTime-0.08)
        XCTAssertNil(model.tvLightningState.flash,"Seek clears the old flash before rendering completes")
        try await waitUntil { !model.rendering }
        XCTAssertNil(model.tvLightningState.flash)
        withExtendedLifetime(observer) {}
    }

    func testPlayPauseSeekScrubEndAndModeSwitch() async throws {
        let path = ProcessInfo.processInfo.environment["PATH", default: "/usr/bin:/bin"]
        guard TVExecutableResolver.find("ffmpeg", path: path) != nil else { throw XCTSkip("FFmpeg is required") }
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let model = PreviewModel()
        model.tvMuted = true // Exercise the native output clock without sounding during tests.
        model.load(root.appendingPathComponent("Assets/rickroll.mp4"))
        try await waitUntil { !model.busy && !model.rendering }
        XCTAssertEqual(model.tool, .tv)
        XCTAssertGreaterThan(model.tvDuration, 200, model.status)
        XCTAssertTrue(model.tvHasAudio)
        XCTAssertFalse(model.tvPreparing)

        model.seekTV(to: 10)
        try await waitUntil { !model.rendering }
        XCTAssertEqual(model.tvTime, 10, accuracy: model.tvStandard.frameDuration)
        XCTAssertEqual(model.tvLock, .locked, model.status)
        model.toggleTVPlayback()
        XCTAssertTrue(model.tvPlaying)
        try await waitUntil { model.tvTime > 10.5 }
        XCTAssertGreaterThan(model.tvAudioConsumedSamples,24_000)
        XCTAssertEqual(model.tvPlaybackMetrics.worstFrameStages.count,4)
        XCTAssertGreaterThan(model.tvPlaybackMetrics.maximumProductionSeconds,0)
        XCTAssertGreaterThan(model.tvPlaybackMetrics.maximumRenderSeconds,0)
        XCTAssertEqual(model.tvTime-10,model.tvAudioMediaSeconds,accuracy: 0.1,
            "The displayed frame must follow the PCM output clock")
        model.pauseTVPlayback()
        XCTAssertEqual(model.tvAudioConsumedSamples,0,"Pause must discard queued audio")
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
