import XCTest
@testable import AnalogCore

final class TVUnifiedChannelTests: XCTestCase {
    private func tone(_ system: TerrestrialSystem, frame: Int64, amplitude: Double = 0.25) -> [Float] {
        let start = TVSoundClock.offset(frame: frame,standard: system.video)
        return (0..<TVSoundClock.count(frame: frame,standard: system.video)).map {
            Float(amplitude*sin(2 * .pi * 1000 * Double(start+Int64($0))/48_000))
        }
    }

    private func measuredTone(_ samples: [Float]) -> (tone: Double, residual: Double) {
        var sine = 0.0, cosine = 0.0, power = 0.0
        for (n,value) in samples.enumerated() {
            let p = 2 * Double.pi * 1000 * Double(n)/48_000
            sine += Double(value)*sin(p); cosine += Double(value)*cos(p)
            power += Double(value*value)
        }
        let a = 2*hypot(sine,cosine)/Double(samples.count)
        return (a,sqrt(max(0,power/Double(samples.count)-a*a/2)))
    }

    func testUnifiedChannelRecoversVisionWithoutSound() throws {
        for system in TerrestrialSystem.allCases {
            var engine = TVUnifiedChannelEngine(system: system)
            var settings = TerrestrialSettings(system: system); settings.carrierToNoiseDB = 100
            let source = TVFrame.colorBars(system.video)
            for index: Int64 in [0,1,2] {
                let result = try engine.process(TVEngine.encode(source,frameIndex: index),settings: settings)
                XCTAssertEqual(result.lock,.locked)
                XCTAssertEqual(result.synchronization.horizontal,.locked)
                XCTAssertEqual(result.synchronization.vertical,.locked)
                XCTAssertEqual(result.synchronization.color,.locked)
                XCTAssertGreaterThan(result.recoveredLines,system.video.height*95/100)
                for x in stride(from: 45, to: 720, by: 90) {
                    let pixel = (system.video.height/4)*720+x
                    for c in 0..<3 {
                        XCTAssertEqual(result.frame.rgb[pixel][c],source.rgb[pixel][c],accuracy: 0.12)
                    }
                }
            }
        }
    }

    func testUnifiedChannelRecoversVisionAndSoundFromOnePass() throws {
        for system in TerrestrialSystem.allCases {
            var engine = TVUnifiedChannelEngine(system: system)
            var settings = TerrestrialSettings(system: system); settings.carrierToNoiseDB = 90
            let source = TVFrame.colorBars(system.video)
            var recovered = [Float]()
            var locked = 0
            for frame: Int64 in 0..<8 {
                let result = try engine.process(TVEngine.encode(source,frameIndex: frame),settings: settings,
                                                audio: tone(system,frame: frame))
                XCTAssertEqual(result.audio.count,TVSoundClock.count(frame: frame,standard: system.video))
                XCTAssertTrue(result.audio.allSatisfy(\.isFinite))
                if result.lock == .locked { locked += 1 }
                if frame >= 3 { recovered += result.audio }
            }
            let audio = measuredTone(recovered)
            print("unified",system,"locked",locked,"tone",audio.tone,"residual",audio.residual)
            XCTAssertGreaterThanOrEqual(locked,6,"Combined sound must not prevent vision lock")
            XCTAssertEqual(audio.tone,0.25,accuracy: 0.04)
            XCTAssertLessThan(audio.residual,0.04)
        }
    }

    func testUnifiedNarrowIFRejectsCompanionCarrier() throws {
        for system in TerrestrialSystem.allCases {
            var wide = TVUnifiedChannelEngine(system: system)
            var narrow = TVUnifiedChannelEngine(system: system)
            var wideSettings = TerrestrialSettings(system: system); wideSettings.carrierToNoiseDB = 90
            var narrowSettings = wideSettings; narrowSettings.rfBandwidthMHz = 3
            let source = TVFrame.colorBars(system.video)
            var wideDB = Float(-200), narrowDB = Float(-200)
            for frame: Int64 in 0..<6 {
                let a = try wide.process(TVEngine.encode(source,frameIndex: frame),settings: wideSettings,
                                         audio: tone(system,frame: frame))
                let b = try narrow.process(TVEngine.encode(source,frameIndex: frame),settings: narrowSettings,
                                           audio: tone(system,frame: frame))
                if frame >= 3 { wideDB = a.soundCarrierDB; narrowDB = b.soundCarrierDB }
            }
            print("unified IF",system,"wide sound",wideDB,"narrow sound",narrowDB)
            XCTAssertGreaterThan(wideDB,-20,"A wide IF must retain the companion carrier")
            XCTAssertLessThan(narrowDB,wideDB-25,"A 3 MHz IF must reject the +6.5/+4.5 MHz companion")
        }
    }
}
