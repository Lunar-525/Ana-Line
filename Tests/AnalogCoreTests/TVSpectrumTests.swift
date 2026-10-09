import XCTest
@testable import AnalogCore

final class TVSpectrumTests: XCTestCase {
    func testComplexToneFrequencySignAndPowerNormalization() throws {
        let size = 2048, rate = 16_384_000.0
        let analyzer = TVSpectrumAnalyzer()
        for bin in [-137, 0, 271] {
            let phase = (0..<size*8).map { 2 * Double.pi * Double(bin*$0)/Double(size) }
            let i = phase.map { Float(0.25*cos($0)) }, q = phase.map { Float(0.25*sin($0)) }
            let spectrum = try XCTUnwrap(analyzer.analyze(i: i, q: q, rate: rate))
            let peak = try XCTUnwrap(spectrum.powerDB.indices.max { spectrum.powerDB[$0] < spectrum.powerDB[$1] })
            XCTAssertEqual(peak, size/2+bin)
            let integrated = spectrum.powerDB.reduce(Double(0)) { $0 + pow(10,Double($1)/10) }
            XCTAssertEqual(integrated, 0.0625, accuracy: 0.000001)
            XCTAssertEqual(spectrum.resolutionHz, 12_000)
        }
    }
    func testSilentTapIsFiniteAndShortInputsAreRejected() throws {
        let analyzer = TVSpectrumAnalyzer(log2Size: 9)
        let zero = [Float](repeating: 0,count: 512)
        let spectrum = try XCTUnwrap(analyzer.analyze(i: zero,q: zero,rate: 384_000,centerHz: 6_500_000))
        XCTAssertTrue(spectrum.powerDB.allSatisfy { $0 == -120 })
        XCTAssertEqual(spectrum.centerHz, 6_500_000)
        XCTAssertNil(analyzer.analyze(i: [0],q: [0],rate: 384_000))
    }
    func testSoundTapTracksAttenuationAndCommonFrontEndBandwidth() throws {
        var settings = TerrestrialSettings(system: .palDK)
        settings.carrierToNoiseDB = 120
        let pcm = [Float](repeating: 0, count: TVSoundClock.count(frame: 0,standard: .pal))
        func power(_ settings: TerrestrialSettings) throws -> Double {
            var engine = TerrestrialSoundEngine(system: .palDK)
            let result = try engine.process(pcm,frameIndex: 0,settings: settings)
            let spectrum = try XCTUnwrap(result.spectrum)
            XCTAssertEqual(spectrum.centerHz,6_500_000)
            return 10*log10(spectrum.powerDB.reduce(Double(0)) { $0 + pow(10,Double($1)/10) })
        }
        let strong = try power(settings)
        settings.signalDB = -20
        XCTAssertEqual(strong - (try power(settings)),20,accuracy: 0.01)
        settings.signalDB = 0; settings.rfBandwidthMHz = 1
        XCTAssertLessThan(try power(settings),strong-40,
            "FM waterfall must measure the actual shared front-end rejection")
    }
    func testMeasuredVisionSpectrumRespondsToTuningAndSignalLevel() throws {
        let standard = TVStandard.ntsc
        let samples = Int(standard.sampleOffset(frame: 1))
        let rf = TelevisionRF(system: .ntscM, frameIndex: 0, sampleRate: standard.sampleRate,
            i: .init(repeating: 0.5,count: samples),q: .init(repeating: 0,count: samples))
        var settings = TerrestrialSettings(system: .ntscM)
        settings.tuningOffsetKHz = 100
        var receiver = TerrestrialReceiver(system: .ntscM)
        let strong = try XCTUnwrap(receiver.receive(rf, settings: settings).visionSpectrum)
        let peak = try XCTUnwrap(strong.powerDB.indices.max { strong.powerDB[$0] < strong.powerDB[$1] })
        let frequency = Double(peak-strong.powerDB.count/2)*strong.binHz
        XCTAssertEqual(frequency, -100_000, accuracy: strong.binHz)
        var weaker = rf; weaker.i = weaker.i.map { $0*0.1 }
        var weakReceiver = TerrestrialReceiver(system: .ntscM)
        let weak = try XCTUnwrap(weakReceiver.receive(weaker,settings: settings).visionSpectrum)
        XCTAssertEqual(strong.powerDB[peak]-weak.powerDB[peak],20,accuracy: 0.01,
            "AGC must not normalize the waterfall tap")
    }
}
