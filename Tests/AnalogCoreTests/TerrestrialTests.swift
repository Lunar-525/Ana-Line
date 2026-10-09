import XCTest
@testable import AnalogCore

final class TerrestrialTests: XCTestCase {
    func testVSBSuppressesLowerSidebandAndRetainsCarrier() throws {
        for system in TerrestrialSystem.allCases {
            let s = system.video, count = Int(s.sampleOffset(frame: 1))
            let frequency = 2e6
            let wave = (0..<count).map { Float(0.2*cos(2 * .pi * frequency * Double($0)/s.sampleRate)) }
            let cvbs = try CompositeVideo(standard: s, frameIndex: 0, samples: wave)
            var modulator = VSBModulator(system: system)
            let rf = try modulator.modulate(cvbs)
            func magnitude(_ frequency: Double) -> Double {
                var re = 0.0, im = 0.0
                for n in 512..<32_768 {
                    let p = 2 * Double.pi * frequency * Double(n)/s.sampleRate
                    re += Double(rf.i[n])*cos(p)+Double(rf.q[n])*sin(p)
                    im += Double(rf.q[n])*cos(p)-Double(rf.i[n])*sin(p)
                }
                return hypot(re,im)/Double(32_768-512)
            }
            XCTAssertGreaterThan(magnitude(frequency), 0.12)
            XCTAssertLessThan(magnitude(-frequency), magnitude(frequency)*0.03)
            if system == .palDK { XCTAssertEqual(magnitude(0), 0.7375, accuracy: 0.002) }
            else { XCTAssertGreaterThan(magnitude(0), 0.69) } // NTSC-M active-picture pedestal
        }
    }

    func testCleanRFRecoversBothFieldsAndColor() throws {
        for system in TerrestrialSystem.allCases {
            var engine = TerrestrialEngine(system: system)
            var settings = TerrestrialSettings(system: system); settings.carrierToNoiseDB = 100
            let source = TVFrame.colorBars(system.video)
            for index: Int64 in [0,1,2] {
                let result = try engine.process(TVEngine.encode(source, frameIndex: index), settings: settings)
                XCTAssertEqual(result.lock, .locked)
                XCTAssertEqual(result.synchronization.horizontal,.locked)
                XCTAssertEqual(result.synchronization.vertical,.locked)
                XCTAssertEqual(result.synchronization.color,.locked)
                XCTAssertGreaterThan(result.recoveredLines, system.video.height*95/100)
                XCTAssertGreaterThan(result.colorLockedLines, system.video.height*95/100)
                for row in [system.video.height/4,system.video.height/4+1] {
                    for x in stride(from: 45, to: 720, by: 90) {
                        let pixel = row*720+x
                        for c in 0..<3 { XCTAssertEqual(result.frame.rgb[pixel][c],source.rgb[pixel][c],accuracy: 0.12) }
                    }
                }
            }
        }
    }

    func testAGCAndAFCRecoverWeakDetunedSignal() throws {
        let system = TerrestrialSystem.palDK
        var settings = TerrestrialSettings(system: system)
        settings.signalDB = -20; settings.carrierToNoiseDB = 90; settings.tuningOffsetKHz = 60
        var engine = TerrestrialEngine(system: system)
        let source = TVFrame.colorBars(system.video)
        var result: TerrestrialReception!
        for index: Int64 in 0..<3 { result = try engine.process(TVEngine.encode(source,frameIndex: index),settings: settings) }
        XCTAssertEqual(result.lock,.locked)
        XCTAssertGreaterThan(result.agcDB,15)
        settings.automaticFineTuning = false
        result = try engine.process(TVEngine.encode(source,frameIndex: 3),settings: settings)
        XCTAssertNotEqual(result.lock,.locked)
        XCTAssertGreaterThan(abs(result.carrierErrorHz),50_000)
    }

    func testLossDoesNotThrowAndSignalCanRelock() throws {
        for system in TerrestrialSystem.allCases {
            var engine = TerrestrialEngine(system: system)
            let source = TVFrame.colorBars(system.video)
            var settings = TerrestrialSettings(system: system)
            let first = try engine.process(TVEngine.encode(source), settings: settings)
            XCTAssertEqual(first.lock,.locked)
            settings.signalDB = -80; settings.carrierToNoiseDB = 10
            for index: Int64 in 1...4 {
                let lost = try engine.process(TVEngine.encode(source,frameIndex: index),settings: settings)
                XCTAssertNotEqual(lost.lock,.locked)
                XCTAssertEqual(lost.frame.rgb.count,source.rgb.count)
                if index == 4 { XCTAssertEqual(lost.lock,.searching) }
                let expected: TelevisionLock = index <= 3 ? .holding : .searching
                XCTAssertEqual(lost.synchronization.horizontal,expected)
                XCTAssertEqual(lost.synchronization.vertical,expected)
                XCTAssertEqual(lost.synchronization.color,expected)
            }
            settings = TerrestrialSettings(system: system)
            var recovered: TerrestrialReception!
            for index: Int64 in 5...7 { recovered = try engine.process(TVEngine.encode(source,frameIndex: index),settings: settings) }
            XCTAssertEqual(recovered.lock,.locked)
            XCTAssertEqual(recovered.synchronization.horizontal,.locked)
            XCTAssertEqual(recovered.synchronization.vertical,.locked)
            XCTAssertEqual(recovered.synchronization.color,.locked)
        }
    }

    func testColorSyncCanBeLostWhileHorizontalAndVerticalRemainLocked() throws {
        for system in TerrestrialSystem.allCases {
            var engine = TerrestrialEngine(system: system)
            var settings = TerrestrialSettings(system: system); settings.carrierToNoiseDB = 100
            let picture = TVFrame.colorBars(system.video)
            _ = try engine.process(TVEngine.encode(picture),settings: settings)
            settings.rfBandwidthMHz = 3
            for frame: Int64 in 1...4 {
                let result = try engine.process(TVEngine.encode(picture,frameIndex: frame),settings: settings)
                XCTAssertEqual(result.synchronization.horizontal,.locked)
                XCTAssertEqual(result.synchronization.vertical,.locked)
                XCTAssertEqual(result.synchronization.color,frame <= 3 ? .holding : .searching)
            }
        }
    }

    func testVerticalSyncCanBeLostWithoutLosingHorizontalSync() throws {
        for system in TerrestrialSystem.allCases {
            var engine = TerrestrialEngine(system: system)
            var settings = TerrestrialSettings(system: system); settings.carrierToNoiseDB = 100
            let s = system.video, picture = TVFrame.colorBars(s)
            _ = try engine.process(TVEngine.encode(picture),settings: settings)
            for frame: Int64 in 1...4 {
                var composite = try TVEngine.encode(picture,frameIndex: frame)
                // Erase only each field's equalizing/vertical pulse train. Regular
                // horizontal sync and burst in the active picture remain intact.
                for field in 0..<2 {
                    let startTime = Double(frame)*s.frameDuration+Double(field)*s.frameDuration/2
                    let start = max(0,Int(ceil(startTime*s.sampleRate-Double(s.sampleOffset(frame: frame)))))
                    let end = min(composite.samples.count,start+Int(Double(s.equalizingCount*3)*s.samplesPerLine/2))
                    for n in start..<end { composite.samples[n] = 0 }
                }
                let result = try engine.process(composite,settings: settings)
                XCTAssertEqual(result.synchronization.horizontal,.locked)
                XCTAssertEqual(result.synchronization.vertical,frame <= 3 ? .holding : .searching)
                XCTAssertEqual(result.synchronization.color,.locked)
            }
        }
    }

    func testComplexEchoPhaseChangesReceivedSignalAndManualGainMatters() throws {
        let system = TerrestrialSystem.palDK
        let cvbs = try TVEngine.encode(TVFrame.colorBars(system.video))
        var modulator = VSBModulator(system: system)
        let rf = try modulator.modulate(cvbs)
        var settings = TerrestrialSettings(system: system)
        settings.carrierToNoiseDB = 120; settings.echoGain = 0.5; settings.echoDelayMicroseconds = 0
        var path = TerrestrialRFChannel()
        let constructive = try path.transmit(rf, settings: settings)
        settings.echoPhaseDegrees = 180
        let destructive = try path.transmit(rf, settings: settings)
        let n = 12_000
        XCTAssertEqual(constructive.i[n],rf.i[n]*1.5,accuracy: 0.0001)
        XCTAssertEqual(destructive.i[n],rf.i[n]*0.5,accuracy: 0.0001)
        settings = TerrestrialSettings(system: system)
        settings.carrierToNoiseDB = 100; settings.signalDB = -20; settings.automaticGain = false
        var engine = TerrestrialEngine(system: system)
        let weak = try engine.process(cvbs,settings: settings)
        XCTAssertNotEqual(weak.lock,.locked)
        settings.manualGainDB = 20
        var restored: TerrestrialReception!
        for index: Int64 in 1...3 {
            restored = try engine.process(TVEngine.encode(TVFrame.colorBars(system.video),frameIndex: index),settings: settings)
        }
        XCTAssertEqual(restored.lock,.locked)
        XCTAssertEqual(restored.agcDB,20,accuracy: 0.01)
    }

    func testFractionalEchoHistoryCrossesFramesAndInvalidControlsAreRejected() throws {
        let system = TerrestrialSystem.palDK, s = TVStandard.pal
        let n = Int(s.sampleOffset(frame: 1))
        var samples = [Float](repeating: 0,count: n); samples[n-1] = 1
        let first = TelevisionRF(system: system,frameIndex: 0,sampleRate: s.sampleRate,i: samples,q: .init(repeating: 0,count: n))
        let m = Int(s.sampleOffset(frame: 2)-s.sampleOffset(frame: 1))
        let next = TelevisionRF(system: system,frameIndex: 1,sampleRate: s.sampleRate,i: .init(repeating: 0,count: m),q: .init(repeating: 0,count: m))
        var settings = TerrestrialSettings(system: system)
        settings.echoGain = 0.5; settings.echoDelayMicroseconds = Float(3.5/s.sampleRate*1e6)
        settings.carrierToNoiseDB = 120
        var channel = TerrestrialRFChannel()
        _ = try channel.transmit(first,settings: settings)
        let delayed = try channel.transmit(next,settings: settings)
        XCTAssertEqual(delayed.i[2],0.25,accuracy: 0.0001)
        XCTAssertEqual(delayed.i[3],0.25,accuracy: 0.0001)
        settings.signalDB = .nan
        XCTAssertThrowsError(try channel.transmit(next,settings: settings))
        var invalid = next; invalid.q.removeLast()
        XCTAssertThrowsError(try channel.transmit(invalid,settings: TerrestrialSettings(system: system)))
    }

    func testOutOfCaptureTuningAndRejectedCarrierDoNotProduceLock() throws {
        let system = TerrestrialSystem.ntscM
        let picture = TVFrame.colorBars(system.video)
        for (offset, bandwidth): (Float,Float) in [(500,6),(0,1)] {
            var engine = TerrestrialEngine(system: system)
            var settings = TerrestrialSettings(system: system)
            settings.carrierToNoiseDB = 90; settings.tuningOffsetKHz = offset; settings.rfBandwidthMHz = bandwidth
            for index: Int64 in 0..<3 {
                let result = try engine.process(TVEngine.encode(picture,frameIndex: index),settings: settings)
                XCTAssertNotEqual(result.lock,.locked)
                XCTAssertTrue(result.frame.rgb.allSatisfy { $0.x.isFinite && $0.y.isFinite && $0.z.isFinite })
            }
        }
    }
}
