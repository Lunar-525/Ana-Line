import XCTest
@testable import AnalogCore

final class TVFrontEndTests: XCTestCase {
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

    private func channel(_ system: TerrestrialSystem, hz: Double, amplitude: Float,
                         components: Int = 1) -> TVChannelIQ {
        let count = Int(system.video.sampleOffset(frame: 1)-system.video.sampleOffset(frame: 0))
        let rate = system.video.sampleRate
        var i = [Float](repeating: 0,count: count), q = i
        for n in 0..<count {
            var value = 0.0
            for c in 0..<components {
                value += Double(amplitude)*cos(2*Double.pi*(hz+Double(c)*60_000)*Double(n)/rate)
            }
            i[n] = Float(value)
            q[n] = Float(value)
        }
        return TVChannelIQ(system: system,frameIndex: 0,firstSampleIndex: 0,sampleRate: rate,i: i,q: q)
    }

    // MARK: - Front-end settings migration

    func testLegacySettingsWithoutFrontEndStillDecode() throws {
        var settings = TerrestrialSettings(system: .palDK)
        settings.carrierToNoiseDB = 33
        let encoded = try JSONEncoder().encode(settings)
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        object.removeValue(forKey: "frontEnd")
        let legacy = try JSONSerialization.data(withJSONObject: object)
        let decoded = try JSONDecoder().decode(TerrestrialSettings.self,from: legacy)
        XCTAssertEqual(decoded.carrierToNoiseDB,33)
        XCTAssertEqual(decoded.frontEnd,TVFrontEndSettings())
        settings.frontEnd.enabled = true; settings.frontEnd.inputSaturationDB = -10
        settings.frontEnd.ifAMPMDegrees = 4
        let roundTrip = try JSONDecoder().decode(TerrestrialSettings.self,from: JSONEncoder().encode(settings))
        XCTAssertEqual(roundTrip.frontEnd,settings.frontEnd)
    }

    // MARK: - Amplifier model

    func testReceiverAmplifierBypassAndCompression() {
        let rate = 2_000_000.0, hz = 200_000.0
        let count = 4_096
        var i = [Float](repeating: 0,count: count), q = i
        for n in 0..<count {
            let phase = 2*Double.pi*hz*Double(n)/rate
            i[n] = Float(0.3*cos(phase)); q[n] = Float(0.3*sin(phase))
        }
        var amplifier = TVReceiverAmplifier()
        var transparentI = i, transparentQ = q
        let overloaded = amplifier.apply(i: &transparentI,q: &transparentQ,
            saturationPower: 1e12,hardness: 0.5,amPMDegrees: 0)
        XCTAssertFalse(overloaded)
        for n in 0..<count {
            XCTAssertEqual(transparentI[n],i[n],accuracy: 1e-6)
            XCTAssertEqual(transparentQ[n],q[n],accuracy: 1e-6)
        }
        var compressedI = i, compressedQ = q
        let compressed = amplifier.apply(i: &compressedI,q: &compressedQ,
            saturationPower: 0.09,hardness: 0.5,amPMDegrees: 0)
        let recovered = correlation(compressedI,compressedQ,rate: rate,hz: hz,range: 512..<count)
        print("RX amplifier tone",recovered,"overloaded",compressed)
        // Fundamental amplitude is compressed below the input 0.3, not silenced.
        XCTAssertLessThan(recovered,0.3*0.95)
        XCTAssertGreaterThan(recovered,0.3*0.75)
    }

    func testReceiverAmplifierCreatesThirdOrderProducts() {
        let rate = 2_000_000.0
        let f1 = 200_000.0, f2 = 260_000.0, im3 = 2*f1-f2
        let count = 8_192
        var i = [Float](repeating: 0,count: count), q = i
        for n in 0..<count {
            let a = 2*Double.pi*f1*Double(n)/rate, b = 2*Double.pi*f2*Double(n)/rate
            i[n] = Float(0.4*cos(a)+0.4*cos(b)); q[n] = Float(0.4*sin(a)+0.4*sin(b))
        }
        var cleanI = i, cleanQ = q
        var amplifier = TVReceiverAmplifier()
        _ = amplifier.apply(i: &cleanI,q: &cleanQ,saturationPower: 1e12,hardness: 0.5,amPMDegrees: 0)
        var drivenI = i, drivenQ = q
        _ = amplifier.apply(i: &drivenI,q: &drivenQ,saturationPower: 0.1,hardness: 0.5,amPMDegrees: 0)
        let cleanIM = correlation(cleanI,cleanQ,rate: rate,hz: im3,range: 256..<count)
        let drivenIM = correlation(drivenI,drivenQ,rate: rate,hz: im3,range: 256..<count)
        let fundamental = correlation(drivenI,drivenQ,rate: rate,hz: f1,range: 256..<count)
        print("RX IM3 clean",cleanIM,"driven",drivenIM,"fundamental",fundamental)
        // The clean reference only has window leakage at this bin; the driven
        // amplifier adds a real third-order product well above it.
        XCTAssertLessThan(cleanIM,drivenIM/10)
        XCTAssertGreaterThan(drivenIM,0.01)
        XCTAssertGreaterThan(fundamental,drivenIM*2)
    }

    // MARK: - Front-end integration

    func testFrontEndInfiniteHeadroomMatchesCleanReference() throws {
        let system = TerrestrialSystem.palDK
        let input = channel(system,hz: 1_000_000,amplitude: 0.3)
        var settings = TerrestrialSettings(system: system); settings.carrierToNoiseDB = 90
        var clean = TVReceiverFrontEnd(system: system), highHeadroom = TVReceiverFrontEnd(system: system)
        let reference = try clean.process(input,settings: settings)
        var driven = settings
        driven.frontEnd.enabled = true
        driven.frontEnd.inputSaturationDB = 60; driven.frontEnd.ifSaturationDB = 60
        let attenuated = try highHeadroom.process(input,settings: driven)
        XCTAssertFalse(attenuated.overloaded)
        var error: Float = 0
        for n in reference.i.indices {
            error = max(error,abs(reference.i[n]-attenuated.i[n]),abs(reference.q[n]-attenuated.q[n]))
        }
        print("front end headroom error",error,"inputPowerDB",attenuated.inputPowerDB)
        XCTAssertLessThan(error,1e-5)
    }

    func testFrontEndCommonGainAppliesExactlyOnce() throws {
        let system = TerrestrialSystem.palDK
        let input = channel(system,hz: 1_000_000,amplitude: 0.2)
        var unitySettings = TerrestrialSettings(system: system); unitySettings.carrierToNoiseDB = 90
        var gainSettings = unitySettings; gainSettings.frontEnd.gainDB = 6
        var unity = TVReceiverFrontEnd(system: system), gained = TVReceiverFrontEnd(system: system)
        let a = try unity.process(input,settings: unitySettings)
        let b = try gained.process(input,settings: gainSettings)
        func power(_ x: [Float], _ y: [Float]) -> Double {
            var sum = 0.0
            for n in x.indices { sum += Double(x[n]*x[n]+y[n]*y[n]) }
            return sum/Double(x.count)
        }
        let ratio = power(b.i,b.q)/power(a.i,a.q)
        print("front end gain ratio",ratio,"reported",b.gainDB)
        XCTAssertEqual(ratio,4,accuracy: 0.02)
        XCTAssertEqual(b.gainDB,6)
    }

    func testCommonFrontEndAGCDrivesSharedGainOnce() throws {
        for system in TerrestrialSystem.allCases {
            var engine = TVUnifiedChannelEngine(system: system)
            var settings = TerrestrialSettings(system: system)
            settings.signalDB = -20; settings.carrierToNoiseDB = 90
            settings.frontEnd.agcEnabled = true
            let source = TVFrame.colorBars(system.video)
            var lastGainDB: Float = 0, locked = 0
            for frame: Int64 in 0..<6 {
                let result = try engine.process(TVEngine.encode(source,frameIndex: frame),settings: settings)
                lastGainDB = result.frontEndGainDB
                if result.lock == .locked { locked += 1 }
            }
            print("common AGC",system.rawValue,"gainDB",lastGainDB,"locked",locked)
            XCTAssertEqual(lastGainDB,20,accuracy: 2,"Shared gain must converge to the measured 20 dB loss")
            XCTAssertGreaterThanOrEqual(locked,4,"Front-end AGC must recover lock on the attenuated signal")
        }
    }

    func testFrontEndOverloadCompressesStrongInput() throws {
        let system = TerrestrialSystem.palDK
        let input = channel(system,hz: 1_000_000,amplitude: 0.5)
        var settings = TerrestrialSettings(system: system); settings.carrierToNoiseDB = 90
        settings.frontEnd.enabled = true
        settings.frontEnd.inputSaturationDB = -12
        settings.frontEnd.inputHardness = 0.6
        var clean = TVReceiverFrontEnd(system: system), driven = TVReceiverFrontEnd(system: system)
        var bypass = settings; bypass.frontEnd.enabled = false
        let reference = try clean.process(input,settings: bypass)
        let compressed = try driven.process(input,settings: settings)
        func amplitude(_ x: [Float], _ y: [Float]) -> Double {
            correlation(x,y,rate: system.video.sampleRate,hz: 1_000_000,range: 1024..<x.count)
        }
        print("front end overload",amplitude(reference.i,reference.q),amplitude(compressed.i,compressed.q),
              "overloaded",compressed.overloaded)
        XCTAssertTrue(compressed.overloaded)
        XCTAssertLessThan(amplitude(compressed.i,compressed.q),amplitude(reference.i,reference.q)*0.95)
    }
}
