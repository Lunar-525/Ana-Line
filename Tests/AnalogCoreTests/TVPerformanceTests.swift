import XCTest
import AnalogCore

/// Diagnostic benchmark, with no machine-dependent speed assertions.
final class TVPerformanceTests: XCTestCase {
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
                    stages.append([encode,t.modulation,t.channel,t.tuner,t.carrier,t.synchronization,t.videoDecode])
                }
            }
            let names = ["CVBS encode","VSB","RF channel","Tuner / IF","Carrier / PLL","AGC / sync","CVBS decode"]
            var row: [String:Any] = ["system":system.rawValue]
            var total = 0.0
            for stage in names.indices {
                let mean = stages.map { $0[stage] }.reduce(0,+)/Double(stages.count)*1000
                row[names[stage]] = mean; total += mean
            }
            row["total_ms"] = total; row["fps"] = 1000/total
            report.append(row)
            print("TV benchmark",system.rawValue,row)
        }
        let output = try JSONSerialization.data(withJSONObject: report,options: [.prettyPrinted,.sortedKeys])
        try output.write(to: URL(fileURLWithPath:"/private/tmp/Terrestrial-benchmark.json"))
    }
}
