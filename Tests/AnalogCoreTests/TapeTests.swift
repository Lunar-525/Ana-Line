import XCTest
@testable import AnalogCore

final class TapeTests: XCTestCase {
    private func run(_ processor: TapeProcessor,_ left: [Float],_ right: [Float]? = nil) -> ([Float],[Float]) {
        let right = right ?? left
        var l = [Float](repeating: 0,count: left.count), r = l
        left.withUnsafeBufferPointer { a in right.withUnsafeBufferPointer { b in
            l.withUnsafeMutableBufferPointer { c in r.withUnsafeMutableBufferPointer { d in
                processor.process(left: a.baseAddress!,right: b.baseAddress!,outputLeft: c.baseAddress!,outputRight: d.baseAddress!,count: left.count)
            } }
        } }
        return (l,r)
    }
    private func configured(hiss: Bool = false) throws -> TapeProcessor {
        let p = try TapeProcessor(); var settings = TapeSettings(); settings.hiss = hiss
        p.configure(settings); p.reset(); return p
    }
    private func harmonic(_ samples: [Float],frequency: Double) -> Double {
        let start=samples.count/2, count=samples.count-start
        var real=0.0,imaginary=0.0
        for n in start..<samples.count {
            let phase=2*Double.pi*frequency*Double(n)/48_000
            real += Double(samples[n])*cos(phase); imaginary += Double(samples[n])*sin(phase)
        }
        return 2*hypot(real,imaginary)/Double(count)
    }
    func testCHFReferenceDistortionSensitivityAndNoise() throws {
        let amplitude=pow(10,-18.0/20), count=24000
        let tone=(0..<count).map { Float(amplitude*sin(2*Double.pi*400*Double($0)/48_000)) }
        let (output,_)=run(try configured(),tone)
        let fundamental=harmonic(output,frequency: 400)
        let distortion=sqrt((2...7).reduce(0.0) { $0+pow(harmonic(output,frequency: Double($1)*400),2) })/fundamental*100
        // A nominal input Dolby-level sine, not a claim of a fitted entire MOL curve.
        XCTAssertEqual(distortion,1.5,accuracy: 0.2)
        let quiet=tone.map { $0*0.1 }
        let (quietOutput,_)=run(try configured(),quiet)
        let sensitivity=20*log10(harmonic(quietOutput,frequency: 400)/(amplitude*0.1))
        XCTAssertEqual(sensitivity,-0.8,accuracy: 0.15)
        let (noise,_)=run(try configured(hiss: true),[Float](repeating: 0,count: count))
        let rms=sqrt(noise.suffix(count/2).reduce(0.0) { $0+Double($1)*Double($1) }/Double(count/2))
        let noiseDB=20*log10(rms/(amplitude/sqrt(2)))
        XCTAssertEqual(noiseDB,-47.6,accuracy: 0.3)
        print("CHF_REFERENCE thd=\(distortion)% sensitivity=\(sensitivity)dB noise=\(noiseDB)dB")
    }
    func testIrregularBlocksPreserveStateAndStereo() throws {
        let input=(0..<5000).map { Float(0.2*sin(Double($0)*0.097)) }
        let silent=[Float](repeating: 0,count: input.count)
        let (expected,right)=run(try configured(),input,silent)
        XCTAssertEqual(right.map(abs).max(),0)
        let split=try configured(); var actual=[Float]()
        for start in stride(from: 0,to: input.count,by: 73) {
            actual += run(split,Array(input[start..<min(start+73,input.count)])).0
        }
        XCTAssertEqual(actual,expected)
    }
    func testBypassResetAndHostileInputStayFinite() throws {
        let p=try configured(); var settings=TapeSettings(); settings.bypass=true; settings.hiss=false
        p.configure(settings); p.reset()
        let input: [Float]=[0,0.1,-0.3,0.9]
        XCTAssertEqual(run(p,input).0,input)
        settings.bypass=false; settings.recordDB=18; p.configure(settings)
        let hostile: [Float]=[.nan,.infinity,-.infinity,Float.greatestFiniteMagnitude,-Float.greatestFiniteMagnitude]
        let (output,_)=run(p,Array(repeating: hostile,count: 1000).flatMap { $0 })
        XCTAssertTrue(output.allSatisfy(\.isFinite))
        p.configure(TapeSettings()); p.reset()
        XCTAssertEqual(run(p,input).0,run(try configured(hiss: true),input).0)
        XCTAssertThrowsError(try TapeProcessor(sampleRate: 0))
    }
    func testReferenceHeadroomAndSaturation() throws {
        var levels=[Double]()
        for db in [-12.0,0.0,12.0] {
            let amplitude=pow(10,(-18+db)/20)
            let input=(0..<24000).map { Float(amplitude*sin(2*Double.pi*400*Double($0)/48_000)) }
            let output=run(try configured(),input).0
            levels.append(20*log10(harmonic(output,frequency: 400)))
        }
        XCTAssertGreaterThan(levels[1],levels[0])
        XCTAssertGreaterThan(levels[2],levels[1])
        XCTAssertLessThan(levels[2]-levels[1],9)
    }
    func testIndependentStereoRecordLevel() throws {
        let processor=try TapeProcessor()
        var settings=TapeSettings(); settings.hiss=false; settings.recordRightDB = -12
        processor.configure(settings); processor.reset()
        let tone=(0..<24000).map { Float(0.01*sin(2*Double.pi*400*Double($0)/48_000)) }
        let (left,right)=run(processor,tone)
        let balance=20*log10(harmonic(right,frequency: 400)/harmonic(left,frequency: 400))
        XCTAssertEqual(balance,-12,accuracy: 0.2)
    }
    func testHealthReducesTrebleAndIncreasesTapeNoise() throws {
        func render(head: Double, tape: Double, hiss: Bool, input: [Float]) throws -> [Float] {
            let processor = try TapeProcessor()
            var settings = TapeSettings()
            settings.headHealth = head; settings.tapeHealth = tape; settings.hiss = hiss
            processor.configure(settings); processor.reset()
            return run(processor, input).0
        }
        let tone = (0..<24000).map { Float(0.01*sin(2*Double.pi*8000*Double($0)/48_000)) }
        let healthy = try render(head: 1, tape: 1, hiss: false, input: tone)
        for (head, tape) in [(0.0, 1.0), (1.0, 0.0)] {
            let worn = try render(head: head, tape: tape, hiss: false, input: tone)
            XCTAssertLessThan(harmonic(worn, frequency: 8000), harmonic(healthy, frequency: 8000)*0.6)
            XCTAssertTrue(worn.allSatisfy(\.isFinite))
        }
        let silence = [Float](repeating: 0, count: 24000)
        let normalNoise = try render(head: 1, tape: 1, hiss: true, input: silence)
        let wornNoise = try render(head: 1, tape: 0, hiss: true, input: silence)
        func energy(_ samples: [Float]) -> Double {
            samples.suffix(12000).reduce(0) { $0 + Double($1)*Double($1) }
        }
        XCTAssertGreaterThan(energy(wornNoise), energy(normalNoise)*10)
        XCTAssertEqual(try render(head: .nan, tape: .infinity, hiss: false, input: tone), healthy)
        XCTAssertEqual(try render(head: -1, tape: 2, hiss: false, input: tone),
                       try render(head: 0, tape: 1, hiss: false, input: tone))
    }

    func testReleaseThroughputReport() throws {
        let p=try configured()
        let input=(0..<48000).map { Float(0.12*sin(Double($0)*0.13)) }
        let start=ContinuousClock.now
        _=run(p,input)
        print("TAPE_ONE_SECOND_PROCESSING \(start.duration(to: .now))")
    }
}
