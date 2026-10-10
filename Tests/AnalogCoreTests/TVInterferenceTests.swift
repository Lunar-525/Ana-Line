import XCTest
@testable import AnalogCore

/// Step 5 acceptance: image/sound cross-modulation must arise inside the shared
/// signal chain, and the optional video low-pass must not damage the picture.
final class TVInterferenceTests: XCTestCase {
    private func tone(_ system: TerrestrialSystem, frame: Int64, amplitude: Double = 0.25) -> [Float] {
        let start = TVSoundClock.offset(frame: frame,standard: system.video)
        return (0..<TVSoundClock.count(frame: frame,standard: system.video)).map {
            Float(amplitude*sin(2 * .pi * 1000 * Double(start+Int64($0))/48_000))
        }
    }
    private func silence(_ system: TerrestrialSystem, frame: Int64) -> [Float] {
        [Float](repeating: 0,count: TVSoundClock.count(frame: frame,standard: system.video))
    }
    private func settings(_ system: TerrestrialSystem, nonlinear: Bool) -> TerrestrialSettings {
        var s = TerrestrialSettings(system: system)
        s.carrierToNoiseDB = 90
        if nonlinear {
            s.frontEnd.enabled = true
            s.frontEnd.inputSaturationDB = -20
            s.frontEnd.inputHardness = 1
            s.frontEnd.inputAMPMDegrees = 20
            s.frontEnd.ifSaturationDB = -20
            s.frontEnd.ifHardness = 1
            s.frontEnd.ifAMPMDegrees = 20
        }
        return s
    }
    private func flat(_ system: TerrestrialSystem, level: Float = 0.4) throws -> TVFrame {
        try TVFrame(standard: system.video,
            rgb: [SIMD3<Float>](repeating: SIMD3(level,level,level),count: system.video.width*system.video.height))
    }

    /// Sound to vision: adding the companion modulation must change the decoded
    /// picture only when the shared front end is nonlinear.
    private func pictureDelta(_ system: TerrestrialSystem, nonlinear: Bool) throws -> Float {
        var with = TVUnifiedChannelEngine(system: system)
        var without = TVUnifiedChannelEngine(system: system)
        let s = settings(system,nonlinear: nonlinear)
        let source = TVFrame.colorBars(system.video)
        var delta: Float = 0
        for frame: Int64 in 0..<4 {
            let composite = try TVEngine.encode(source,frameIndex: frame)
            let a = try with.process(composite,settings: s,audio: tone(system,frame: frame))
            let b = try without.process(composite,settings: s,audio: silence(system,frame: frame))
            if frame >= 2 {
                for (x,y) in zip(a.frame.rgb,b.frame.rgb) {
                    for c in 0..<3 { delta = max(delta,abs(x[c]-y[c])) }
                }
            }
        }
        return delta
    }

    /// Vision to sound: changing picture content must pollute the recovered PCM
    /// only when the shared front end is nonlinear.
    private func soundDelta(_ system: TerrestrialSystem, nonlinear: Bool) throws -> Float {
        var bars = TVUnifiedChannelEngine(system: system)
        var flatEngine = TVUnifiedChannelEngine(system: system)
        let s = settings(system,nonlinear: nonlinear)
        let source = TVFrame.colorBars(system.video)
        let grey = try flat(system)
        var delta: Float = 0
        for frame: Int64 in 0..<5 {
            let a = try bars.process(TVEngine.encode(source,frameIndex: frame),settings: s,audio: tone(system,frame: frame))
            let b = try flatEngine.process(TVEngine.encode(grey,frameIndex: frame),settings: s,audio: tone(system,frame: frame))
            if frame >= 3 {
                for (x,y) in zip(a.audio,b.audio) { delta = max(delta,abs(x-y)) }
            }
        }
        return delta
    }

    func testSoundToVisionInterferenceRequiresFrontEndNonlinearity() throws {
        for system in TerrestrialSystem.allCases {
            let linear = try pictureDelta(system,nonlinear: false)
            let compressed = try pictureDelta(system,nonlinear: true)
            print("interference sound->vision",system.rawValue,"linear",linear,"compressed",compressed)
            XCTAssertGreaterThan(compressed,linear+0.05,"A compressed front end must add in-band cross-modulation")
        }
    }

    func testVisionToSoundInterferenceRequiresFrontEndNonlinearity() throws {
        for system in TerrestrialSystem.allCases {
            let linear = try soundDelta(system,nonlinear: false)
            let compressed = try soundDelta(system,nonlinear: true)
            print("interference vision->sound",system.rawValue,"linear",linear,"compressed",compressed)
            XCTAssertGreaterThan(compressed,linear*1.5,"A compressed front end must add picture content to the sound")
            XCTAssertGreaterThan(compressed,0.001)
        }
    }

    func testOptionalVideoLowpassKeepsPictureAccurate() throws {
        for system in TerrestrialSystem.allCases {
            var engine = TVUnifiedChannelEngine(system: system)
            var s = TerrestrialSettings(system: system)
            s.carrierToNoiseDB = 100
            s.frontEnd.videoLowpassEnabled = true
            let source = TVFrame.colorBars(system.video)
            for frame: Int64 in 0..<4 {
                let result = try engine.process(TVEngine.encode(source,frameIndex: frame),settings: s)
                XCTAssertEqual(result.lock,.locked)
                if frame == 3 {
                    for x in stride(from: 45, to: 720, by: 90) {
                        let pixel = (system.video.height/4)*720+x
                        for c in 0..<3 {
                            XCTAssertEqual(result.frame.rgb[pixel][c],source.rgb[pixel][c],accuracy: 0.12)
                        }
                    }
                }
            }
        }
    }
}
