import XCTest
@testable import AnalogCore

final class TVChannelTests: XCTestCase {
    // MARK: - Unified clock

    func testChannelClockTracksFrameBoundariesWithoutDrift() {
        for system in TerrestrialSystem.allCases {
            let clock = TVChannelClock(system: system, sampleRate: system.video.sampleRate)
            var position: Int64 = 0
            for frame: Int64 in 0..<2_000 {
                XCTAssertEqual(clock.offset(frame: frame), position)
                position += Int64(clock.count(frame: frame))
            }
            XCTAssertEqual(clock.offset(frame: 2_000), position)
            for frame: Int64 in 0..<50 {
                XCTAssertEqual(clock.offset(frame: frame), system.video.sampleOffset(frame: frame),
                               "The 4fsc channel grid must match the video clock")
            }
            XCTAssertTrue(clock.isVisionGrid)
        }
    }

    func testChannelClockTimeMappingRoundTrips() {
        let clock = TVChannelClock(system: .palDK, sampleRate: 8_000_000)
        for frame: Int64 in [0, 1, 25, 1_000, 100_000] {
            let start = clock.offset(frame: frame)
            XCTAssertEqual(clock.sampleIndex(time: clock.time(sampleIndex: start)), start)
        }
    }

    // MARK: - Resampler

    func testInvalidChannelRatesThrowBeforeClockConversion() {
        for rate in [Double.nan, .infinity, -.infinity, 0, -1, Double.greatestFiniteMagnitude] {
            let input = TVChannelIQ(system: .palDK,frameIndex: 0,firstSampleIndex: 0,sampleRate: rate,i: [],q: [])
            XCTAssertThrowsError(try input.validate())
        }
    }

    func testCombinerRejectsMismatchedSoundBeforeResampling() throws {
        let system = TerrestrialSystem.palDK
        let cvbs = try TVEngine.encode(TVFrame.colorBars(system.video))
        var modulator = VSBModulator(system: system)
        let vision = try modulator.modulate(cvbs)
        var combiner = TVChannelModulator(system: system)
        for sound in [
            TVSoundIQ(system: system,frameIndex: 0,sampleRate: .nan,i: [],q: []),
            TVSoundIQ(system: system,frameIndex: 0,sampleRate: 384_000,i: [1],q: []),
            TVSoundIQ(system: .ntscM,frameIndex: 0,sampleRate: 384_000,i: [],q: [])
        ] {
            XCTAssertThrowsError(try combiner.combine(vision: vision,sound: sound))
        }
    }

    private func tone(_ rate: Double, _ hz: Double, _ count: Int) -> ([Float],[Float]) {
        var i = [Float](repeating: 0, count: count), q = i
        for n in 0..<count {
            let phase = 2*Double.pi*hz*Double(n)/rate
            i[n] = Float(cos(phase)); q[n] = Float(sin(phase))
        }
        return (i,q)
    }

    private func correlation(_ i: [Float], _ q: [Float], rate: Double, hz: Double,
                             range: Range<Int>) -> Double {
        var re = 0.0, im = 0.0
        for n in range {
            let phase = 2*Double.pi*hz*Double(n)/rate
            let c = cos(phase), s = sin(phase)
            re += Double(i[n])*c+Double(q[n])*s
            im += Double(q[n])*c-Double(i[n])*s
        }
        return hypot(re,im)/Double(range.count)
    }

    func testComplexResamplerPreservesToneAndRejectsImages() {
        let inputRate = 48_000.0, outputRate = 192_000.0, hz = 3_000.0
        let (i,q) = tone(inputRate,hz,4_096)
        var resampler = TVComplexResampler(inputRate: inputRate, outputRate: outputRate, radius: 8)
        let (oi,oq) = resampler.process(i: i,q: q,inputStart: 0,outputStart: 0,outputCount: 16_384)
        let range = 8_192..<16_384
        let recovered = correlation(oi,oq,rate: outputRate,hz: hz,range: range)
        let image = correlation(oi,oq,rate: outputRate,hz: inputRate-hz,range: range)
        print("resampler tone",recovered,"image",image)
        XCTAssertEqual(recovered,1,accuracy: 0.02)
        XCTAssertLessThan(image,0.05)
    }

    func testComplexResamplerRejectsDecimationAlias() {
        let inputRate = 192_000.0, outputRate = 48_000.0
        var inband = TVComplexResampler(inputRate: inputRate, outputRate: outputRate, radius: 12)
        var alias = TVComplexResampler(inputRate: inputRate, outputRate: outputRate, radius: 12)
        let (pi,pq) = tone(inputRate,3_000,16_384)
        let (ai,aq) = tone(inputRate,57_600,16_384)
        let (oi,oq) = inband.process(i: pi,q: pq,inputStart: 0,outputStart: 0,outputCount: 4_096)
        let (bi,bq) = alias.process(i: ai,q: aq,inputStart: 0,outputStart: 0,outputCount: 4_096)
        let passed = correlation(oi,oq,rate: outputRate,hz: 3_000,range: 2_048..<4_096)
        var aliasPower = 0.0
        for n in 2_048..<4_096 { aliasPower += Double(bi[n]*bi[n]+bq[n]*bq[n]) }
        let aliasRMS = sqrt(aliasPower/2_048)
        print("decimation pass",passed,"alias RMS",aliasRMS)
        XCTAssertEqual(passed,1,accuracy: 0.02)
        XCTAssertLessThan(aliasRMS,0.1)
    }

    func testComplexResamplerSplicesBlocksWithoutASeam() {
        let rate = 48_000.0, hz = 1_000.0, total = 8_192
        let (i,q) = tone(rate,hz,total)
        var oneShot = TVComplexResampler(inputRate: rate, outputRate: rate, radius: 8)
        let (fi,fq) = oneShot.process(i: i,q: q,inputStart: 0,outputStart: 0,outputCount: total)
        var split = TVComplexResampler(inputRate: rate, outputRate: rate, radius: 8)
        let (a,ab) = split.process(i: Array(i[0..<4_096]),q: Array(q[0..<4_096]),inputStart: 0,outputStart: 0,outputCount: 4_096)
        let (b,bb) = split.process(i: Array(i[4_096..<total]),q: Array(q[4_096..<total]),inputStart: 4_096,outputStart: 4_096,outputCount: 4_096)
        let splitI = a+b, splitQ = ab+bb
        var maximum = 0.0
        for n in 0..<total { maximum = max(maximum,Double(abs(fi[n]-splitI[n])),Double(abs(fq[n]-splitQ[n]))) }
        print("splice max difference",maximum)
        XCTAssertLessThan(maximum,1e-5)
    }

    // MARK: - Linear combining

    private func power(_ spectrum: TVSpectrum, at hz: Double) -> Float {
        let size = spectrum.powerDB.count
        let index = Int((Double(size)/2+hz/spectrum.binHz).rounded())
        return spectrum.powerDB[max(0,min(size-1,index))]
    }

    func testChannelModulatorPlacesBothRealCarriers() throws {
        for system in TerrestrialSystem.allCases {
            let settings = TerrestrialSettings(system: system)
            let frameCount = TVSoundClock.count(frame: 0,standard: system.video)
            var pcm = [Float](repeating: 0, count: frameCount)
            for n in 0..<frameCount {
                pcm[n] = Float(0.25*sin(2*Double.pi*1_000*Double(n)/48_000))
            }
            var modulator = TVSoundModulator(system: system)
            let sound = modulator.modulate(pcm,frameIndex: 0,settings: settings,rate: 384_000)
            let visionCount = Int(system.video.sampleOffset(frame: 1)-system.video.sampleOffset(frame: 0))
            let vision = TelevisionRF(system: system,frameIndex: 0,sampleRate: system.video.sampleRate,
                                      i: [Float](repeating: 1,count: visionCount),
                                      q: [Float](repeating: 0,count: visionCount))
            var channel = TVChannelModulator(system: system)
            let combined = try channel.combine(vision: vision,sound: sound)
            XCTAssertEqual(combined.count,visionCount)
            XCTAssertEqual(combined.firstSampleIndex,system.video.sampleOffset(frame: 0))
            let analyzer = TVSpectrumAnalyzer(log2Size: 11)
            let spectrum = try XCTUnwrap(analyzer.analyze(i: combined.i,q: combined.q,rate: combined.sampleRate))
            let visionDB = power(spectrum,at: 0)
            let soundDB = power(spectrum,at: system.soundCarrierHz)
            let gapDB = power(spectrum,at: system.soundCarrierHz/2)
            print("combined",system,"vision",visionDB,"sound",soundDB,"gap",gapDB)
            XCTAssertGreaterThan(visionDB,-30,"Vision carrier must remain at 0 Hz")
            XCTAssertGreaterThan(soundDB,visionDB-40,"Sound carrier must appear at its real offset")
            XCTAssertLessThan(gapDB,soundDB-20,"Energy must be concentrated on the two carriers")
        }
    }

    func testChannelModulatorWithoutSoundLeavesVisionUntouched() throws {
        let system = TerrestrialSystem.palDK
        let count = Int(system.video.sampleOffset(frame: 1)-system.video.sampleOffset(frame: 0))
        let vision = TelevisionRF(system: system,frameIndex: 0,sampleRate: system.video.sampleRate,
                                  i: (0..<count).map { Float($0%97)/97 },
                                  q: (0..<count).map { Float($0%53)/53 })
        var channel = TVChannelModulator(system: system)
        let combined = try channel.combine(vision: vision,sound: nil)
        XCTAssertEqual(combined.i,vision.i)
        XCTAssertEqual(combined.q,vision.q)
    }

    func testChannelModulatorRejectsForeignGrid() throws {
        let vision = TelevisionRF(system: .palDK,frameIndex: 0,sampleRate: TVStandard.pal.sampleRate,
                                  i: [0],q: [0])
        var channel = TVChannelModulator(system: .palDK,sampleRate: 384_000)
        XCTAssertThrowsError(try channel.combine(vision: vision,sound: nil))
    }
}
