import XCTest
@testable import AnalogCore

final class RadioAdvancedTests: XCTestCase {
    private func tone(_ count: Int = 12_000, frequency: Double = 1000, amplitude: Double = 0.2) -> [Float] {
        (0..<count).map { Float(amplitude*sin(2 * Double.pi*frequency*Double($0)/48_000)) }
    }
    private func projection(_ i: [Float], _ q: [Float], frequency: Double, rate: Double, start: Int) -> Double {
        var re = 0.0, im = 0.0
        for n in start..<i.count {
            let phase = -2 * Double.pi*frequency*Double(n)/rate
            re += Double(i[n])*cos(phase)-Double(q[n])*sin(phase)
            im += Double(i[n])*sin(phase)+Double(q[n])*cos(phase)
        }
        return hypot(re, im)/Double(i.count-start)
    }
    func testSSBSidebandSuppressionAndRecovery() throws {
        let pcm = tone()
        for sideband in SSBSideband.allCases {
            var s = SSBSettings(); s.sideband = sideband
            var tx = try SSBTransmitter(settings: s), rx = try SSBReceiver(settings: s)
            let iq = try tx.transmit(pcm)
            let wanted = sideband == .usb ? 1000.0 : -1000.0
            let signal = projection(iq.i, iq.q, frequency: wanted, rate: iq.sampleRate, start: 4000)
            let image = projection(iq.i, iq.q, frequency: -wanted, rate: iq.sampleRate, start: 4000)
            XCTAssertGreaterThan(signal, 0.15)
            XCTAssertLessThan(image/signal, 0.01, "Opposite sideband must be at least 40 dB down")
            let output = try rx.receive(iq)
            let mse = (3000..<11_000).reduce(0.0) { $0+pow(Double(output[$1]-pcm[$1-544]),2) }/8000
            XCTAssertLessThan(mse, 0.0001)
            var wrong = s; wrong.sideband = sideband == .usb ? .lsb : .usb
            var wrongRX = try SSBReceiver(settings: wrong)
            let rejected = try wrongRX.receive(iq)
            XCTAssertLessThan(rejected.suffix(8000).reduce(0) { $0+$1*$1 }/8000, 0.00001)
        }
    }
    func testPMDirectPhaseAndUnwrappedRecovery() throws {
        var s = PMSettings(); s.phaseDeviationRadians = 4
        let pcm = tone(amplitude: 0.85)
        var tx = try PMTransmitter(settings: s), rx = try PMReceiver(settings: s)
        let iq = try tx.transmit(pcm)
        for n in stride(from: 5000, to: iq.i.count, by: 97) {
            XCTAssertEqual(iq.i[n]*iq.i[n]+iq.q[n]*iq.q[n], 1, accuracy: 1e-6)
        }
        XCTAssertTrue(iq.i.contains { $0 < -0.9 }, "Phase must cross pi for this test")
        let output = try rx.receive(iq)
        let mse = (4000..<11_000).reduce(0.0) { $0+pow(Double(output[$1]-pcm[$1-80]),2) }/7000
        XCTAssertLessThan(mse, 0.001)
    }
    func testCWKeyingAndBFO() throws {
        var tx = try CWTransmitter(), rx = try CWReceiver()
        let key = [Float](repeating: 1, count: 6000)+[Float](repeating: 0, count: 6000)
        let iq = try tx.transmit(key)
        XCTAssertLessThan(iq.i[0], 0.01)
        XCTAssertGreaterThan(iq.i[10_000], 0.99)
        XCTAssertLessThan(iq.i.last!, 1e-8)
        let output = try rx.receive(iq)
        let active = Array(output[2000..<5000])
        let zeros = [Float](repeating: 0, count: active.count)
        let amplitude = projection(active, zeros, frequency: 700, rate: 48_000, start: 0)
        XCTAssertGreaterThan(amplitude, 0.15)
        XCTAssertLessThan(projection(active, zeros, frequency: 1000, rate: 48_000, start: 0), amplitude*0.05)
        XCTAssertLessThan(output.suffix(2000).map { abs($0) }.max()!, 1e-4)
        XCTAssertThrowsError(try tx.transmit([-1]))
    }
    func testMorseTimingAndValidation() throws {
        let letters = try CWMorse.encode("EE")
        let words = try CWMorse.encode("E E")
        XCTAssertEqual(letters.count, 8*2880)
        XCTAssertEqual(words.count, 12*2880)
        XCTAssertTrue(letters.prefix(2880).allSatisfy { $0 == 1 })
        XCTAssertTrue(letters[2880..<11_520].allSatisfy { $0 == 0 })
        XCTAssertThrowsError(try CWMorse.encode("中文"))
        XCTAssertThrowsError(try CWMorse.encode("CQ", wordsPerMinute: .nan))
    }
    func testAllNewModesRemainContinuousAcrossBlocks() throws {
        for mode in [RadioMode.ssb, .cw, .pm] {
            var ssb = SSBSettings(), cw = CWSettings(), pm = PMSettings()
            ssb.noiseAmplitude = 0.01; cw.noiseAmplitude = 0.01; pm.noiseAmplitude = 0.01
            let pcm = mode == .cw ? (0..<4096).map { Float(($0/800)%2) } : tone(4096)
            var whole = try RadioEngine(mode: mode, ssb: ssb, cw: cw, pm: pm)
            var split = try RadioEngine(mode: mode, ssb: ssb, cw: cw, pm: pm)
            let expected = try whole.process(pcm)
            var actual: [Float] = []
            for start in stride(from: 0, to: pcm.count, by: 73) {
                actual += try split.process(Array(pcm[start..<min(pcm.count, start+73)]))
            }
            XCTAssertEqual(actual.count, expected.count)
            XCTAssertLessThan(zip(actual,expected).map { abs($0-$1) }.max() ?? 0, 0.0001, mode.rawValue)
        }
    }
    func testPartialIQBlocksMatchWholeReception() throws {
        let pcm = tone(1024)
        var ssbTX = try SSBTransmitter(), ssbWhole = try SSBReceiver(), ssbSplit = try SSBReceiver()
        var pmTX = try PMTransmitter(), pmWhole = try PMReceiver(), pmSplit = try PMReceiver()
        var cwTX = try CWTransmitter(), cwWhole = try CWReceiver(), cwSplit = try CWReceiver()
        let ssbIQ = try ssbTX.transmit(pcm), pmIQ = try pmTX.transmit(pcm)
        let cwIQ = try cwTX.transmit(pcm.map { $0 > 0 ? 1 : 0 })
        func blocks(_ iq: FMIQ) -> [FMIQ] {
            stride(from: 0, to: iq.i.count, by: 17).map { start in
                let end = min(iq.i.count, start+17)
                return FMIQ(sampleRate: iq.sampleRate, firstSampleIndex: Int64(start),
                    i: Array(iq.i[start..<end]), q: Array(iq.q[start..<end]))
            }
        }
        let expectedSSB = try ssbWhole.receive(ssbIQ), expectedPM = try pmWhole.receive(pmIQ), expectedCW = try cwWhole.receive(cwIQ)
        let actualSSB = try blocks(ssbIQ).flatMap { try ssbSplit.receive($0) }
        let actualPM = try blocks(pmIQ).flatMap { try pmSplit.receive($0) }
        let actualCW = try blocks(cwIQ).flatMap { try cwSplit.receive($0) }
        for (expected, actual) in [(expectedSSB,actualSSB),(expectedPM,actualPM),(expectedCW,actualCW)] {
            XCTAssertEqual(actual.count, expected.count)
            XCTAssertLessThan(zip(actual,expected).map { abs($0-$1) }.max() ?? 0, 1e-4)
        }
    }
    func testNewReceiverIQContractsAndInvalidSettings() throws {
        var ssb = try SSBReceiver(), cw = try CWReceiver(), pm = try PMReceiver()
        let bad = FMIQ(sampleRate: 96_000, firstSampleIndex: 1, i: [1], q: [0])
        XCTAssertThrowsError(try ssb.receive(bad)); XCTAssertThrowsError(try cw.receive(bad)); XCTAssertThrowsError(try pm.receive(bad))
        let corrupt = FMIQ(sampleRate: 96_000, firstSampleIndex: 0, i: [.nan], q: [0])
        XCTAssertThrowsError(try ssb.receive(corrupt)); XCTAssertThrowsError(try cw.receive(corrupt))
        XCTAssertEqual(try ssb.receive(FMIQ(sampleRate: 96_000, firstSampleIndex: 0, i: [0,0], q: [0,0])).count, 1)
        var a = SSBSettings(); a.audioBandwidthHz = 0
        var b = PMSettings(); b.phaseDeviationRadians = 9
        var c = CWSettings(); c.riseMilliseconds = 0
        XCTAssertThrowsError(try SSBEngine(settings: a)); XCTAssertThrowsError(try PMEngine(settings: b)); XCTAssertThrowsError(try CWEngine(settings: c))
    }
}
