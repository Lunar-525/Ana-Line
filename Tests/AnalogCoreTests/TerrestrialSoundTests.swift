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

    func testInvalidPCMIsRejected() throws {
        var engine = TerrestrialSoundEngine(system: .palDK)
        XCTAssertThrowsError(try engine.process([],frameIndex: 0,settings: .init()))
        var pcm = tone(.palDK,frame: 0); pcm[10] = .nan
        XCTAssertThrowsError(try engine.process(pcm,frameIndex: 0,settings: .init()))
    }
}
