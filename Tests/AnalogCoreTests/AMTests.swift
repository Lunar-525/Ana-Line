import XCTest
@testable import AnalogCore

final class AMTests: XCTestCase {
    func testEnvelopeAndToneRoundTrip() throws {
        let pcm = (0..<9600).map { Float(0.3*sin(2 * Double.pi*1000*Double($0)/48_000)) }
        var tx = try AMTransmitter(), rx = try AMReceiver()
        let iq = try tx.transmit(pcm)
        XCTAssertEqual(iq.i.count, pcm.count*2)
        XCTAssertTrue(iq.q.allSatisfy { $0 == 0 })
        XCTAssertTrue(iq.i.allSatisfy { $0 >= 0 && $0 <= 2 })
        let output = try rx.receive(iq)
        XCTAssertEqual(output.count, pcm.count)
        let mse = (4000..<9000).reduce(0.0) { $0+pow(Double(output[$1]-pcm[$1-96]),2) }/5000
        XCTAssertLessThan(mse, 0.0002)
    }
    func testArbitraryBlocksAndNoiseContinuity() throws {
        var s = AMSettings(); s.noiseAmplitude = 0.03
        let pcm = (0..<2048).map { Float(0.2*sin(Double($0)*0.05)) }
        var whole = try AMEngine(settings: s), split = try AMEngine(settings: s)
        let expected = try whole.process(pcm)
        var actual: [Float] = []
        for start in stride(from: 0, to: pcm.count, by: 37) {
            actual += try split.process(Array(pcm[start..<min(pcm.count, start+37)]))
        }
        XCTAssertEqual(actual.count, expected.count)
        XCTAssertLessThan(zip(actual,expected).map { abs($0-$1) }.max() ?? 0, 1e-5)
    }
    func testReceiverIQContinuityAndValidation() throws {
        var tx = try AMTransmitter(), rx = try AMReceiver()
        XCTAssertThrowsError(try tx.transmit([.infinity]))
        let iq = try tx.transmit([0, 0.1, -0.1])
        var output: [Float] = []
        for n in iq.i.indices {
            output += try rx.receive(FMIQ(sampleRate: iq.sampleRate, firstSampleIndex: Int64(n), i: [iq.i[n]], q: [iq.q[n]]))
        }
        XCTAssertEqual(output.count, 3)
        XCTAssertThrowsError(try rx.receive(iq))
        var s = AMSettings(); s.modulationIndex = 1.1
        XCTAssertThrowsError(try AMEngine(settings: s))
    }
    func testLimiterAndSilence() throws {
        var tx = try AMTransmitter()
        let iq = try tx.transmit([Float](repeating: 4, count: 2048))
        XCTAssertTrue(tx.limited)
        XCTAssertTrue(iq.i.allSatisfy { $0 >= 0 && $0 <= 2 })
        var engine = try AMEngine()
        let output = try engine.process([Float](repeating: 0, count: 9600))
        XCTAssertLessThan(output.suffix(2000).map { abs($0) }.max() ?? 0, 1e-4)
    }
    func testStreamingThroughput() throws {
        #if DEBUG
        throw XCTSkip("Measure production DSP with -c release")
        #else
        let pcm = (0..<2048).map { Float(0.1*sin(Double($0)*0.1)) }
        for mode in RadioMode.allCases {
            var engine = try RadioEngine(mode: mode)
            let input = mode == .cw ? pcm.map { $0 > 0 ? Float(1) : Float(0) } : pcm
            _ = try engine.process(input)
            let clock = ContinuousClock.now
            for _ in 0..<30 { _ = try engine.process(input) }
            let d = clock.duration(to: .now).components
            let mean = (Double(d.seconds)+Double(d.attoseconds)/1e18)/30
            print("RADIO_REALTIME \(mode.rawValue): \(mean*1000) ms / 42.67 ms")
            XCTAssertLessThan(mean, Double(pcm.count)/48_000)
        }
        #endif
    }
}
