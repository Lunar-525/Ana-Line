import XCTest
@testable import AnalogCore

final class FMTests: XCTestCase {
    func testToneRoundTripAndConstantEnvelope() throws {
        var s = FMSettings(); s.emphasisSeconds = 0
        let pcm = (0..<9600).map { Float(0.2*sin(2 * Double.pi*1000*Double($0)/48_000)) }
        var tx = try FMTransmitter(settings: s), rx = try FMReceiver(settings: s)
        let iq = try tx.transmit(pcm)
        XCTAssertEqual(iq.i.count, pcm.count*8)
        for n in stride(from: 0, to: iq.i.count, by: 97) {
            XCTAssertEqual(iq.i[n]*iq.i[n]+iq.q[n]*iq.q[n], 1, accuracy: 1e-6)
        }
        let output = try rx.receive(iq)
        XCTAssertEqual(output.count, pcm.count)
        // 32 audio samples source FIR + 16 resampler + 8 IF + 16 audio FIR.
        let delay = 72
        let mse = (1000..<9000).reduce(0.0) { $0 + pow(Double(output[$1]-pcm[$1-delay]), 2) }/8000
        XCTAssertLessThan(mse, 0.0001)
    }
    func testIrregularBlocksMatchWholeStream() throws {
        let pcm = (0..<2048).map { Float(0.1*sin(Double($0)*0.05)) }
        var whole = try FMEngine(), split = try FMEngine()
        let reference = try whole.process(pcm)
        var output: [Float] = []
        for start in stride(from: 0, to: pcm.count, by: 73) {
            output += try split.process(Array(pcm[start..<min(start+73,pcm.count)]))
        }
        XCTAssertEqual(output.count, reference.count)
        let maximumError = zip(output, reference).map { abs($0-$1) }.max() ?? 0
        XCTAssertLessThan(maximumError, 1e-5)
    }
    func testReceiverAcceptsPartialAudioCells() throws {
        var tx = try FMTransmitter()
        let iq = try tx.transmit((0..<512).map { Float(0.05*sin(Double($0)*0.1)) })
        var whole = try FMReceiver(), split = try FMReceiver()
        let reference = try whole.receive(iq)
        var output: [Float] = []
        for start in stride(from: 0, to: iq.i.count, by: 13) {
            let end = min(start+13, iq.i.count)
            output += try split.receive(FMIQ(sampleRate: iq.sampleRate, firstSampleIndex: Int64(start),
                i: Array(iq.i[start..<end]), q: Array(iq.q[start..<end])))
        }
        XCTAssertEqual(output.count, reference.count)
        XCTAssertLessThan(zip(output, reference).map { abs($0-$1) }.max() ?? 0, 1e-5)
    }
    func testNoiseIsRepeatableAndTuningChangesReception() throws {
        var s = FMSettings(); s.emphasisSeconds = 0; s.noiseAmplitude = 0.1
        let pcm = [Float](repeating: 0, count: 2048)
        var a = try FMEngine(settings: s, seed: 9), b = try FMEngine(settings: s, seed: 9)
        let noisy = try a.process(pcm)
        XCTAssertEqual(noisy, try b.process(pcm))
        XCTAssertGreaterThan(noisy.suffix(1000).reduce(0) { $0 + $1*$1 }, 0)
        s.noiseAmplitude = 0; s.tuningOffsetHz = 5000
        var tuned = try FMEngine(settings: s)
        let output = try tuned.process(pcm)
        let mean = output.suffix(1000).reduce(0,+)/1000
        XCTAssertEqual(mean, Float(-5000/75000.0), accuracy: 0.001)
    }
    func testValidationAndContinuity() throws {
        var s = FMSettings(); s.deviationHz = .nan
        XCTAssertThrowsError(try FMEngine(settings: s))
        var tx = try FMTransmitter(), rx = try FMReceiver()
        XCTAssertThrowsError(try tx.transmit([.nan]))
        let iq = try tx.transmit([0,0,0])
        var bad = iq; bad.q.removeLast()
        XCTAssertThrowsError(try rx.receive(bad))
        XCTAssertEqual(try rx.receive(iq).count, 3)
        XCTAssertThrowsError(try rx.receive(iq))
        XCTAssertEqual(try tx.transmit([]).i.count, 0)
    }
}
