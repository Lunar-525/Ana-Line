import XCTest
@testable import AnalogCore

final class TVPropagationTests: XCTestCase {
    func testDistanceGainAndAntennaPatternHavePhysicalScaling() {
        var s = TVPropagationSettings(); s.transmitterHeightM = 300; s.receiverHeightM = 150
        let a = TVPropagationModel.evaluate(s)
        s.distanceKm = 20
        let b = TVPropagationModel.evaluate(s)
        XCTAssertEqual(b.spaceLossDB-a.spaceLossDB,20*log10(2),accuracy: 1e-9)
        XCTAssertEqual(b.diffractionLossDB,0)
        s.antennaGainDB += 6
        XCTAssertEqual(TVPropagationModel.evaluate(s).relativeGainDB-b.relativeGainDB,6,accuracy: 1e-9)
        XCTAssertGreaterThan(TVAntennaKind.yagi.lossDB(offAxisDegrees: 45),TVAntennaKind.dipole.lossDB(offAxisDegrees: 45))
        XCTAssertEqual(TVAntennaKind.dipole.lossDB(offAxisDegrees: 180),0)
        XCTAssertEqual(TVAntennaKind.yagi.lossDB(offAxisDegrees: 180),30)
    }

    func testRidgeBypassAndRefractionChangeClearance() {
        var s = TVPropagationSettings(); s.ridgeHeightM = 200; s.ridgeEnabled = true
        let blocked = TVPropagationModel.evaluate(s)
        XCTAssertLessThan(blocked.ridgeClearanceM,0)
        XCTAssertGreaterThan(blocked.diffractionLossDB,20)
        s.ridgeEnabled = false
        let clear = TVPropagationModel.evaluate(s)
        XCTAssertEqual(clear.diffractionLossDB,0)
        s.ridgeHeightM = 500; s.ridgePosition = 0.85
        XCTAssertEqual(TVPropagationModel.evaluate(s).relativeGainDB,clear.relativeGainDB)
        s.distanceKm = 50; s.transmitterHeightM = 20; s.receiverHeightM = 2; s.refractionK = 0.65
        let lowK = TVPropagationModel.evaluate(s)
        s.refractionK = 4
        let highK = TVPropagationModel.evaluate(s)
        XCTAssertGreaterThan(highK.ridgeClearanceM,lowK.ridgeClearanceM)
        XCTAssertLessThan(highK.diffractionLossDB,lowK.diffractionLossDB)
        XCTAssertGreaterThan(lowK.diffractionLossDB,0,"Earth curvature remains when the ridge is switched off")
    }

    func testWeatherLossClutterThermalNoiseAndRefraction() {
        var s = TVPropagationSettings(); s.weather.enabled = true
        let neutral = TVPropagationModel.evaluate(s)
        XCTAssertEqual(neutral.thermalNoiseScale,1)
        XCTAssertEqual(neutral.weatherLossDB,0)
        s.weather.rainMMHour = 100; s.weather.snowMMHour = 15; s.weather.fogGramsM3 = 0.4
        let wet = TVPropagationModel.evaluate(s)
        XCTAssertGreaterThan(wet.weatherLossDB,0)
        XCTAssertLessThan(wet.weatherLossDB,2,"Sub-GHz weather absorption is intentionally weak")
        XCTAssertGreaterThan(wet.clutterAmplitude,0)
        s.weather.temperatureC = 50; s.weather.sunlight = 1
        let hot = TVPropagationModel.evaluate(s)
        XCTAssertEqual(hot.thermalNoiseScale,Float(sqrt(323.15/293.15)),accuracy: 1e-6)
        XCTAssertLessThan(hot.refractionK,neutral.refractionK)
        s.weather.enabled = false
        let off = TVPropagationModel.evaluate(s)
        XCTAssertEqual(off.weatherLossDB,0); XCTAssertEqual(off.clutterAmplitude,0)
        XCTAssertEqual(off.thermalNoiseScale,1); XCTAssertEqual(off.refractionK,Double(s.refractionK),accuracy: 1e-7)
    }

    func testPropagationRaysPreserveContinuityAcrossArbitraryBlocks() {
        var s = TVPropagationSettings(); s.enabled = true; s.groundReflection = 0.4
        s.weather.enabled = true; s.weather.rainMMHour = 70; s.weather.clutter = 0.8
        let rate = 384_000.0, count = 131_072
        let i = (0..<count).map { Float(cos(Double($0)*0.19)) }
        let q = (0..<count).map { Float(sin(Double($0)*0.19)) }
        var whole = TVSceneChannel(), streaming = TVSceneChannel()
        let expected = whole.propagate(i: i,q: q,rate: rate,carrierOffsetHz: 6.5e6,time: 0,settings: s)
        var actualI = [Float](), actualQ = [Float]()
        for block in [0..<17,17..<1041,1041..<count] {
            let result = streaming.propagate(i: Array(i[block]),q: Array(q[block]),rate: rate,carrierOffsetHz: 6.5e6,
                time: Double(block.lowerBound)/rate,settings: s)
            actualI += result.0; actualQ += result.1
        }
        XCTAssertLessThan(zip(actualI,expected.0).map { abs($0-$1) }.max()!,1e-6)
        XCTAssertLessThan(zip(actualQ,expected.1).map { abs($0-$1) }.max()!,1e-6)
        s.enabled = false
        let bypass = streaming.propagate(i: i,q: q,rate: rate,carrierOffsetHz: 0,time: 0,settings: s)
        XCTAssertEqual(bypass.0,i); XCTAssertEqual(bypass.1,q)
    }

    func testLightningIsRepeatableContinuousAndSharedInTimeAcrossCarriers() {
        var s = TVPropagationSettings(); s.enabled = true; s.weather.enabled = true; s.weather.lightning = 1; s.weather.lightningRatePerMinute = 120
        let rate = 48_000.0, count = Int(rate*2)
        func interference(_ slice: Range<Int>,offset: Double) -> ([Float],[Float]) {
            var i = [Float](repeating: 0,count: slice.count), q = i
            TVSceneChannel.interference(i: &i,q: &q,rate: rate,carrierOffsetHz: offset,time: Double(slice.lowerBound)/rate,
                noiseReferenceRate: rate,seed: 1234,settings: s)
            return (i,q)
        }
        let whole = interference(0..<count,offset: 0)
        let sound = interference(0..<count,offset: 6.5e6)
        XCTAssertGreaterThan(whole.0.map { abs($0) }.max()!,0.1)
        XCTAssertEqual(whole.0.map { $0 != 0 },sound.0.map { $0 != 0 },"Both carriers see the same lightning envelope")
        let cut = 12_037, a = interference(0..<cut,offset: 0), b = interference(cut..<count,offset: 0)
        XCTAssertLessThan(zip(whole.0,a.0+b.0).map { abs($0-$1) }.max()!,0.00001)
        XCTAssertEqual(whole.0,interference(0..<count,offset: 0).0)
    }

    func testLightningMetadataMatchesActualRFImpulsesAndBypass() throws {
        var s = TVPropagationSettings(); s.enabled = true
        s.weather.enabled = true; s.weather.lightning = 1; s.weather.lightningRatePerMinute = 120
        let rate = 48_000.0, duration = 2.0
        let events = TVLightningTimeline.events(time: 0,duration: duration,seed: 1234,settings: s)
        XCTAssertFalse(events.isEmpty)
        var i = [Float](repeating: 0,count: Int(rate*duration)), q = i
        TVSceneChannel.interference(i: &i,q: &q,rate: rate,carrierOffsetHz: 0,time: 0,
            noiseReferenceRate: rate,seed: 1234,settings: s)
        for n in i.indices {
            let time = Double(n)/rate
            let inside = events.contains { time >= $0.time && time < $0.time+TVLightningEvent.pulseDuration }
            XCTAssertEqual(i[n] != 0 || q[n] != 0,inside,"No RF strike may occur outside the published event timeline")
        }
        let first = try XCTUnwrap(events.first)
        XCTAssertTrue(TVLightningTimeline.events(time: first.time+0.002,duration: 0.002,seed: 1234,settings: s).contains(first))
        XCTAssertTrue(TVLightningTimeline.events(time: first.time-0.01,duration: 0.005,seed: 1234,settings: s).isEmpty)
        XCTAssertEqual(events,TVLightningTimeline.events(time: 0,duration: duration,seed: 1234,settings: s))
        var weak = s; weak.weather.lightning = 0.2
        let weaker = TVLightningTimeline.events(time: 0,duration: duration,seed: 1234,settings: weak)
        XCTAssertEqual(weaker.map(\.token),events.map(\.token),"Intensity must not change the schedule")
        XCTAssertEqual(weaker.map(\.time),events.map(\.time))
        XCTAssertTrue(weaker.allSatisfy { $0.intensity == 0.2 })
        s.weather.lightning = 0
        XCTAssertTrue(TVLightningTimeline.events(time: 0,duration: duration,seed: 1234,settings: s).isEmpty)
        s.weather.lightning = 1; s.weather.enabled = false
        XCTAssertTrue(TVLightningTimeline.events(time: 0,duration: duration,seed: 1234,settings: s).isEmpty)
        s.weather.enabled = true; s.enabled = false
        XCTAssertTrue(TVLightningTimeline.events(time: 0,duration: duration,seed: 1234,settings: s).isEmpty)
    }

    func testLightningRateIsIndependentOfIntensityAndMatchesItsUnits() throws {
        var s = TVPropagationSettings(); s.enabled = true; s.weather.enabled = true
        s.weather.lightning = 0.25; s.weather.lightningRatePerMinute = 30
        let low = TVLightningTimeline.events(time: 0,duration: 3600,seed: 42,settings: s)
        XCTAssertEqual(Double(low.count)/60,30,accuracy: 3,"Rate is average strikes per minute")
        s.weather.lightning = 1
        let strong = TVLightningTimeline.events(time: 0,duration: 3600,seed: 42,settings: s)
        XCTAssertEqual(low.map(\.time),strong.map(\.time))
        XCTAssertEqual(low.map(\.token),strong.map(\.token))
        s.weather.lightningRatePerMinute = 120
        let frequent = TVLightningTimeline.events(time: 0,duration: 3600,seed: 42,settings: s)
        XCTAssertEqual(Double(frequent.count)/60,120,accuracy: 6)
        let tokens = Set(frequent.map(\.token))
        XCTAssertTrue(strong.allSatisfy { tokens.contains($0.token) })
        XCTAssertTrue(frequent.allSatisfy { $0.intensity == 1 })
        s.weather.lightningRatePerMinute = 0
        XCTAssertTrue(TVLightningTimeline.events(time: 0,duration: 3600,seed: 42,settings: s).isEmpty)
        var i = [Float](repeating: 0,count: 48_000),q = i
        TVSceneChannel.interference(i: &i,q: &q,rate: 48_000,carrierOffsetHz: 0,time: 0,
            noiseReferenceRate: 48_000,seed: 42,settings: s)
        XCTAssertTrue(i.allSatisfy { $0 == 0 } && q.allSatisfy { $0 == 0 })
        for invalid: Float in [-1,121,.infinity,.nan] {
            s.weather.lightningRatePerMinute = invalid
            XCTAssertThrowsError(try s.validate())
        }
    }

    func testLightningIntensityScalesRFWithoutChangingImpulseSupport() {
        var s = TVPropagationSettings(); s.enabled = true; s.weather.enabled = true
        s.weather.lightning = 1; s.weather.lightningRatePerMinute = 120
        func signal(_ strength: Float) -> ([Float],[Float]) {
            var settings = s; settings.weather.lightning = strength
            var i = [Float](repeating: 0,count: 96_000),q = i
            TVSceneChannel.interference(i: &i,q: &q,rate: 48_000,carrierOffsetHz: 0,time: 0,
                noiseReferenceRate: 48_000,seed: 42,settings: settings)
            return (i,q)
        }
        let strong = signal(1), weak = signal(0.2),off = signal(0)
        XCTAssertGreaterThan(strong.0.map { abs($0) }.max()!,1)
        XCTAssertEqual(strong.0.map { $0 != 0 },weak.0.map { $0 != 0 })
        XCTAssertLessThan(zip(strong.0,weak.0).map { abs($0*0.2-$1) }.max()!,1e-6)
        XCTAssertLessThan(zip(strong.1,weak.1).map { abs($0*0.2-$1) }.max()!,1e-6)
        XCTAssertTrue(off.0.allSatisfy { $0 == 0 } && off.1.allSatisfy { $0 == 0 })
    }

    func testDecodedPALAndNTSCFramesCarryTheirOwnLightningEvent() throws {
        for system in TerrestrialSystem.allCases {
            var settings = TerrestrialSettings(system: system)
            settings.propagation.enabled = true; settings.propagation.weather.enabled = true
            settings.propagation.weather.lightning = 1
            settings.propagation.weather.lightningRatePerMinute = 120
            let event = try XCTUnwrap(TVLightningTimeline.events(time: 0,duration: 4,seed: settings.seed,settings: settings.propagation).first)
            let index = Int64(floor(event.time/system.video.frameDuration))
            let input = try TVEngine.encode(TVFrame.colorBars(system.video),frameIndex: index)
            var engine = TerrestrialEngine(system: system)
            let result = try engine.process(input,settings: settings)
            XCTAssertTrue(result.lightningEvents.contains(event))
            settings.propagation.weather.enabled = false
            let bypass = try engine.process(input,settings: settings)
            XCTAssertTrue(bypass.lightningEvents.isEmpty)
        }
    }

    func testIonosphericRemoteSourceFavorsVHFAndFMPhaseIsContinuous() {
        var s = TVPropagationSettings(); s.enabled = true; s.weather.enabled = true; s.weather.ionization = 1
        let rate = 384_000.0, count = 4096
        func sample(_ slice: Range<Int>,frequency: Float,offset: Double) -> [Float] {
            var local = s; local.frequencyMHz = frequency
            var i = [Float](repeating: 0,count: slice.count), q = i
            TVSceneChannel.interference(i: &i,q: &q,rate: rate,carrierOffsetHz: offset,time: Double(slice.lowerBound)/rate,
                noiseReferenceRate: rate,seed: 10,settings: local)
            return i
        }
        let vhf = sample(0..<count,frequency: 60,offset: 0), uhf = sample(0..<count,frequency: 600,offset: 0)
        XCTAssertGreaterThan(vhf.reduce(0) { $0+$1*$1 },uhf.reduce(0) { $0+$1*$1 }*1000)
        let fm = sample(0..<count,frequency: 60,offset: 6.5e6)
        let split = sample(0..<2031,frequency: 60,offset: 6.5e6)+sample(2031..<count,frequency: 60,offset: 6.5e6)
        XCTAssertLessThan(zip(fm,split).map { abs($0-$1) }.max()!,1e-6)
    }

    func testParallelRemoteSourceMatchesScalarAcrossFramesAndChunkBoundaries() {
        var settings = TVPropagationSettings(); settings.enabled = true; settings.weather.enabled = true
        settings.frequencyMHz = 60; settings.antennaGainDB = 25
        settings.weather.ionization = 1; settings.weather.lightning = 1
        let rate = 17_734_475.0, count = 710_000
        for offset in [0.0,6.5e6] {
            let time = 12.345
            func sample(_ range: Range<Int>,execution: TVExecution) -> ([Float],[Float]) {
                var re = [Float](repeating: 0,count: range.count), im = re
                TVSceneChannel.interference(i: &re,q: &im,rate: rate,carrierOffsetHz: offset,
                    time: time+Double(range.lowerBound)/rate,noiseReferenceRate: rate,
                    seed: 42,settings: settings,execution: execution)
                return (re,im)
            }
            let reference = sample(0..<count,execution: .reference)
            let parallel = sample(0..<count,execution: .accelerated)
            let cut = 321_037
            let a = sample(0..<cut,execution: .accelerated), b = sample(cut..<count,execution: .accelerated)
            for (expected,actual) in [(reference.0,parallel.0),(reference.1,parallel.1),
                                      (parallel.0,a.0+b.0),(parallel.1,a.1+b.1)] {
                XCTAssertLessThan(zip(expected,actual).map { abs($0-$1) }.max()!,2e-6)
            }
        }
    }

    func testTerrainLossCanRecoverWhenAntennaAndRidgeAreRestored() throws {
        for system in TerrestrialSystem.allCases {
            var engine = TerrestrialEngine(system: system)
            var s = TerrestrialSettings(system: system); s.propagation.enabled = true
            let picture = TVFrame.colorBars(system.video)
            let normal = try engine.process(TVEngine.encode(picture),settings: s)
            XCTAssertEqual(normal.lock,.locked)
            s.propagation.ridgeEnabled = true; s.propagation.ridgeHeightM = 500
            s.propagation.antennaElevationDegrees = -90
            for n: Int64 in 1...4 { _ = try engine.process(TVEngine.encode(picture,frameIndex: n),settings: s) }
            let lost = try engine.process(TVEngine.encode(picture,frameIndex: 5),settings: s)
            XCTAssertNotEqual(lost.lock,.locked)
            s.propagation.ridgeEnabled = false; s.propagation.antennaElevationDegrees = 0
            var restored: TerrestrialReception!
            for n: Int64 in 6...11 {
                restored = try engine.process(TVEngine.encode(picture,frameIndex: n),settings: s)
            }
            XCTAssertEqual(restored.lock,.locked)
        }
    }

    func testInvalidSceneAndPASettingsAreRejectedBeforeDSP() throws {
        var s = TerrestrialSettings(); s.propagation.frequencyMHz = .nan
        var engine = TerrestrialEngine(system: .palDK)
        let signal = try TVEngine.encode(TVFrame.colorBars(.pal))
        XCTAssertThrowsError(try engine.process(signal,settings: s))
        s = TerrestrialSettings(); s.transmitter.enabled = true; s.transmitter.backoffDB = .infinity
        XCTAssertThrowsError(try engine.process(signal,settings: s))
    }
}

final class TVTransmitterTests: XCTestCase {
    func testCompressionAndAMPMFollowBackoff() {
        var s = TVTransmitterSettings(); s.enabled = true; s.phaseDegrees = 30
        s.backoffDB = 24
        let clean = TVTransmitterAmplifier.coefficient(power: 1,settings: s)
        s.backoffDB = -6
        let saturated = TVTransmitterAmplifier.coefficient(power: 1,settings: s)
        XCTAssertGreaterThan(hypot(clean.x,clean.y),0.99)
        XCTAssertLessThan(hypot(saturated.x,saturated.y),0.6)
        XCTAssertGreaterThan(atan2(saturated.y,saturated.x),atan2(clean.y,clean.x))
    }

    func testOversampledPAPreservesStreamingStateAndDisabledBypass() {
        var s = TVTransmitterSettings(); s.enabled = true; s.backoffDB = -2; s.phaseDegrees = 20
        let count = 131_072, i = (0..<131_072).map { Float(1.2*cos(Double($0)*0.16)) }
        let q = (0..<131_072).map { Float(1.2*sin(Double($0)*0.16)) }
        var whole = TVTransmitterAmplifier(), blocks = TVTransmitterAmplifier()
        let expected = whole.apply(i: i,q: q,settings: s,execution: .accelerated)
        var scalar = TVTransmitterAmplifier()
        let reference = scalar.apply(i: i,q: q,settings: s,execution: .reference)
        XCTAssertLessThan(zip(reference.0,expected.0).map { abs($0-$1) }.max()!,1e-6)
        XCTAssertLessThan(zip(reference.1,expected.1).map { abs($0-$1) }.max()!,1e-6)
        var re = [Float](), im = [Float]()
        for block in [0..<15,15..<701,701..<count] {
            let result = blocks.apply(i: Array(i[block]),q: Array(q[block]),settings: s,execution: .accelerated)
            re += result.0; im += result.1
        }
        XCTAssertLessThan(zip(re,expected.0).map { abs($0-$1) }.max()!,1e-6)
        XCTAssertLessThan(zip(im,expected.1).map { abs($0-$1) }.max()!,1e-6)
        s.enabled = false
        let bypass = blocks.apply(i: i,q: q,settings: s,execution: .accelerated)
        XCTAssertEqual(bypass.0,i); XCTAssertEqual(bypass.1,q)
    }
}
