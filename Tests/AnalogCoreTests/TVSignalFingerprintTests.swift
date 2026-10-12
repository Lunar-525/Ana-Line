import XCTest
@testable import AnalogCore

/// Bit-level fingerprint of the unified channel path.
///
/// P2 exists to change *when* work happens, never *what* it computes. Every
/// structural refactor (chain split, frame pipeline, deferred construction, and
/// the receive-half split still to come) is therefore checked against a recorded
/// fingerprint of the whole signal: one changed bit anywhere fails loudly.
///
/// The expected values are recorded from the reference implementation; if a
/// change is genuinely intended to alter the signal, this test is where that has
/// to be acknowledged explicitly.
final class TVSignalFingerprintTests: XCTestCase {
    private static let expected: [String: UInt64] = [
        "PAL-D/K": 842533699000995399, "NTSC-M": 5808328073038609714,
    ]

    private static func fnv(_ hash: UInt64, _ value: Float) -> UInt64 {
        var h = hash
        withUnsafeBytes(of: value.bitPattern) { bytes in
            for byte in bytes { h = (h ^ UInt64(byte)) &* 0x100000001b3 }
        }
        return h
    }
    private static func fnv(_ hash: UInt64, _ value: Double) -> UInt64 {
        var h = hash
        withUnsafeBytes(of: value.bitPattern) { bytes in
            for byte in bytes { h = (h ^ UInt64(byte)) &* 0x100000001b3 }
        }
        return h
    }

    private func fingerprint(system: TerrestrialSystem) throws -> UInt64 {
        var settings = TerrestrialSettings(system: system)
        settings.echoGain = 0.15; settings.echoDelayMicroseconds = 4.3
        settings.echoPhaseDegrees = 30; settings.tuningOffsetKHz = 20
        settings.transmitter.enabled = true; settings.transmitter.powerDB = 3
        settings.transmitter.sharedCoupling = 0.15
        settings.transmitter.encoder.enabled = true
        settings.transmitter.encoder.differentialGain = 0.05
        settings.transmitter.vsb.enabled = true
        settings.receiverDamage.agcEnabled = true
        settings.receiverDamage.syncEnabled = true
        settings.propagation.enabled = true
        settings.propagation.weather.enabled = true
        settings.propagation.weather.rainMMHour = 10
        settings.performance = .mobile
        let source = TVFrame.colorBars(system.video)
        var engine = TVUnifiedChannelEngine(system: system)
        var hash: UInt64 = 0xcbf29ce484222325
        for n in 0..<3 {
            let index = Int64(n)
            let start = TVSoundClock.offset(frame: index,standard: system.video)
            let audio = (0..<TVSoundClock.count(frame: index,standard: system.video)).map {
                Float(0.25*sin(2 * Double.pi * 1000 * Double(start+Int64($0))/48_000))
            }
            let input = try TVEngine.encode(source,frameIndex: index,damage: settings.transmitter.encoder)
            let result = try engine.process(input,settings: settings,audio: audio)
            for pixel in result.frame.rgb {
                hash = Self.fnv(hash,pixel.x); hash = Self.fnv(hash,pixel.y); hash = Self.fnv(hash,pixel.z)
            }
            for sample in result.audio { hash = Self.fnv(hash,sample) }
            hash = Self.fnv(hash,result.agcDB)
            hash = Self.fnv(hash,result.carrierErrorHz)
            hash = Self.fnv(hash,result.soundCarrierDB)
            hash = Self.fnv(hash,Double(result.recoveredLines))
            hash = Self.fnv(hash,Double(result.colorLockedLines))
            hash = Self.fnv(hash,result.lock == .locked ? 1.0 : 0.0)
            hash = Self.fnv(hash,Double(result.carrierEstimationDecimation))
            hash = Self.fnv(hash,Double(result.carrierPLLStrideUsed))
            hash = Self.fnv(hash,result.transmitter.forwardPower)
        }
        return hash
    }

    func testUnifiedPathFingerprintIsStable() throws {
        for system in TerrestrialSystem.allCases {
            let value = try fingerprint(system: system)
            let name = system.rawValue
            guard let expected = Self.expected[name], expected != 0 else {
                print("FINGERPRINT \(name) = \(value)")
                continue
            }
            XCTAssertEqual(value,expected,"\(name): the unified path must stay bit-identical")
        }
    }
}
