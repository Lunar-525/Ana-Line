import XCTest
@testable import AnalogCore

final class TerrestrialSoundTests: XCTestCase {
    func testPCMClockHasNoNTSCFrameRoundingDrift() {
        for standard in TVStandard.allCases {
            var position: Int64 = 0
            for frame: Int64 in 0..<30_000 {
                XCTAssertEqual(TVSoundClock.offset(frame: frame,standard: standard),position)
                position += Int64(TVSoundClock.count(frame: frame,standard: standard))
            }
            XCTAssertEqual(position,standard == .pal ? 57_600_000 : 48_048_000)
        }
    }

    private func tone(_ system: TerrestrialSystem, frame: Int64, amplitude: Double = 0.25) -> [Float] {
        let start = TVSoundClock.offset(frame: frame,standard: system.video)
        return (0..<TVSoundClock.count(frame: frame,standard: system.video)).map {
            Float(amplitude*sin(2 * .pi * 1000 * Double(start+Int64($0))/48_000))
        }
    }
    private func amplitude(_ samples: [Float]) -> (tone: Double, residual: Double) {
        var sine = 0.0, cosine = 0.0, power = 0.0
        for (n,value) in samples.enumerated() {
            let p = 2 * Double.pi * 1000 * Double(n)/48_000
            sine += Double(value)*sin(p); cosine += Double(value)*cos(p)
            power += Double(value*value)
        }
        let a = 2*hypot(sine,cosine)/Double(samples.count)
        return (a,sqrt(max(0,power/Double(samples.count)-a*a/2)))
    }

    func testCleanFMAndEmphasisRecoverToneContinuously() throws {
        for system in TerrestrialSystem.allCases {
            var engine = TerrestrialSoundEngine(system: system)
            var settings = TerrestrialSettings(system: system); settings.carrierToNoiseDB = 90
            var samples = [Float]()
            for frame: Int64 in 0..<8 {
                let received = try engine.process(tone(system,frame: frame),frameIndex: frame,settings: settings)
                XCTAssertEqual(received.samples.count,TVSoundClock.count(frame: frame,standard: system.video))
                XCTAssertTrue(received.samples.allSatisfy(\.isFinite))
                if frame >= 2 {
                    samples += received.samples
                    XCTAssertEqual(received.carrierDB,-10,accuracy: 0.1)
                }
            }
            let measured = amplitude(samples)
            print("FM clean",system,measured)
            XCTAssertEqual(measured.tone,0.25,accuracy: 0.015)
            XCTAssertLessThan(measured.residual,0.015)
        }
    }

    func testRFNoiseAttenuationAndChannelEdgesAffectSound() throws {
        for system in TerrestrialSystem.allCases {
            var clean = TerrestrialSoundEngine(system: system), weak = TerrestrialSoundEngine(system: system)
            var rejected = TerrestrialSoundEngine(system: system)
            var settings = TerrestrialSettings(system: system); settings.carrierToNoiseDB = 35
            var weakSettings = settings; weakSettings.signalDB = -40
            var narrow = settings; narrow.rfBandwidthMHz = 3
            var clearPCM = [Float](), noisyPCM = [Float](), rejectedPCM = [Float]()
            for frame: Int64 in 0..<6 {
                let source = tone(system,frame: frame)
                let a = try clean.process(source,frameIndex: frame,settings: settings)
                let b = try weak.process(source,frameIndex: frame,settings: weakSettings)
                let c = try rejected.process(source,frameIndex: frame,settings: narrow)
                if frame >= 2 { clearPCM += a.samples; noisyPCM += b.samples; rejectedPCM += c.samples }
            }
            XCTAssertGreaterThan(amplitude(noisyPCM).residual,amplitude(clearPCM).residual*4)
            XCTAssertLessThan(rejectedPCM.map { abs($0) }.max() ?? 1,0.001)
        }
    }

    func testAFCAndCarrierDependentMultipath() throws {
        for system in TerrestrialSystem.allCases {
            var tuned = TerrestrialSoundEngine(system: system)
            var settings = TerrestrialSettings(system: system)
            settings.carrierToNoiseDB = 90; settings.tuningOffsetKHz = 80
            for frame: Int64 in 0..<4 {
                let result = try tuned.process(tone(system,frame: frame),frameIndex: frame,settings: settings,visionCorrectionHz: -80_000)
                if frame >= 2 { XCTAssertEqual(amplitude(result.samples).tone,0.25,accuracy: 0.02) }
            }
            var echo = TerrestrialSoundEngine(system: system)
            settings.tuningOffsetKHz = 0; settings.echoGain = 1
            settings.echoDelayMicroseconds = 2; settings.echoPhaseDegrees = 180
            for frame: Int64 in 0..<4 {
                let result = try echo.process(.init(repeating: 0,count: TVSoundClock.count(frame: frame,standard: system.video)),
                    frameIndex: frame,settings: settings)
                if frame >= 2 { XCTAssertLessThan(result.carrierDB,-60) }
            }
        }
    }

    func testAntennaAndWeatherReachTheDecodedFMSound() throws {
        for system in TerrestrialSystem.allCases {
            var settings = TerrestrialSettings(system: system)
            settings.propagation.enabled = true
            settings.carrierToNoiseDB = 35
            var turned = settings
            turned.propagation.antennaElevationDegrees = 90
            turned.propagation.antennaGainDB = -5
            var wet = settings
            wet.propagation.weather.enabled = true
            wet.propagation.weather.rainMMHour = 120
            wet.propagation.weather.snowMMHour = 20
            wet.propagation.weather.fogGramsM3 = 0.5
            wet.propagation.weather.humidityPercent = 100
            wet.propagation.weather.clutter = 0 // Isolate attenuation from moving reflections.
            var clear = TerrestrialSoundEngine(system: system), offAxis = TerrestrialSoundEngine(system: system)
            var weather = TerrestrialSoundEngine(system: system)
            var cleanPCM = [Float](), weakPCM = [Float]()
            var clearCarrier = Float(0), weakCarrier = Float(0), wetCarrier = Float(0)
            for frame: Int64 in 0..<12 {
                let source = tone(system,frame: frame)
                let a = try clear.process(source,frameIndex: frame,settings: settings)
                let b = try offAxis.process(source,frameIndex: frame,settings: turned)
                let c = try weather.process(source,frameIndex: frame,settings: wet)
                if frame >= 2 { cleanPCM += a.samples; weakPCM += b.samples }
                clearCarrier = a.carrierDB; weakCarrier = b.carrierDB; wetCarrier = c.carrierDB
            }
            XCTAssertLessThan(weakCarrier,clearCarrier-30,"Antenna loss must reach the sound RF envelope")
            XCTAssertGreaterThan(amplitude(weakPCM).residual,amplitude(cleanPCM).residual*5,
                "A seriously misaligned antenna must damage the demodulated audio, not only its meter")
            XCTAssertLessThan(wetCarrier,clearCarrier-1,"Weather attenuation must also reduce the FM carrier")
            print("FM propagation",system,"clear/antenna/wet carrier dB:",clearCarrier,weakCarrier,wetCarrier,
                  "clear/antenna residual RMS:",amplitude(cleanPCM).residual,amplitude(weakPCM).residual)
        }
    }

    func testLightningChangesRecoveredFMAudioOnTheSharedEventClock() throws {
        for system in TerrestrialSystem.allCases {
            var settings = TerrestrialSettings(system: system)
            settings.carrierToNoiseDB = 90
            settings.propagation.enabled = true; settings.propagation.weather.enabled = true
            var storm = settings; storm.propagation.weather.lightning = 1; storm.propagation.weather.lightningRatePerMinute = 120
            let event = try XCTUnwrap(TVLightningTimeline.events(time: 0,duration: 2,
                seed: settings.seed,settings: storm.propagation).first)
            let first = max(Int64(0),Int64(floor(event.time/system.video.frameDuration))-2)
            let last = Int64(floor((event.time+0.06)/system.video.frameDuration))
            var clear = TerrestrialSoundEngine(system: system), lightning = TerrestrialSoundEngine(system: system)
            var before = Float(0), after = Float(0)
            for frame in first...last {
                let source = tone(system,frame: frame)
                let a = try clear.process(source,frameIndex: frame,settings: settings)
                let b = try lightning.process(source,frameIndex: frame,settings: storm)
                let delta = zip(a.samples,b.samples).map { abs($0-$1) }.max() ?? 0
                if Double(frame+1)*system.video.frameDuration <= event.time { before = max(before,delta) }
                else { after = max(after,delta) }
                XCTAssertTrue(b.samples.allSatisfy(\.isFinite))
            }
            XCTAssertEqual(before,0,"A future strike cannot disturb earlier audio")
            XCTAssertGreaterThan(after,0.01,"The real demodulated PCM must respond to the RF impulse")
            print("FM lightning",system,"event seconds:",event.time,"peak PCM difference:",after)
        }
    }

    func testInvalidPCMIsRejected() throws {
        var engine = TerrestrialSoundEngine(system: .palDK)
        XCTAssertThrowsError(try engine.process([],frameIndex: 0,settings: .init()))
        var pcm = tone(.palDK,frame: 0); pcm[10] = .nan
        XCTAssertThrowsError(try engine.process(pcm,frameIndex: 0,settings: .init()))
    }
}
