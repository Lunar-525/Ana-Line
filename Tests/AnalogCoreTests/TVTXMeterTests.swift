import XCTest
@testable import AnalogCore

final class TVTXMeterTests: XCTestCase {
    func testTransmitPowerScalesVisionSoundAndBothMetersWithPABYPASSED() throws {
        for system in TerrestrialSystem.allCases {
            let composite = try TVEngine.encode(TVFrame.colorBars(system.video))
            let pcm = [Float](repeating: 0,count: TVSoundClock.count(frame: 0,standard: system.video))
            var settings = TerrestrialSettings(system: system)
            settings.carrierToNoiseDB = 100; settings.automaticGain = false
            settings.transmitter.loadVSWR = 3
            var engine = TerrestrialEngine(system: system)
            let baseline = try engine.process(composite,settings: settings,audio: pcm)
            for power: Float in [-6,6] {
                settings.transmitter.powerDB = power
                var adjusted = TerrestrialEngine(system: system)
                let received = try adjusted.process(composite,settings: settings,audio: pcm)
                // Large Float energy reductions round differently after scaling;
                // verify the physical dB ratio to 0.001 dB (UI steps are 0.1 dB).
                XCTAssertEqual(10*log10(received.transmitter.forwardPower/baseline.transmitter.forwardPower),power,accuracy: 0.001)
                XCTAssertEqual(10*log10(received.transmitter.reflectedPower/baseline.transmitter.reflectedPower),power,accuracy: 0.001)
                XCTAssertEqual(received.transmitter.referencePower,baseline.transmitter.referencePower)
                XCTAssertEqual(received.soundCarrierDB-baseline.soundCarrierDB,power,accuracy: 0.02)
                let a = try XCTUnwrap(baseline.visionSpectrum?.powerDB.max())
                let b = try XCTUnwrap(received.visionSpectrum?.powerDB.max())
                XCTAssertEqual(b-a,power,accuracy: 0.02)
                XCTAssertFalse(received.transmitter.saturated)
            }
        }
    }

    func testTransmitPowerLeavesTheChannelNoiseFloorIndependent() {
        let zeros = [Float](repeating: 0,count: 2048)
        var settings = TerrestrialSettings(), baselineChannel = TerrestrialRFChannel(seed: 42)
        let baseline = baselineChannel.transmit(i: zeros,q: zeros,rate: TVStandard.pal.sampleRate,carrierOffsetHz: 0,settings: settings)
        for power: Float in [-60,12] {
            settings.transmitter.powerDB = power
            var channel = TerrestrialRFChannel(seed: 42)
            let noise = channel.transmit(i: zeros,q: zeros,rate: TVStandard.pal.sampleRate,carrierOffsetHz: 0,settings: settings)
            XCTAssertEqual(noise.0,baseline.0); XCTAssertEqual(noise.1,baseline.1)
        }
        for invalid: Float in [-60.1,12.1,.nan,.infinity] {
            settings.transmitter.powerDB = invalid
            XCTAssertThrowsError(try settings.validate(rate: TVStandard.pal.sampleRate))
        }
    }

    func testPowerDrivesCompressionAndMatchesScalarWithSharedVisionSoundPA() throws {
        let system = TerrestrialSystem.ntscM
        let input = try TVEngine.encode(TVFrame.colorBars(system.video))
        let pcm = [Float](repeating: 0,count: TVSoundClock.count(frame: 0,standard: system.video))
        var settings = TerrestrialSettings(system: system)
        settings.transmitter.enabled = true; settings.transmitter.sharedCoupling = 0.4
        settings.transmitter.loadVSWR = 3
        var normal = TerrestrialEngine(system: system)
        let baseline = try normal.process(input,settings: settings,audio: pcm)
        XCTAssertFalse(baseline.transmitter.saturated)
        settings.transmitter.powerDB = 12
        var boosted = TerrestrialEngine(system: system), reference = TerrestrialEngine(system: system)
        let actual = try boosted.process(input,settings: settings,audio: pcm)
        settings.execution = .reference
        let scalar = try reference.process(input,settings: settings,audio: pcm)
        XCTAssertTrue(actual.transmitter.saturated)
        XCTAssertGreaterThan(actual.transmitter.forwardPower,baseline.transmitter.forwardPower)
        XCTAssertLessThan(actual.transmitter.forwardPower,baseline.transmitter.forwardPower*settings.transmitter.powerGain)
        XCTAssertEqual(actual.transmitter.forwardPower,scalar.transmitter.forwardPower,accuracy: 1e-5)
        XCTAssertEqual(actual.transmitter.reflectedPower,scalar.transmitter.reflectedPower,accuracy: 1e-5)
        XCTAssertEqual(actual.transmitter.saturated,scalar.transmitter.saturated)
    }

    func testParallelMeterReductionsMatchFilteredOutputAndReferenceAcrossFrames() {
        var accelerated = TVTransmitterAmplifier(), reference = TVTransmitterAmplifier()
        var settings = TVTransmitterSettings()
        settings.enabled = true; settings.sharedCoupling = 0.3; settings.phaseDegrees = 12
        let count = 70_000 // Exercise multiple PA worker ranges and both FIR branches.
        let i = (0..<count).map { Float(0.8*sin(Double($0)*0.03)) }
        let q = (0..<count).map { Float(0.3*cos(Double($0)*0.07)) }
        for other: [Float] in [[0.1,0.8,0.3],[0.4]] {
            let output = accelerated.apply(i: i,q: q,settings: settings,execution: .accelerated,otherPower: other)
            _ = reference.apply(i: i,q: q,settings: settings,execution: .reference,otherPower: other)
            XCTAssertEqual(accelerated.meanOutputPower,TVTransmitterTelemetry.meanPower(i: output.0,q: output.1),accuracy: 1e-6)
            XCTAssertEqual(accelerated.meanOutputPower,reference.meanOutputPower,accuracy: 1e-6)
            XCTAssertEqual(accelerated.peakDrivePower,reference.peakDrivePower,accuracy: 1e-6)
        }
        settings.enabled = false
        _ = accelerated.apply(i: i,q: q,settings: settings,execution: .accelerated)
        XCTAssertEqual(accelerated.meanOutputPower,TVTransmitterTelemetry.meanPower(i: i,q: q),accuracy: 1e-6)
    }

    func testLoadMismatchConservesForwardReturnedAndDeliveredPower() {
        var settings = TVTransmitterSettings()
        let originalI: [Float] = [1,0.5,-0.25,0.75], originalQ: [Float] = [0.5,-0.2,0.4,0]
        let forward = TVTransmitterTelemetry.meanPower(i: originalI,q: originalQ)
        for swr: Float in [1,2,3,5] {
            settings.loadVSWR = swr
            var i = originalI, q = originalQ
            TVTransmitterSettings.deliver(i: &i,q: &q,settings: settings)
            let delivered = TVTransmitterTelemetry.meanPower(i: i,q: q)
            XCTAssertEqual(delivered+forward*settings.reflectedFraction,forward,accuracy: 1e-6)
            if swr == 1 { XCTAssertEqual(i,originalI); XCTAssertEqual(q,originalQ) }
            if swr == 3 { XCTAssertEqual(settings.reflectedFraction,0.25) }
        }
        for invalid: Float in [0.9,5.1,.nan,.infinity] {
            settings.loadVSWR = invalid
            XCTAssertThrowsError(try settings.validate())
        }
    }

    func testMetersMeasureBeforeTheChannelAndMismatchAffectsBothCarriers() throws {
        let system = TerrestrialSystem.ntscM
        let composite = try TVEngine.encode(TVFrame.colorBars(system.video))
        var settings = TerrestrialSettings(system: system)
        settings.carrierToNoiseDB = 100; settings.automaticGain = false
        let pcm = [Float](repeating: 0,count: TVSoundClock.count(frame: 0,standard: system.video))
        var clean = TerrestrialEngine(system: system), mismatch = TerrestrialEngine(system: system)
        let a = try clean.process(composite,settings: settings,audio: pcm)
        settings.transmitter.loadVSWR = 3
        let b = try mismatch.process(composite,settings: settings,audio: pcm)
        XCTAssertGreaterThan(a.transmitter.forwardPower,0)
        XCTAssertEqual(a.transmitter.reflectedPower,0)
        XCTAssertEqual(a.transmitter.referencePower,1.1)
        XCTAssertEqual(a.transmitter.forwardPower,b.transmitter.forwardPower,accuracy: 1e-6)
        XCTAssertEqual(b.transmitter.reflectedPower,b.transmitter.forwardPower*0.25,accuracy: 1e-6)
        XCTAssertEqual(b.soundCarrierDB-a.soundCarrierDB,10*log10(0.75),accuracy: 0.03)
        // Receiver/channel attenuation cannot change the PA-side instrument.
        settings.signalDB = -20
        var weak = TerrestrialEngine(system: system)
        let c = try weak.process(composite,settings: settings,audio: pcm)
        XCTAssertEqual(c.transmitter.forwardPower,b.transmitter.forwardPower,accuracy: 1e-6)
    }

    func testWarningsDetectActualPAExcursionAndAudioLimiter() throws {
        var pa = TVTransmitterAmplifier(), settings = TVTransmitterSettings()
        settings.enabled = true; settings.backoffDB = 0
        let input = [Float](repeating: 2,count: 256), zero = [Float](repeating: 0,count: 256)
        _ = pa.apply(i: input,q: zero,settings: settings,execution: .accelerated)
        XCTAssertEqual(pa.peakDrivePower,4)
        _ = pa.apply(i: zero,q: zero,settings: settings,execution: .accelerated)
        // Interpolation includes the prior sample, so a boundary excursion remains visible.
        XCTAssertGreaterThanOrEqual(pa.peakDrivePower,1)
        _ = pa.apply(i: zero,q: zero,settings: settings,execution: .accelerated)
        XCTAssertEqual(pa.peakDrivePower,0)
        let system = TerrestrialSystem.ntscM
        var tx = TerrestrialSettings(system: system); tx.transmitter.audioDriveDB = 24
        var sound = TerrestrialSoundEngine(system: system)
        let count = TVSoundClock.count(frame: 0,standard: system.video)
        let pcm = (0..<count).map { Float(0.5*sin(2*Double.pi*1000*Double($0)/48000)) }
        XCTAssertTrue(try sound.process(pcm,frameIndex: 0,settings: tx).transmitter.overmodulated)
        var modulator = VSBModulator(system: system)
        let samples = [Float](repeating: 1,count: Int(system.video.sampleOffset(frame: 1)))
        _ = try modulator.modulate(CompositeVideo(standard: system.video,frameIndex: 0,samples: samples))
        XCTAssertTrue(modulator.overmodulated)
    }
}
