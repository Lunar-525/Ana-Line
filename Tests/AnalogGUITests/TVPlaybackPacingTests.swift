import XCTest
import Combine
import AnalogCore
@testable import AnalogGUI

@MainActor
final class TVPlaybackPacingTests: XCTestCase {
    func testRealtimeDeadlineDoesNotRequireTenPercentExtraHeadroom() {
        var pacing = TVPlaybackPacing()
        for _ in 0..<120 {
            XCTAssertEqual(pacing.requestedRate(cost: 0.039,frameDuration: 0.04,queuedSeconds: 0.24),1)
        }
        XCTAssertEqual(pacing.requestedRate(cost: 0.09,frameDuration: 0.04,queuedSeconds: 0.2),1)
        for _ in 0..<120 { _ = pacing.requestedRate(cost: 0.06,frameDuration: 0.04,queuedSeconds: 0.1) }
        XCTAssertEqual(pacing.requestedRate(cost: 0.06,frameDuration: 0.04,queuedSeconds: 0.1),1)
        for _ in 0..<120 { _ = pacing.requestedRate(cost: 0.03,frameDuration: 0.04,queuedSeconds: 0.2) }
        XCTAssertEqual(pacing.requestedRate(cost: 0.03,frameDuration: 0.04,queuedSeconds: 0.2),1)
    }

    func testOverloadNeverSlowsClockAndNextFrameCatchesUpForBothStandards() {
        var pacing = TVPlaybackPacing()
        XCTAssertEqual(pacing.requestedRate(cost: 0.12,frameDuration: 0.04,queuedSeconds: 0.06),1)
        XCTAssertEqual(pacing.requestedRate(cost: 0.02,frameDuration: 0.04,queuedSeconds: 0.06),1)
        XCTAssertEqual(pacing.requestedRate(cost: 0.02,frameDuration: 0.04,queuedSeconds: 0.16),1)
        for _ in 0..<8 { _ = pacing.requestedRate(cost: 0.02,frameDuration: 0.04,queuedSeconds: 0.06) }
        XCTAssertEqual(pacing.requestedRate(cost: 0.02,frameDuration: 0.04,queuedSeconds: 0.06),1)
        for standard in TVStandard.allCases {
            let next = TVPlaybackPacing.nextFrame(after: 2,consumedSamples: 48_000,startSample: 0,standard: standard)
            XCTAssertGreaterThanOrEqual(Double(next)/standard.frameRate,1)
            XCTAssertEqual(TVPlaybackPacing.nextFrame(after: 40,consumedSamples: 48_000,startSample: 0,standard: standard),40)
        }
        XCTAssertTrue(TVStatusText.isNormalSpeed(1)); XCTAssertFalse(TVStatusText.isNormalSpeed(0.95))
    }

    func testControlsSynchronizeBothDirectionsWithoutObservingFrameClock() {
        let model = PreviewModel(), state = model.tvControlState
        state.bind(model)
        var changes = 0
        let subscription = state.objectWillChange.sink { changes += 1 }
        model.tvTime = 10; model.status = "Frame received"
        var settings = TVPropagationSettings(); settings.enabled = true
        settings.weather.enabled = true; settings.weather.lightning = 1
        let events = TVLightningTimeline.events(time: 0,duration: 4,seed: 42,settings: settings)
        model.tvLightningState.present(events: events,time: 10)
        XCTAssertEqual(changes,0,"Clock/status updates must not invalidate configuration panels")
        state.tvChannel.propagation.antennaGainDB = 15
        XCTAssertEqual(model.tvChannel.propagation.antennaGainDB,15)
        model.tvChannel.propagation.ridgeEnabled = true
        XCTAssertTrue(state.tvChannel.propagation.ridgeEnabled)
        model.busy = true; XCTAssertTrue(state.busy)
        state.tvStandard = .ntsc
        XCTAssertEqual(model.tvStandard,.ntsc)
        XCTAssertEqual(state.tvChannel.rfBandwidthMHz,6)
        withExtendedLifetime(subscription) {}
    }

    func testTVFramesInvalidateOnlyPreviewObserversAndKeepFilmObservable() {
        let model = PreviewModel(); model.tool = .tv
        var workspaceChanges = 0, frameChanges = 0, receptionChanges = 0
        let workspace = model.objectWillChange.sink { workspaceChanges += 1 }
        let frames = model.tvPreviewState.objectWillChange.sink { frameChanges += 1 }
        let reception = model.tvReceptionState.objectWillChange.sink { receptionChanges += 1 }
        model.tvTime = 12; model.status = "Received frame"
        model.tvReceptionState.lock = .locked
        model.tvReceptionState.synchronization.horizontal = .locked
        XCTAssertEqual(workspaceChanges,0,"A TV frame must not relayout the entire workspace")
        XCTAssertEqual(frameChanges,2); XCTAssertEqual(receptionChanges,2)
        XCTAssertEqual(model.tvTime,12); XCTAssertEqual(model.tvLock,.locked)
        model.tool = .film
        let before = workspaceChanges
        model.status = "Film ready"
        XCTAssertEqual(workspaceChanges,before+1,"Film status must remain observable")
        withExtendedLifetime((workspace,frames,reception)) {}
    }
}
