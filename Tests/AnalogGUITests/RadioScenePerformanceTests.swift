import XCTest
import SwiftUI
import AppKit
@testable import AnalogCore
@testable import AnalogGUI

/// Guards the interactive cost of the Radio page. The page used to publish the
/// scene clock on every 5 ms poll of the playback loop, which repainted the
/// transport (and its native knobs) up to 100 times a second, and it handed the
/// whole decoded-audio dictionary to the DSP actor every 21 ms block.
final class RadioScenePerformanceTests: XCTestCase {
    @MainActor private func hosted(_ model: RadioSceneModel,size: NSSize) -> (NSHostingView<AnyView>,NSWindow) {
        let view = AnyView(RadioSceneView(model: model).frame(width: size.width,height: size.height)
            .environment(\.colorScheme,.dark).background(Color(white: 0.15)))
        let host = NSHostingView(rootView: view)
        let window = NSWindow(contentRect: NSRect(x: -10000,y: -10000,width: size.width,height: size.height),
            styleMask: [.borderless],backing: .buffered,defer: false)
        window.isReleasedWhenClosed = false; window.appearance = NSAppearance(named: .darkAqua)
        window.contentView = host; host.frame = NSRect(origin: .zero,size: size)
        host.layoutSubtreeIfNeeded()
        return (host,window)
    }
    @MainActor private func apply(_ model: RadioSceneModel,_ result: (frame: RadioSceneFrame, seconds: Double)) {
        model.clock.seconds = Double(result.frame.firstAudioSample)/48_000
        model.clock.processingMS = result.seconds*1000
        for (id,spectrum) in result.frame.transmitSpectra { model.txDisplay(id).apply(spectrum); model.txDisplay(id).publish() }
        for (id,reception) in result.frame.receptions { model.rxDisplay(id).apply(reception,time: model.clock.seconds); model.rxDisplay(id).publish() }
    }
    private func source(_ seconds: Double,seed: UInt64 = 7) -> [Float] {
        var state = seed
        return (0..<Int(seconds*48_000)).map { n in
            state = state &* 6364136223846793005 &+ 1
            let noise = Float(state >> 40)/Float(1 << 24)*2-1
            return 0.3*Float(sin(2 * Double.pi*997*Double(n)/48_000))+0.2*noise
        }
    }
    /// One measurement repaints eight transmitter spectra, two receiver
    /// waterfalls and the environment panel. It must stay well inside a frame.
    @MainActor func testFullWidthMeasurementRepaintBudget() async throws {
        #if DEBUG
        throw XCTSkip("Measure the production renderer with -c release")
        #else
        let model = RadioSceneModel()
        XCTAssertEqual(model.settings.transmitters.count,RadioSceneSettings.transmitterSlots)
        let processor = RadioSceneProcessor(startSample: 0)
        for _ in 0..<8 { apply(model,try await processor.process(settings: model.settings,clips: [:])) }
        let (host,window) = hosted(model,size: NSSize(width: 1200,height: 920))
        defer { window.close() }
        try await Task.sleep(for: .milliseconds(80))
        host.layoutSubtreeIfNeeded(); host.displayIfNeeded()
        var total = 0.0
        for _ in 0..<24 {
            let result = try await processor.process(settings: model.settings,clips: [:])
            let start = ContinuousClock.now
            apply(model,result)
            host.layoutSubtreeIfNeeded(); host.displayIfNeeded()
            let d = start.duration(to: .now).components
            total += Double(d.seconds)+Double(d.attoseconds)/1e18
        }
        let mean = total/24*1000
        print("RADIO_SCENE_REPAINT 8 TX / 2 RX full repaint: \(mean) ms")
        XCTAssertLessThan(mean,12,"A 8 TX / 2 RX repaint must leave room inside a 16.7 ms frame")
        #endif
    }
    /// The clock must be published a few times a second, never once per poll.
    @MainActor func testClockPublishingStaysCoarse() async throws {
        let model = RadioSceneModel(); model.muted = true
        defer { model.pause() }
        model.play()
        guard model.clock.playing else { throw XCTSkip("No audio output: \(model.clock.status)") }
        try await Task.sleep(for: .milliseconds(300))
        try await Task.sleep(for: .milliseconds(1500))
        var updates = 0, last = model.clock.seconds
        let start = ContinuousClock.now
        while true {
            try await Task.sleep(for: .milliseconds(4))
            if model.clock.seconds != last { updates += 1; last = model.clock.seconds }
            let d = start.duration(to: .now).components
            let elapsed = Double(d.seconds)+Double(d.attoseconds)/1e18
            if elapsed > 1 { break }
        }
        print(String(format: "RADIO_SCENE_CLOCK updates %.0f media %.3f underruns %lld pending %d callbacks %d ran %.3f overruns %d",
            Double(updates),model.clock.seconds,model.clock.underruns,model.audioPending,
            model.audioBlocksConsumed,model.audioRanTime,model.audioOverruns))
        XCTAssertLessThan(updates,30,"The clock must not be republished on every 5 ms poll")
        XCTAssertEqual(model.clock.underruns,0,"The producer must never let the FIFO empty while running")
    }

    /// With eight transmitters the default sources are tone generators, so the
    /// DSP is at its heaviest. The producer must still keep the FIFO ahead of
    /// the callback: the low water mark never dips toward zero, and no block is
    /// discarded as late.
    @MainActor func testEightTransmitterFIFOHeadroom() async throws {
        #if DEBUG
        throw XCTSkip("Measure the production producer with -c release")
        #else
        let model = RadioSceneModel(); model.muted = true
        XCTAssertEqual(model.settings.transmitters.count,RadioSceneSettings.transmitterSlots)
        defer { model.pause() }
        model.play()
        guard model.clock.playing else { throw XCTSkip("No audio output: \(model.clock.status)") }
        try await Task.sleep(for: .seconds(2))
        print(String(format: "RADIO_SCENE_8TX dsp %.2f ms · schedule %.2f ms · fifo %lld · underruns %lld",
            model.clock.processingMS,model.clock.scheduleMS,
            model.clock.fifoMinimum == Int.max ? -1 : Int64(model.clock.fifoMinimum),model.clock.underruns))
        XCTAssertGreaterThan(model.producerBlocks,20)
        XCTAssertGreaterThan(model.clock.fifoMinimum,0,"The producer must keep ahead of the callback")
        XCTAssertEqual(model.clock.underruns,0)
        #endif
    }
    /// The media clock must track wall time while the scene runs: one second of
    /// playback advances the reported clock by roughly a second. A stalled
    /// callback or a dead producer shows up here even when every per-block
    /// number looks fine.
    @MainActor func testClockTracksWallTime() async throws {
        #if DEBUG
        throw XCTSkip("Measure the production producer with -c release")
        #else
        let model = RadioSceneModel(); model.muted = true
        defer { model.pause() }
        model.play()
        guard model.clock.playing else { throw XCTSkip("No audio output: \(model.clock.status)") }
        try await Task.sleep(for: .milliseconds(2000))
        print(String(format: "RADIO_SCENE_CLOCK media %.3f blocks %d underruns %lld",
            model.clock.seconds,model.producerBlocks,model.clock.underruns))
        XCTAssertGreaterThan(model.clock.seconds,1.5)
        // The producer must never stop on its own. Before the ring had
        // backpressure it raced ahead, overflowed, and died after ~25 blocks.
        XCTAssertGreaterThan(model.producerBlocks,80,"The producer must keep feeding blocks for the whole run")
        XCTAssertEqual(model.clock.underruns,0)
        #endif
    }
    /// The four numbers that tell compute, scheduling and buffering apart.
    /// DSP compute time and end-to-end block latency are both reported; their
    /// difference is scheduling delay. The FIFO low water mark catches a
    /// producer that is behind even when every block fits its budget.
    @MainActor func testSchedulingLatencyAndFIFOHeadroom() async throws {
        #if DEBUG
        throw XCTSkip("Measure the production producer with -c release")
        #else
        let model = RadioSceneModel(); model.muted = true
        XCTAssertEqual(model.settings.transmitters.count,RadioSceneSettings.transmitterSlots)
        for n in model.settings.transmitters.indices { model.configure { $0.transmitters[n].mode = .fm }}
        for n in model.settings.receivers.indices { model.configure { $0.receivers[n].mode = .fm }}
        defer { model.pause() }
        model.play()
        guard model.clock.playing else { throw XCTSkip("No audio output: \(model.clock.status)") }
        try await Task.sleep(for: .seconds(2))
        let blockBudgetMS = 1024.0/48_000*1000
        print(String(format: "RADIO_SCENE_SCHEDULING dsp %.2f ms · schedule %.2f ms · fifo %lld · underruns %lld",
            model.clock.processingMS,model.clock.scheduleMS,
            model.clock.fifoMinimum == Int.max ? -1 : Int64(model.clock.fifoMinimum),model.clock.underruns))
        XCTAssertGreaterThan(model.producerBlocks,20)
        XCTAssertLessThan(model.clock.processingMS,blockBudgetMS,"Eight FM stations must fit the block budget")
        XCTAssertLessThan(model.clock.scheduleMS,blockBudgetMS,"End-to-end block latency must fit the budget too")
        XCTAssertGreaterThanOrEqual(model.clock.fifoMinimum,0)
        XCTAssertEqual(model.clock.underruns,0)
        #endif
    }
    /// An imported source must cost the same as a test tone: the decoded PCM is
    /// pushed to the DSP actor on change, not once per block.
    @MainActor func testImportedSourceCostsTheSameAsATone() async throws {
        let tone = RadioSceneModel()
        let imported = RadioSceneModel()
        for tx in imported.settings.transmitters { imported.setSource(tx.id,samples: source(120),name: "probe.wav") }
        XCTAssertFalse(imported.sourceNames.isEmpty)
        let toneProcessor = RadioSceneProcessor(startSample: 0)
        let importedProcessor = RadioSceneProcessor(startSample: 0)
        
        func measure(_ processor: RadioSceneProcessor,_ model: RadioSceneModel) async throws -> Double {
            _ = try await processor.process(settings: model.settings,clips: imported.clips)
            var total = 0.0
            for _ in 0..<24 { total += try await processor.process(settings: model.settings,clips: imported.clips).seconds }
            return total/24*1000
        }
        let toneMS = try await measure(toneProcessor,tone)
        let importedMS = try await measure(importedProcessor,imported)
        print("RADIO_SCENE_SOURCE tone \(toneMS) ms vs imported \(importedMS) ms per block")
        XCTAssertLessThan(importedMS,toneMS*1.6+2,"Imported audio must not add per-block copying work")
        XCTAssertLessThan(importedMS,21.33)
    }
}
