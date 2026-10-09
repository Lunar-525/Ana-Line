import XCTest
@testable import AnalogCore

/// Diagnostic benchmark, with no machine-dependent speed assertions.
final class TVPerformanceTests: XCTestCase {
    func testParallelCVBSMatchesScalarReferenceIncludingPALDelayAndComb() throws {
        for standard in TVStandard.allCases {
            var picture = TVFrame.colorBars(standard)
            // Add row-dependent detail, so this also checks the PAL delay line's
            // field order, rather than repeating identical rows everywhere.
            for row in 0..<standard.height {
                for x in 0..<standard.width {
                    picture.rgb[row*standard.width+x] *= 0.65 + Float(row%11)/32
                }
            }
            let scalar = try TVEngine.encode(picture,frameIndex: 1,execution: .reference)
            let parallel = try TVEngine.encode(picture,frameIndex: 1)
            XCTAssertLessThan(zip(scalar.samples,parallel.samples).map { abs($0-$1) }.max() ?? 0,0.000002)
            var channel = TVChannelSettings(); channel.noise = 0.01
            let signal = try TVEngine.channel(scalar,settings: channel)
            for separation in [TVSeparation.notch,.comb] {
                var settings = TVDecoderSettings(); settings.separation = separation
                let reference = try TVEngine.decode(signal,settings: settings,execution: .reference)
                let accelerated = try TVEngine.decode(signal,settings: settings)
                XCTAssertEqual(reference.recoveredLines,accelerated.recoveredLines)
                XCTAssertEqual(reference.colorLockedLines,accelerated.colorLockedLines)
                var maximum: Float = 0
                for (a,b) in zip(reference.frame.rgb,accelerated.frame.rgb) {
                    for c in 0..<3 { maximum = max(maximum,abs(a[c]-b[c])) }
                }
                XCTAssertLessThan(maximum,0.00001,"\(standard) / \(separation)")
            }
        }
    }

    func testAcceleratedReceiverMatchesReferenceAcrossConsecutiveFrames() throws {
        for system in TerrestrialSystem.allCases {
            var referenceEngine = TerrestrialEngine(system: system)
            var acceleratedEngine = TerrestrialEngine(system: system)
            var settings = TerrestrialSettings(system: system)
            settings.echoGain = 0.15; settings.echoDelayMicroseconds = 4.3
            settings.echoPhaseDegrees = 30; settings.tuningOffsetKHz = 20
            let picture = TVFrame.colorBars(system.video)
            for index: Int64 in 0..<4 {
                let signal = try TVEngine.encode(picture,frameIndex: index)
                settings.execution = .reference
                let reference = try referenceEngine.process(signal,settings: settings)
                settings.execution = .accelerated
                let accelerated = try acceleratedEngine.process(signal,settings: settings)
                XCTAssertEqual(reference.lock,accelerated.lock)
                XCTAssertEqual(reference.recoveredLines,accelerated.recoveredLines)
                XCTAssertEqual(reference.colorLockedLines,accelerated.colorLockedLines)
                XCTAssertEqual(reference.agcDB,accelerated.agcDB,accuracy: 0.001)
                XCTAssertEqual(reference.carrierErrorHz,accelerated.carrierErrorHz,accuracy: 0.1)
                var maximum: Float = 0
                for (a,b) in zip(reference.frame.rgb,accelerated.frame.rgb) {
                    for c in 0..<3 { maximum = max(maximum,abs(a[c]-b[c])) }
                }
                XCTAssertLessThan(maximum,0.00005,"\(system) frame \(index)")
            }
        }
    }

    func testContinuousTerrestrialStageTimings() throws {
        var report = [[String: Any]]()
        for system in TerrestrialSystem.allCases {
            var engine = TerrestrialEngine(system: system)
            var settings = TerrestrialSettings(system: system)
            settings.echoGain = 0.15; settings.echoDelayMicroseconds = 4.3
            settings.echoPhaseDegrees = 30; settings.tuningOffsetKHz = 20
            let picture = TVFrame.colorBars(system.video)
            var stages = [[Double]]()
            for index: Int64 in 0..<10 {
                let start = ContinuousClock.now
                let cvbs = try TVEngine.encode(picture,frameIndex: index)
                let encoded = ContinuousClock.now
                let reception = try engine.process(cvbs,settings: settings)
                XCTAssertEqual(reception.lock,.locked,"\(system) frame \(index)")
                if index >= 2 {
                    let c = start.duration(to: encoded).components
                    let encode = Double(c.seconds)+Double(c.attoseconds)/1e18
                    let t = reception.timings
                    stages.append([encode,t.modulation,t.channel,t.tuner,t.carrier,t.synchronization,t.videoDecode,t.carrierEstimation,t.carrierPLL])
                }
            }
            let names = ["CVBS encode","VSB","RF channel","Tuner / IF","Carrier / PLL","AGC / sync","CVBS decode","AFC (included)","PLL (included)"]
            var row: [String:Any] = ["system":system.rawValue]
            var total = 0.0
            for stage in names.indices {
                let mean = stages.map { $0[stage] }.reduce(0,+)/Double(stages.count)*1000
                row[names[stage]] = mean
                if stage < 7 { total += mean }
            }
            row["total_ms"] = total; row["fps"] = 1000/total
            report.append(row)
            print("TV benchmark",system.rawValue,row)
        }
        let output = try JSONSerialization.data(withJSONObject: report,options: [.prettyPrinted,.sortedKeys])
        try output.write(to: URL(fileURLWithPath:"/private/tmp/Terrestrial-benchmark.json"))
    }

    func testVectorCarrierPreservesReferenceDuringLossAndReacquisition() throws {
        for system in TerrestrialSystem.allCases {
            var referenceEngine = TerrestrialEngine(system: system), acceleratedEngine = TerrestrialEngine(system: system)
            let picture = TVFrame.colorBars(system.video)
            for frame: Int64 in 0..<7 {
                var settings = TerrestrialSettings(system: system)
                if frame == 1 || frame == 2 {
                    settings.signalDB = -15; settings.carrierToNoiseDB = 30
                    settings.echoGain = 0.4; settings.echoDelayMicroseconds = 7.8
                    settings.echoPhaseDegrees = -85; settings.tuningOffsetKHz = -40
                }
                if frame == 3 || frame == 4 { settings.signalDB = -80; settings.carrierToNoiseDB = 10 }
                let signal = try TVEngine.encode(picture,frameIndex: frame)
                settings.execution = .reference
                let reference = try referenceEngine.process(signal,settings: settings)
                settings.execution = .accelerated
                let accelerated = try acceleratedEngine.process(signal,settings: settings)
                XCTAssertEqual(reference.lock,accelerated.lock)
                XCTAssertEqual(reference.synchronization,accelerated.synchronization)
                XCTAssertEqual(reference.recoveredLines,accelerated.recoveredLines)
                XCTAssertEqual(reference.colorLockedLines,accelerated.colorLockedLines)
                XCTAssertEqual(reference.agcDB,accelerated.agcDB,accuracy: 0.001)
                XCTAssertEqual(reference.carrierErrorHz,accelerated.carrierErrorHz,accuracy: 0.1)
                var error: Float = 0
                for (a,b) in zip(reference.frame.rgb,accelerated.frame.rgb) {
                    for c in 0..<3 { error = max(error,abs(a[c]-b[c])) }
                }
                XCTAssertLessThan(error,0.00005,"\(system), frame \(frame)")
            }
        }
    }
}
