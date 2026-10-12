import XCTest
@testable import AnalogCore

/// P0 acceptance: deterministic frame identity, monotonic per-stage progress and
/// atomic commit. A frame that fails must leave nothing behind, including the
/// recursive state of the modulators, the channel and the receiver.
final class TVProcessContractTests: XCTestCase {
    private func cvbs(_ system: TerrestrialSystem, frame: Int64) throws -> CompositeVideo {
        try TVEngine.encode(TVFrame.colorBars(system.video), frameIndex: frame)
    }
    private func tone(_ system: TerrestrialSystem, frame: Int64) -> [Float] {
        let start = TVSoundClock.offset(frame: frame,standard: system.video)
        return (0..<TVSoundClock.count(frame: frame,standard: system.video)).map {
            Float(0.25*sin(2 * .pi * 1000 * Double(start+Int64($0))/48_000))
        }
    }
    private func settings(_ system: TerrestrialSystem) -> TerrestrialSettings {
        var value = TerrestrialSettings(system: system)
        value.carrierToNoiseDB = 100
        return value
    }
    private func maximumError(_ a: TVFrame, _ b: TVFrame) -> Float {
        var maximum: Float = 0
        for (x,y) in zip(a.rgb,b.rgb) { for c in 0..<3 { maximum = max(maximum,abs(x[c]-y[c])) } }
        return maximum
    }

    // MARK: - Identity

    func testIdentityTracksTheFrameSampleGrid() throws {
        for system in TerrestrialSystem.allCases {
            var engine = TVUnifiedChannelEngine(system: system)
            let settings = settings(system)
            for frame: Int64 in 0..<4 {
                let reception = try engine.process(try cvbs(system, frame: frame),settings: settings,
                                                   audio: tone(system, frame: frame))
                let identity = try XCTUnwrap(reception.frameIdentity)
                XCTAssertEqual(identity.frameIndex,frame)
                XCTAssertEqual(identity.sampleStart,system.video.sampleOffset(frame: frame))
                XCTAssertGreaterThan(identity.sampleCount,0)
                XCTAssertEqual(reception.frameContinuity,frame == 0 ? .first : .continuous)
            }
            XCTAssertTrue(engine.progress.stagesBehind(frameIndex: 3).isEmpty,
                          "Every stage that ran must be on the last frame")
            XCTAssertEqual(engine.progress.totalDiscontinuities,0)
            XCTAssertEqual(engine.progress.totalCommits,9*4,
                          "Nine stages commit once per frame when the companion carrier is on")
        }
    }

    /// The player re-runs a frame on purpose to settle the loops before a paused
    /// preview, so a repeat is recorded and counted rather than refused: it is a
    /// whole extra frame of work and must not be invisible.
    func testRepeatedFrameIsRecordedAndCounted() throws {
        for system in TerrestrialSystem.allCases {
            var engine = TVUnifiedChannelEngine(system: system)
            let settings = settings(system)
            let frame = try cvbs(system, frame: 0)
            _ = try engine.process(frame,settings: settings)
            let commits = engine.progress.totalCommits
            let reception = try engine.process(frame,settings: settings)
            XCTAssertEqual(reception.frameContinuity,.repeatOrRewind)
            XCTAssertEqual(engine.progress.totalCommits,commits+8,
                           "A repeat still runs and commits every stage that ran")
            XCTAssertEqual(engine.progress.totalRepeats,8)
        }
    }

    /// Strict order is opt-in, for callers that can guarantee monotonic frames.
    func testStrictOrderRefusesARepeatWithoutAdvancing() throws {
        for system in TerrestrialSystem.allCases {
            var engine = TVUnifiedChannelEngine(system: system)
            engine.strictFrameOrder = true
            let settings = settings(system)
            let frame = try cvbs(system, frame: 0)
            _ = try engine.process(frame,settings: settings)
            let commits = engine.progress.totalCommits
            XCTAssertThrowsError(try engine.process(frame,settings: settings)) { error in
                guard case TVError.outOfOrderFrame = error else {
                    return XCTFail("Expected outOfOrderFrame, got \(error)")
                }
            }
            XCTAssertEqual(engine.progress.totalCommits,commits,
                           "A refused frame must not advance any stage")
        }
    }

    func testForwardGapIsRecordedAndAccepted() throws {
        for system in TerrestrialSystem.allCases {
            var engine = TVUnifiedChannelEngine(system: system)
            let settings = settings(system)
            _ = try engine.process(try cvbs(system, frame: 0),settings: settings)
            let reception = try engine.process(try cvbs(system, frame: 5),settings: settings)
            guard case .forwardGap(let samples,let frames) = reception.frameContinuity else {
                return XCTFail("A seek forward is a gap, not a violation: \(reception.frameContinuity)")
            }
            XCTAssertEqual(frames,4)
            XCTAssertGreaterThan(samples,0)
            XCTAssertGreaterThan(engine.progress.totalDiscontinuities,0)
        }
    }

    // MARK: - Atomic commit

    /// The decisive P0 test: a stage that fails in the middle of a frame must
    /// leave the engine bit-identical to one that never saw the frame, so the
    /// next frames produce exactly the same signal.
    func testInjectedFaultRollsBackEveryStage() throws {
        for system in TerrestrialSystem.allCases {
            var settings = settings(system)
            settings.echoGain = 0.15; settings.echoDelayMicroseconds = 4.3
            settings.tuningOffsetKHz = 20
            settings.transmitter.enabled = true; settings.transmitter.sharedCoupling = 0.15
            settings.receiverDamage.agcEnabled = true
            var frames = [CompositeVideo]()
            var audio = [[Float]]()
            for frame: Int64 in 0..<5 {
                frames.append(try cvbs(system, frame: frame))
                audio.append(tone(system, frame: frame))
            }
            var reference = TVUnifiedChannelEngine(system: system)
            var expected = [TerrestrialReception]()
            for (index,frame) in frames.enumerated() {
                expected.append(try reference.process(frame,settings: settings,audio: audio[index]))
            }

            for fault in TVProcessFault.allCases {
                var subject = TVUnifiedChannelEngine(system: system)
                _ = try subject.process(frames[0],settings: settings,audio: audio[0])
                let commits = subject.progress.totalCommits
                TVProcessDiagnostics.injectedFault = fault
                XCTAssertThrowsError(try subject.process(frames[1],settings: settings,audio: audio[1]),
                                     "\(system) \(fault) must fail") { error in
                    guard case TVError.injectedFault = error else {
                        return XCTFail("Expected injectedFault, got \(error)")
                    }
                }
                TVProcessDiagnostics.injectedFault = nil
                XCTAssertEqual(subject.progress.totalCommits,commits,
                               "\(system) \(fault): progress advanced for a failed frame")
                for index in 1..<5 {
                    let actual = try subject.process(frames[index],settings: settings,audio: audio[index])
                    XCTAssertLessThan(maximumError(actual.frame,expected[index].frame),1e-7,
                                      "\(system) \(fault) frame \(index): state did not roll back")
                }
            }
        }
    }

    func testProgramFaultAndLockLossStayDistinct() throws {
        let system = TerrestrialSystem.palDK
        var settings = settings(system)
        settings.signalDB = -80; settings.carrierToNoiseDB = 10
        var engine = TVUnifiedChannelEngine(system: system)
        // Loss of lock is part of the receiver model: it must not throw, and it
        // must keep advancing physical time.
        let reception = try engine.process(try cvbs(system, frame: 0),settings: settings)
        XCTAssertNotEqual(reception.lock,.locked)
        XCTAssertEqual(reception.frameIdentity?.frameIndex,0)
        XCTAssertEqual(engine.progress.totalDiscontinuities,0)
        // A program-level violation is a different thing and is refused when the
        // caller asks for strict ordering.
        engine.strictFrameOrder = true
        XCTAssertThrowsError(try engine.process(try cvbs(system, frame: 0),settings: settings))
    }

    // MARK: - Carrier strategy telemetry (P1)

    func testCarrierStrategyIsReportedPerFrame() throws {
        for system in TerrestrialSystem.allCases {
            var settings = settings(system)
            settings.performance = .mobile
            settings.echoGain = 0.15; settings.tuningOffsetKHz = 20
            var engine = TVUnifiedChannelEngine(system: system)
            var tracked = false
            for frame: Int64 in 0..<5 {
                let reception = try engine.process(try cvbs(system, frame: frame),settings: settings)
                if frame == 0 {
                    // The frame that acquires the carrier must run the dense
                    // path even though its own capture result may already be
                    // positive: both decisions follow the state on entry.
                    XCTAssertEqual(reception.carrierEstimationDecimation,1,
                                   "\(system): acquisition must use the full-rate estimate")
                    XCTAssertEqual(reception.carrierPLLStrideUsed,1,
                                   "\(system): acquisition must use the dense phase feedback")
                } else {
                    tracked = tracked || reception.carrierTracked
                    XCTAssertLessThanOrEqual(reception.carrierEstimationDecimation,
                                             settings.performance.afcLockedDecimation)
                    XCTAssertLessThanOrEqual(reception.carrierPLLStrideUsed,
                                             settings.performance.carrierPLLStride)
                }
            }
            XCTAssertTrue(tracked,"\(system): a clean carrier must end up tracked")
        }
    }
}
