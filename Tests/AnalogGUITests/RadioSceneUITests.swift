import XCTest
import SwiftUI
import AppKit
import Combine
@testable import AnalogCore
@testable import AnalogGUI

final class RadioSceneUITests: XCTestCase {
    @MainActor func testStationLimitsAndIndependentDemodulation() {
        let model = RadioSceneModel()
        // The rack arrives full: eight transmitters, two receivers. Stations go
        // off air through their power switch, not by leaving the list.
        XCTAssertEqual(model.settings.transmitters.count,RadioSceneSettings.transmitterSlots)
        XCTAssertEqual(model.settings.receivers.count,RadioSceneSettings.receiverSlots)
        XCTAssertEqual(Set(model.settings.transmitters.map(\.id)).count,RadioSceneSettings.transmitterSlots)
        model.configure { $0.transmitters[0].mode = .pm }
        model.configure { $0.receivers[0].mode = .lsb }
        model.configure { $0.receivers[1].mode = .cw }
        XCTAssertEqual(model.settings.transmitters[0].mode,.pm)
        XCTAssertEqual(model.settings.receivers[0].mode,.lsb)
        XCTAssertEqual(model.settings.receivers[1].mode,.cw)
        // Powering a station down leaves its slot in place.
        model.editTX(model.settings.transmitters[0].id) { $0.enabled = false }
        XCTAssertEqual(model.settings.transmitters.count,RadioSceneSettings.transmitterSlots)
        XCTAssertFalse(model.settings.transmitters[0].enabled)
        XCTAssertEqual(model.settings.transmitters.filter(\.enabled).count,RadioSceneSettings.transmitterSlots-1)
        model.removeRX(model.settings.receivers[0].id)
        XCTAssertEqual(model.settings.receivers.count,1)
    }
    @MainActor func testStereoScenePlaybackAndLiveConfiguration() async throws {
        #if DEBUG
        throw XCTSkip("Full scene playback uses optimized Release DSP")
        #else
        let model = RadioSceneModel(); model.muted = true; model.monitor = .stereo
        defer { model.pause() }
        model.play()
        guard model.clock.playing else { throw XCTSkip("No audio output: \(model.clock.status)") }
        try await Task.sleep(for: .milliseconds(800))
        XCTAssertGreaterThan(model.clock.seconds,0.2)
        print("PROBE display ids:",model.txDisplay(model.settings.transmitters[0].id) === model.txDisplay(model.settings.transmitters[0].id), "blocks:",model.producerBlocks,"displayCount:",model.producerDisplayCount)
        if model.txDisplay(model.settings.transmitters[0].id).spectrum == nil {
            print("PROBE after 800 ms: playing=\(model.clock.playing) seconds=\(model.clock.seconds) underruns=\(model.clock.underruns) dsp=\(model.clock.processingMS) schedule=\(model.clock.scheduleMS) fifo=\(model.clock.fifoMinimum) tx=\(model.settings.transmitters.count)")
        }
        XCTAssertNotNil(model.txDisplay(model.settings.transmitters[0].id).spectrum)
        XCTAssertNotNil(model.rxDisplay(model.settings.receivers[0].id).history.image)
        model.configure { $0.transmitters[2].mode = .cw }
        model.configure { $0.receivers[1].mode = .fm }
        model.monitor = .second
        try await Task.sleep(for: .milliseconds(350))
        XCTAssertTrue(model.clock.playing,model.clock.status)
        model.configure { $0.transmitters[1].enabled = false }
        model.configure { $0.transmitters[2].enabled = false }
        model.monitor = .stereo
        try await Task.sleep(for: .milliseconds(250))
        XCTAssertTrue(model.clock.playing)
        XCTAssertEqual(model.clock.underruns,0)
        model.pause(); let position = model.clock.seconds
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(model.clock.seconds,position)
        #endif
    }
    @MainActor func testPlaybackReconnectsDisplayObserversAndPreservesPausedFrame() async throws {
        let model = RadioSceneModel(); model.muted = true
        let id = model.settings.transmitters[0].id
        let idleDisplay = model.txDisplay(id)
        var changes = 0
        let subscription = model.objectWillChange.sink { changes += 1 }
        defer { subscription.cancel(); model.pause() }
        model.play()
        guard model.clock.playing else { throw XCTSkip("No audio output: \(model.clock.status)") }
        XCTAssertGreaterThan(changes,0,"Cards already on screen must reconnect when the display box changes")
        let liveDisplay = model.txDisplay(id)
        XCTAssertFalse(idleDisplay === liveDisplay)
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertNotNil(liveDisplay.spectrum)
        model.pause()
        XCTAssertTrue(model.txDisplay(id) === liveDisplay,"Pause must preserve the displayed RF frame")
        XCTAssertNotNil(model.txDisplay(id).spectrum)
    }
    @MainActor func testRenderEightTXTwoRX() async throws {
        let model = RadioSceneModel()
        XCTAssertEqual(model.settings.transmitters.count,RadioSceneSettings.transmitterSlots)
        let modes = RadioSceneMode.allCases
        for n in model.settings.transmitters.indices { model.configure { $0.transmitters[n].mode = modes[n % modes.count] }}
        // Tune the first receiver onto the first AM station, so the recovered
        // level below measures a live carrier instead of wherever the default
        // tuning happened to land once the rack gained its carrier spread.
        let carrier = try XCTUnwrap(model.settings.transmitters.first { $0.mode == .am }).carrierHz
        model.editRX(model.settings.receivers[0].id) { $0.mode = .am; $0.tuningHz = carrier }
        let processor = RadioSceneProcessor(startSample: 0)
        for _ in 0..<24 {
            let result = try await processor.process(settings: model.settings,clips: [:])
            model.clock.seconds = Double(result.frame.firstAudioSample)/48_000
            model.clock.processingMS = result.seconds*1000
            for (id,spectrum) in result.frame.transmitSpectra { model.txDisplay(id).apply(spectrum) }
            for (id,reception) in result.frame.receptions { model.rxDisplay(id).apply(reception,time: model.clock.seconds) }
        }
        let view = RadioSceneView(model: model).frame(width: 1200,height: 920)
            .environment(\.colorScheme,.dark).background(Color(white: 0.15))
        let host = NSHostingView(rootView: view)
        let window = NSWindow(contentRect: NSRect(x: -10000,y: -10000,width: 1200,height: 920),styleMask: [.borderless],backing: .buffered,defer: false)
        window.isReleasedWhenClosed = false; window.appearance = NSAppearance(named: .darkAqua)
        window.contentView = host; host.frame = NSRect(x: 0,y: 0,width: 1200,height: 920)
        host.layoutSubtreeIfNeeded(); try await Task.sleep(for: .milliseconds(120))
        host.layoutSubtreeIfNeeded(); host.displayIfNeeded()
        let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds,to: bitmap)
        let data = try XCTUnwrap(bitmap.representation(using: .png,properties: [:]))
        try data.write(to: URL(fileURLWithPath: "/tmp/analine-radio-scene.png"))
        window.close()
        XCTAssertEqual(model.settings.transmitters.count,8)
        XCTAssertNotNil(model.rxDisplay(model.settings.receivers[1].id).history.image)
        let first = model.rxDisplay(model.settings.receivers[0].id)
        XCTAssertGreaterThan(first.levelDB,-60,"An AM receiver on a live carrier must report recovered audio")
        XCTAssertEqual(first.scope.count,RadioSceneRXDisplay.scopeColumns)
        XCTAssertTrue(first.scope.allSatisfy { $0 >= 0 && $0 <= 1 })
        XCTAssertNotNil(first.environmentHistory.image,"The wideband environment tap must be measured before tuning")
        XCTAssertEqual(first.environmentHistory.width,1024)
    }
    @MainActor func testEnvironmentReceiverSelectionAndZoomCrop() {
        let model = RadioSceneModel()
        let first = model.settings.receivers[0].id, second = model.settings.receivers[1].id
        XCTAssertEqual(model.environmentReceiverID,first)
        model.environmentRX = second
        XCTAssertEqual(model.environmentReceiverID,second)
        model.removeRX(second)
        XCTAssertEqual(model.environmentReceiverID,first,"Removing RX 2 must fall back to RX 1")
        model.removeRX(first)
        XCTAssertNil(model.environmentReceiverID)

        let history = TVSpectrumHistory(width: 128)
        history.update(TVSpectrum(sampleRate: 768_000,centerHz: 0,
            powerDB: (0..<256).map { Float($0)/2-100 }),time: 0)
        XCTAssertNotNil(history.image)
        XCTAssertNotNil(history.croppedImage(lowerHz: -384_000,upperHz: 384_000))
        XCTAssertEqual(history.columnRange(lowerHz: -384_000,upperHz: 384_000).lowerBound,0,accuracy: 0.001)
        XCTAssertEqual(history.columnRange(lowerHz: -384_000,upperHz: 384_000).upperBound,1,accuracy: 0.001)
        XCTAssertEqual(history.columnRange(lowerHz: 0,upperHz: 192_000).lowerBound,0.5,accuracy: 0.01)
        XCTAssertEqual(history.columnRange(lowerHz: 0,upperHz: 192_000).upperBound,0.75,accuracy: 0.01)
        XCTAssertEqual(history.croppedImage(lowerHz: 0,upperHz: 192_000)?.width,32)
        history.reset()
        XCTAssertNil(history.image)
        XCTAssertTrue(history.trace.isEmpty)
    }
    @MainActor func testReceiverBandBracketMatchesDemodulation() {
        var rx = RadioSceneRX(); rx.tuningHz = 10_000
        rx.mode = .usb; rx.parameters.ssb.audioBandwidthHz = 3_000
        XCTAssertEqual(RadioSceneMarkerOverlay.band(rx).lowerBound,10_200,accuracy: 0.001)
        XCTAssertEqual(RadioSceneMarkerOverlay.band(rx).upperBound,13_000,accuracy: 0.001)
        rx.mode = .lsb
        XCTAssertEqual(RadioSceneMarkerOverlay.band(rx).lowerBound,7_000,accuracy: 0.001)
        XCTAssertEqual(RadioSceneMarkerOverlay.band(rx).upperBound,9_800,accuracy: 0.001)
        rx.mode = .cw; rx.parameters.cw.receiveBandwidthHz = 800
        XCTAssertEqual(RadioSceneMarkerOverlay.band(rx).lowerBound,9_600,accuracy: 0.001)
        XCTAssertEqual(RadioSceneMarkerOverlay.band(rx).upperBound,10_400,accuracy: 0.001)
        rx.mode = .am; rx.parameters.am.audioBandwidthHz = 5_000
        XCTAssertEqual(RadioSceneMarkerOverlay.band(rx).lowerBound,2_500,accuracy: 0.001)
        XCTAssertEqual(RadioSceneMarkerOverlay.band(rx).upperBound,17_500,accuracy: 0.001)
    }
    @MainActor func testEnvelopeAndLevelReset() {
        let display = RadioSceneRXDisplay()
        display.apply(RadioSceneReception(samples: [0,1,0,-1,0,0.5],spectrum: nil,environment: nil,overloaded: true,levelDB: -6),time: 0)
        XCTAssertEqual(display.levelDB,-6)
        XCTAssertTrue(display.overloaded)
        XCTAssertEqual(display.scope.count,RadioSceneRXDisplay.scopeColumns)
        XCTAssertEqual(display.scope.max(),1)
        display.clear()
        XCTAssertEqual(display.levelDB,-100)
        XCTAssertTrue(display.scope.isEmpty)
        XCTAssertFalse(display.overloaded)
        XCTAssertEqual(RadioSceneRXDisplay.envelope([],columns: 4),[])
        XCTAssertEqual(RadioSceneRXDisplay.envelope([0.2,0.8,0.4,0.6],columns: 2),[0.8,0.6])
    }
}
