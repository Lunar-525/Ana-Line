import XCTest
@testable import AnalogCore

/// P2 acceptance: the two-thread pipeline must produce exactly the signal the
/// sequential engine produces, must demonstrably overlap the halves, and must
/// refuse the one combination that would change the hardware model.
final class TVFramePipelineTests: XCTestCase {
    private func cvbs(_ system: TerrestrialSystem, frame: Int64) throws -> CompositeVideo {
        try TVEngine.encode(TVFrame.colorBars(system.video), frameIndex: frame)
    }
    private func tone(_ system: TerrestrialSystem, frame: Int64) -> [Float] {
        let start = TVSoundClock.offset(frame: frame,standard: system.video)
        return (0..<TVSoundClock.count(frame: frame,standard: system.video)).map {
            Float(0.3*sin(2 * .pi * 700 * Double(start+Int64($0))/48_000))
        }
    }
    private func damaged(_ system: TerrestrialSystem) -> TerrestrialSettings {
        var s = TerrestrialSettings(system: system)
        s.echoGain = 0.15; s.echoDelayMicroseconds = 4.3; s.echoPhaseDegrees = 30
        s.tuningOffsetKHz = 20
        s.transmitter.enabled = true; s.transmitter.powerDB = 3
        s.transmitter.sharedCoupling = 0.15
        s.transmitter.encoder.enabled = true; s.transmitter.encoder.differentialGain = 0.05
        s.transmitter.vsb.enabled = true
        s.receiverDamage.agcEnabled = true; s.receiverDamage.syncEnabled = true
        s.propagation.enabled = true; s.propagation.weather.enabled = true
        s.propagation.weather.rainMMHour = 10
        return s
    }
    private func assertSameSignal(_ a: TerrestrialReception, _ b: TerrestrialReception,
                                  _ label: String) {
        XCTAssertEqual(a.frame.rgb.count,b.frame.rgb.count,label)
        var worst: Float = 0
        for (x,y) in zip(a.frame.rgb,b.frame.rgb) { for c in 0..<3 { worst = max(worst,abs(x[c]-y[c])) } }
        XCTAssertEqual(worst,0,"\(label): vision must be bit-identical")
        XCTAssertEqual(a.audio.count,b.audio.count,"\(label): audio length")
        for (x,y) in zip(a.audio,b.audio) { XCTAssertEqual(x,y,"\(label): audio must be bit-identical") }
        XCTAssertEqual(a.lock,b.lock,label)
        XCTAssertEqual(a.recoveredLines,b.recoveredLines,label)
        XCTAssertEqual(a.colorLockedLines,b.colorLockedLines,label)
        XCTAssertEqual(a.agcDB,b.agcDB,label)
        XCTAssertEqual(a.carrierErrorHz,b.carrierErrorHz,label)
        XCTAssertEqual(a.soundCarrierDB,b.soundCarrierDB,label)
        XCTAssertEqual(a.transmitter.forwardPower,b.transmitter.forwardPower,label)
        XCTAssertEqual(a.transmitter.saturated,b.transmitter.saturated,label)
        XCTAssertEqual(a.transmitter.overmodulated,b.transmitter.overmodulated,label)
        XCTAssertEqual(a.carrierTracked,b.carrierTracked,label)
        XCTAssertEqual(a.carrierEstimationDecimation,b.carrierEstimationDecimation,label)
        XCTAssertEqual(a.carrierPLLStrideUsed,b.carrierPLLStrideUsed,label)
    }

    /// The decisive P2 test: overlap must not change a single sample.
    func testPipelineMatchesSequentialExactly() throws {
        for system in TerrestrialSystem.allCases {
            let settings = damaged(system)
            let count = 5
            var frames = [CompositeVideo](), audio = [[Float]]()
            for n in 0..<count { frames.append(try cvbs(system,frame: Int64(n))); audio.append(tone(system,frame: Int64(n))) }
            var sequential = TVUnifiedChannelEngine(system: system)
            var expected = [TerrestrialReception]()
            for n in 0..<count { expected.append(try sequential.process(frames[n],settings: settings,audio: audio[n])) }

            let pipeline = TVFramePipeline(system: system)
            try pipeline.submit(frames[0],settings: settings,audio: audio[0])
            for n in 0..<count {
                if pipeline.allowsLookahead,n+1 < count {
                    try pipeline.submit(frames[n+1],settings: settings,audio: audio[n+1])
                }
                let actual = try pipeline.receive()
                assertSameSignal(actual,expected[n],"\(system) frame \(n)")
                XCTAssertEqual(actual.frameIdentity?.frameIndex,Int64(n))
            }
            XCTAssertTrue(pipeline.progress.stagesBehind(frameIndex: Int64(count-1)).isEmpty)
            XCTAssertEqual(pipeline.progress.totalCommits,Int64(9*count))
            XCTAssertEqual(pipeline.pendingFrames,0)
            // Deterministic evidence that the halves really overlapped.
            XCTAssertGreaterThanOrEqual(pipeline.overlapped,count-2,
                "\(system): the transmit half must run ahead of the receive half")
        }
    }

    /// The benchmark hands frame construction to the transmit thread so the CVBS
    /// encode overlaps the receive pass. That path must be just as exact.
    func testDeferredConstructionMatchesSequentialExactly() throws {
        for system in TerrestrialSystem.allCases {
            let settings = damaged(system)
            let count = 4
            var sequential = TVUnifiedChannelEngine(system: system)
            var expected = [TerrestrialReception]()
            let source = TVFrame.colorBars(system.video)
            for n in 0..<count {
                let input = try TVEngine.encode(source,frameIndex: Int64(n),damage: settings.transmitter.encoder)
                expected.append(try sequential.process(input,settings: settings,audio: tone(system,frame: Int64(n))))
            }
            let pipeline = TVFramePipeline(system: system)
            let built: @Sendable (Int64) throws -> (CompositeVideo, [Float]?) = { index in
                let start = TVSoundClock.offset(frame: index,standard: system.video)
                let audio = (0..<TVSoundClock.count(frame: index,standard: system.video)).map {
                    Float(0.3*sin(2 * .pi * 700 * Double(start+Int64($0))/48_000))
                }
                return (try TVEngine.encode(source,frameIndex: index,damage: settings.transmitter.encoder),audio)
            }
            try pipeline.submit(TVFrameRequest(frameIndex: 0,settings: settings,build: built))
            for n in 0..<count {
                if pipeline.allowsLookahead,n+1 < count {
                    try pipeline.submit(TVFrameRequest(frameIndex: Int64(n+1),settings: settings,build: built))
                }
                assertSameSignal(try pipeline.receive(),expected[n],"\(system) deferred frame \(n)")
            }
            XCTAssertGreaterThanOrEqual(pipeline.overlapped,count-2)
        }
    }

    /// The shared front-end gain is measured by the receiver and consumed by the
    /// next frame's transmitter, so that combination cannot be overlapped.
    func testSharedGainCouplingRefusesOverlap() throws {
        for system in TerrestrialSystem.allCases {
            var settings = damaged(system)
            settings.frontEnd.agcEnabled = true
            settings.automaticGain = true
            let count = 4
            var frames = [CompositeVideo](), audio = [[Float]]()
            for n in 0..<count { frames.append(try cvbs(system,frame: Int64(n))); audio.append(tone(system,frame: Int64(n))) }
            var sequential = TVUnifiedChannelEngine(system: system)
            var expected = [TerrestrialReception]()
            for n in 0..<count { expected.append(try sequential.process(frames[n],settings: settings,audio: audio[n])) }

            let pipeline = TVFramePipeline(system: system)
            for n in 0..<count {
                try pipeline.submit(frames[n],settings: settings,audio: audio[n])
                XCTAssertFalse(pipeline.allowsLookahead,
                               "\(system): a coupled frame in flight must stop the lookahead")
                let actual = try pipeline.receive()
                assertSameSignal(actual,expected[n],"\(system) coupled frame \(n)")
            }
            XCTAssertEqual(pipeline.overlapped,0,"A coupled pipeline must not overlap any transmit")
        }
    }

    func testCoupledFrameIsRefusedWhileAnotherIsInFlight() throws {
        let system = TerrestrialSystem.palDK
        var coupled = damaged(system)
        coupled.frontEnd.agcEnabled = true
        let pipeline = TVFramePipeline(system: system)
        try pipeline.submit(try cvbs(system,frame: 0),settings: damaged(system),audio: tone(system,frame: 0))
        XCTAssertThrowsError(try pipeline.submit(try cvbs(system,frame: 1),settings: coupled,
                                                 audio: tone(system,frame: 1))) { error in
            guard case TVError.pipelineCoupling = error else {
                return XCTFail("Expected pipelineCoupling, got \(error)")
            }
        }
        _ = try pipeline.receive()
    }
}
