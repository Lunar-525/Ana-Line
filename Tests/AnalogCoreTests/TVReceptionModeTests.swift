import XCTest
@testable import AnalogCore

final class TVReceptionModeTests: XCTestCase {
    private func tone(_ system: TerrestrialSystem, frame: Int64, amplitude: Double = 0.25) -> [Float] {
        let start = TVSoundClock.offset(frame: frame,standard: system.video)
        return (0..<TVSoundClock.count(frame: frame,standard: system.video)).map {
            Float(amplitude*sin(2 * .pi * 1000 * Double(start+Int64($0))/48_000))
        }
    }
    private func measuredTone(_ samples: [Float]) -> Double {
        var sine = 0.0, cosine = 0.0
        for (n,value) in samples.enumerated() {
            let p = 2 * Double.pi * 1000 * Double(n)/48_000
            sine += Double(value)*sin(p); cosine += Double(value)*cos(p)
        }
        return 2*hypot(sine,cosine)/Double(samples.count)
    }

    func testBothDetectionModesRecoverTheTone() throws {
        for system in TerrestrialSystem.allCases {
            for mode in TVSoundDetectionMode.allCases {
                var engine = TVUnifiedChannelEngine(system: system)
                var settings = TerrestrialSettings(system: system)
                settings.carrierToNoiseDB = 90
                settings.frontEnd.soundDetection = mode
                let source = TVFrame.colorBars(system.video)
                var recovered = [Float](), locked = 0
                for frame: Int64 in 0..<8 {
                    let result = try engine.process(TVEngine.encode(source,frameIndex: frame),settings: settings,
                                                    audio: tone(system,frame: frame))
                    if result.lock == .locked { locked += 1 }
                    if frame >= 3 { recovered += result.audio }
                }
                let amplitude = measuredTone(recovered)
                print("mode",mode.rawValue,system.rawValue,"locked",locked,"tone",amplitude)
                XCTAssertGreaterThanOrEqual(locked,6,"\(mode) must still lock vision")
                XCTAssertEqual(amplitude,0.25,accuracy: 0.05)
            }
        }
    }

    func testIntercarrierCancelsCommonTuningError() throws {
        for system in TerrestrialSystem.allCases {
            var engine = TVUnifiedChannelEngine(system: system)
            var settings = TerrestrialSettings(system: system)
            settings.carrierToNoiseDB = 90
            settings.tuningOffsetKHz = 40
            settings.frontEnd.soundDetection = .intercarrier
            let source = TVFrame.colorBars(system.video)
            var recovered = [Float]()
            for frame: Int64 in 0..<8 {
                let result = try engine.process(TVEngine.encode(source,frameIndex: frame),settings: settings,
                                                audio: tone(system,frame: frame))
                if frame >= 3 { recovered += result.audio }
            }
            let amplitude = measuredTone(recovered)
            print("intercarrier tuned",system.rawValue,"tone",amplitude)
            XCTAssertEqual(amplitude,0.25,accuracy: 0.05)
        }
    }

    func testSoundNotchRejectsCarrierAndKeepsVideo() {
        let rate = TVStandard.pal.sampleRate
        let count = 200_000
        let carrier = TerrestrialSystem.palDK.soundCarrierHz
        var input = [Float](repeating: 0,count: count)
        for n in 0..<count {
            let carrierWave = 0.3*cos(2*Double.pi*carrier*Double(n)/rate)
            let videoWave = 0.1*cos(2*Double.pi*1_000_000*Double(n)/rate)
            input[n] = Float(0.2+carrierWave+videoWave)
        }
        func amplitude(_ x: [Float], _ hz: Double) -> Double {
            var re = 0.0, im = 0.0
            for n in 65_536..<count {
                let p = 2*Double.pi*hz*Double(n)/rate
                re += Double(x[n])*cos(p); im += Double(x[n])*sin(p)
            }
            return 2*hypot(re,im)/Double(count-65_536)
        }
        var notch = TVSoundNotch(frequency: carrier,rate: rate)
        let output = notch.process(input)
        let before = amplitude(input,carrier), after = amplitude(output,carrier)
        let videoBefore = amplitude(input,1_000_000), videoAfter = amplitude(output,1_000_000)
        print("notch carrier",before,after,"video",videoBefore,videoAfter)
        XCTAssertLessThan(after,before*0.05)
        XCTAssertEqual(videoAfter,videoBefore,accuracy: videoBefore*0.1)
    }
}
