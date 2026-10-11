import XCTest
@testable import AnalogCore

final class TVMobileOptimizationTests: XCTestCase {
    func testParallelTunerPreservesPhaseThroughDetuningChanges() throws {
        for system in TerrestrialSystem.allCases {
            var scalar = TVReceiverFrontEnd(system: system), parallel = scalar
            for (frame,offset) in [Float(20),-40,0,2_000,-2_000].enumerated() {
                let count = TVChannelClock(system: system,sampleRate: system.video.sampleRate).count(frame: Int64(frame))
                let signal = (0..<count).map { Float(0.5+0.2*sin(Double($0)*0.12)) }
                let input = TVChannelIQ(system: system,frameIndex: Int64(frame),
                    firstSampleIndex: system.video.sampleOffset(frame: Int64(frame)),
                    sampleRate: system.video.sampleRate,i: signal,q: signal.map { $0*0.3 })
                var settings = TerrestrialSettings(system: system); settings.tuningOffsetKHz = offset
                settings.execution = .reference
                let expected = try scalar.process(input,settings: settings)
                settings.execution = .accelerated
                let actual = try parallel.process(input,settings: settings)
                var maximum: Float = 0
                for n in actual.i.indices {
                    maximum = max(maximum,abs(actual.i[n]-expected.i[n]),abs(actual.q[n]-expected.q[n]))
                }
                XCTAssertLessThan(maximum,0.000005,"\(system) frame \(frame) offset \(offset)")
            }
        }
    }
}
