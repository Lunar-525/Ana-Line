import XCTest
@testable import AnalogCore

/// The engine tests need a scene small enough to reason about analytically: two
/// stations on carriers 1.5 kHz apart, one at 0 dB and one at -3 dB, with an AM
/// and a USB receiver. The app ships an eight-slot rack instead, so this fixture
/// lives here rather than in `AnalogCore`.
private extension RadioSceneSettings {
    static func crosstalkDemo() -> Self {
        var result = Self()
        var a = RadioSceneTX(); a.toneHz = 440
        var b = RadioSceneTX(); b.toneHz = 880; b.carrierHz = 1500; b.powerDB = -3
        result.transmitters = [a,b]
        let receiver = RadioSceneRX()
        var sideband = RadioSceneRX(); sideband.mode = .usb
        result.receivers = [receiver,sideband]
        return result
    }
}

final class RadioSceneTests: XCTestCase {
    private func inputs(_ settings: RadioSceneSettings, start: Int, count: Int) -> [UUID:[Float]] {
        Dictionary(uniqueKeysWithValues: settings.transmitters.map { tx in
            (tx.id,(0..<count).map { n in tx.mode == .cw ? Float(((start+n)/2880)%2) : Float(0.12*sin(2 * Double.pi*tx.toneHz*Double(start+n)/48_000)) })
        })
    }
    private func amplitudes(_ pcm: [Float], frequency: Double) -> Double {
        let samples = Array(pcm.suffix(8192))
        var c = 0.0, s = 0.0
        for n in samples.indices {
            let angle = 2 * Double.pi*frequency*Double(n)/48_000
            c += Double(samples[n])*cos(angle); s += Double(samples[n])*sin(angle)
        }
        return 2*hypot(c,s)/Double(samples.count)
    }
    private func render(_ settings: RadioSceneSettings, engine: inout RadioSceneEngine, blocks: Int = 16) throws -> [UUID:[Float]] {
        var outputs: [UUID:[Float]] = [:]
        for _ in 0..<blocks {
            let data = inputs(settings,start: Int(engine.audioCursor),count: 1024)
            let frame = try engine.process(data,count: 1024,settings: settings,measure: false)
            for (id,reception) in frame.receptions { outputs[id,default: []] += reception.samples }
        }
        return outputs
    }
    func testCochannelInterferenceDisappearsWhenTXIsOff() throws {
        var settings = RadioSceneSettings.crosstalkDemo(); settings.noiseDB = -120
        settings.transmitters[1].carrierHz = 0; settings.transmitters[1].powerDB = 0
        settings.receivers = [settings.receivers[0]]
        var engine = RadioSceneEngine()
        let rx = settings.receivers[0].id
        let mixed = try render(settings,engine: &engine)[rx]!
        XCTAssertGreaterThan(amplitudes(mixed,frequency: 440),0.08)
        XCTAssertGreaterThan(amplitudes(mixed,frequency: 880),0.08)
        settings.transmitters[1].enabled = false
        let single = try render(settings,engine: &engine)[rx]!
        XCTAssertGreaterThan(amplitudes(single,frequency: 440),0.08)
        XCTAssertLessThan(amplitudes(single,frequency: 880),0.005)
    }
    func testSilentAMCarriersProduceRealBeatInterference() throws {
        var settings = RadioSceneSettings.crosstalkDemo(); settings.noiseDB = -120
        settings.receivers = [settings.receivers[0]]
        var engine = RadioSceneEngine(), output: [Float] = []
        for _ in 0..<16 {
            let silence = Dictionary(uniqueKeysWithValues: settings.transmitters.map { ($0.id,[Float](repeating: 0,count: 1024)) })
            let frame = try engine.process(silence,count: 1024,settings: settings,measure: false)
            output += frame.receptions[settings.receivers[0].id]!.samples
        }
        XCTAssertGreaterThan(amplitudes(output,frequency: 1500),0.3,
            "Silent audio must still beat when two RF carriers enter an AM detector")
    }
    func testFMCaptureTracksStrongerCochannelStation() throws {
        var settings = RadioSceneSettings.crosstalkDemo(); settings.noiseDB = -120
        for n in settings.transmitters.indices { settings.transmitters[n].mode = .fm; settings.transmitters[n].carrierHz = 0 }
        settings.transmitters[1].powerDB = -18
        settings.receivers = [settings.receivers[0]]; settings.receivers[0].mode = .fm
        var engine = RadioSceneEngine()
        let output = try render(settings,engine: &engine)[settings.receivers[0].id]!
        XCTAssertGreaterThan(amplitudes(output,frequency: 440),0.08)
        XCTAssertLessThan(amplitudes(output,frequency: 880),0.02)
    }
    func testReflectedRFPathChangesReception() throws {
        var settings = RadioSceneSettings.crosstalkDemo(); settings.noiseDB = -120
        settings.transmitters = [settings.transmitters[0]]; settings.receivers = [settings.receivers[0]]
        var baseline = RadioSceneEngine()
        let clean = try render(settings,engine: &baseline)[settings.receivers[0].id]!
        settings.echoGain = 0.8; settings.echoDelayMicroseconds = 30
        var constructive = RadioSceneEngine()
        let strong = try render(settings,engine: &constructive)[settings.receivers[0].id]!
        settings.echoDelayMicroseconds = 30.05
        var destructive = RadioSceneEngine()
        let weak = try render(settings,engine: &destructive)[settings.receivers[0].id]!
        let reference = amplitudes(clean,frequency: 440)
        XCTAssertGreaterThan(amplitudes(strong,frequency: 440)/reference,1.6)
        XCTAssertLessThan(amplitudes(weak,frequency: 440)/reference,0.35)
    }
    func testTwoReceiversSelectDifferentStations() throws {
        var settings = RadioSceneSettings.crosstalkDemo(); settings.noiseDB = -120
        settings.transmitters[1].carrierHz = 20_000; settings.transmitters[1].powerDB = 0
        settings.receivers[1].mode = .am; settings.receivers[1].tuningHz = 20_000
        var engine = RadioSceneEngine()
        let output = try render(settings,engine: &engine)
        let a = output[settings.receivers[0].id]!, b = output[settings.receivers[1].id]!
        XCTAssertGreaterThan(amplitudes(a,frequency: 440),0.08)
        XCTAssertLessThan(amplitudes(a,frequency: 880),0.006)
        XCTAssertGreaterThan(amplitudes(b,frequency: 880),0.08)
        XCTAssertLessThan(amplitudes(b,frequency: 440),0.006)
    }
    func testReceiverPositionsProduceIndependentFieldStrength() throws {
        var settings = RadioSceneSettings.crosstalkDemo(); settings.noiseDB = -120
        settings.transmitters = [settings.transmitters[0]]
        settings.receivers[1].mode = .am; settings.receivers[1].positionKm = -2
        var engine = RadioSceneEngine()
        let output = try render(settings,engine: &engine)
        let a = amplitudes(output[settings.receivers[0].id]!,frequency: 440)
        let b = amplitudes(output[settings.receivers[1].id]!,frequency: 440)
        XCTAssertEqual(b/a,1/3,accuracy: 0.03)
    }
    func testRFCarrierSpectraAndWrongDemodulation() throws {
        var settings = RadioSceneSettings.crosstalkDemo()
        settings.transmitters = [settings.transmitters[0]]; settings.transmitters[0].carrierHz = 40_000
        settings.receivers[0].tuningHz = 40_000; settings.receivers[1].tuningHz = 40_000; settings.receivers[1].mode = .cw
        var engine = RadioSceneEngine()
        for _ in 0..<8 { _ = try engine.process(inputs(settings,start: Int(engine.audioCursor),count: 1024),count: 1024,settings: settings,measure: false) }
        let frame = try engine.process(inputs(settings,start: Int(engine.audioCursor),count: 1024),count: 1024,settings: settings)
        let spectrum = try XCTUnwrap(frame.transmitSpectra[settings.transmitters[0].id])
        let peak = spectrum.powerDB.indices.max { spectrum.powerDB[$0] < spectrum.powerDB[$1] }!
        let frequency = (Double(peak)-Double(spectrum.powerDB.count)/2)*spectrum.binHz
        XCTAssertEqual(frequency,40_000,accuracy: spectrum.binHz)
        let first = frame.receptions[settings.receivers[0].id]!.samples
        let second = frame.receptions[settings.receivers[1].id]!.samples
        XCTAssertNotEqual(first,second)
        XCTAssertEqual(first.count,1024); XCTAssertEqual(second.count,1024)
        XCTAssertNotNil(frame.receptions[settings.receivers[1].id]?.spectrum)
    }
    func testFractionalPropagationDelayPreservesHighOffsetStationPower() throws {
        var settings = RadioSceneSettings.crosstalkDemo(); settings.noiseDB = -120
        settings.transmitters = [settings.transmitters[0]]; settings.receivers = [settings.receivers[0]]
        var base = RadioSceneEngine()
        let clean = try render(settings,engine: &base)[settings.receivers[0].id]!
        settings.transmitters[0].carrierHz = 240_000; settings.receivers[0].tuningHz = 240_000
        var shifted = RadioSceneEngine()
        let high = try render(settings,engine: &shifted)[settings.receivers[0].id]!
        XCTAssertEqual(amplitudes(high,frequency: 440)/amplitudes(clean,frequency: 440),1,accuracy: 0.03)
    }
    func testContinuousPartitionsAndMaximumStationCount() throws {
        var settings = RadioSceneSettings.crosstalkDemo(); settings.echoGain = 0.3; settings.echoDelayMicroseconds = 180
        var whole = RadioSceneEngine(), split = RadioSceneEngine()
        let count = 4096, full = try whole.process(inputs(settings,start: 0,count: count),count: count,settings: settings,measure: false)
        var outputs: [UUID:[Float]] = [:]
        for start in stride(from: 0,to: count,by: 128) {
            let frame = try split.process(inputs(settings,start: start,count: 128),count: 128,settings: settings,measure: false)
            for (id,result) in frame.receptions { outputs[id,default: []] += result.samples }
        }
        for (id,result) in full.receptions {
            XCTAssertEqual(outputs[id]!.count,result.samples.count)
            XCTAssertLessThan(zip(outputs[id]!,result.samples).map { abs($0-$1) }.max() ?? 0,0.0001)
        }
        while settings.transmitters.count < 8 { var next = RadioSceneTX(); next.carrierHz = Double(settings.transmitters.count-3)*30_000; settings.transmitters.append(next) }
        let modes = RadioSceneMode.allCases
        for n in settings.transmitters.indices { settings.transmitters[n].mode = modes[n % modes.count] }
        let frame = try whole.process(inputs(settings,start: count,count: 1024),count: 1024,settings: settings)
        XCTAssertEqual(frame.transmitSpectra.count,8); XCTAssertEqual(frame.receptions.count,2)
        XCTAssertTrue(frame.receptions.values.allSatisfy { $0.samples.count == 1024 && $0.samples.allSatisfy(\.isFinite) })
        settings.transmitters.append(RadioSceneTX())
        XCTAssertThrowsError(try settings.validate())
        settings.transmitters.removeLast(); settings.receivers.append(RadioSceneRX())
        XCTAssertThrowsError(try settings.validate())
    }
    func testReceptionLevelReportsSilenceMuteAndClipping() throws {
        var settings = RadioSceneSettings.crosstalkDemo(); settings.noiseDB = -120
        settings.transmitters[1].carrierHz = 0
        settings.receivers = [settings.receivers[0]]
        var engine = RadioSceneEngine()
        var levels: [Float] = []
        for _ in 0..<24 {
            let frame = try engine.process(inputs(settings,start: Int(engine.audioCursor),count: 1024),
                count: 1024,settings: settings,measure: false)
            levels.append(frame.receptions[settings.receivers[0].id]!.levelDB)
        }
        // Two carriers beating inside the detector must show up as real audio.
        XCTAssertGreaterThan(levels.last!, -40)
        // Overload is reported rather than hidden: co-channel AM can exceed 0 dBFS.
        XCTAssertTrue(levels.allSatisfy { $0.isFinite && $0 >= -100 })
        settings.receivers[0].enabled = false
        let muted = try engine.process(inputs(settings,start: Int(engine.audioCursor),count: 1024),
            count: 1024,settings: settings,measure: false)
        XCTAssertEqual(muted.receptions[settings.receivers[0].id]!.levelDB,-100,accuracy: 0.01)
        XCTAssertFalse(muted.receptions[settings.receivers[0].id]!.isClipping)
        XCTAssertEqual(RadioSceneReception.level(of: [0.5,-0.5]),20*log10(0.5),accuracy: 0.001)
        XCTAssertEqual(RadioSceneReception.level(of: []),-100,accuracy: 0.001)
        let clipped = RadioSceneReception(samples: [1],spectrum: nil,environment: nil,overloaded: false,
            levelDB: RadioSceneReception.level(of: [1]))
        XCTAssertTrue(clipped.isClipping)
        XCTAssertFalse(RadioSceneReception(samples: [0.1],spectrum: nil,environment: nil,overloaded: false,
            levelDB: RadioSceneReception.level(of: [0.1])).isClipping)
    }
    func testEnvironmentSpectrumShowsEveryCarrierBeforeTuning() throws {
        var settings = RadioSceneSettings.crosstalkDemo(); settings.noiseDB = -120
        settings.transmitters[0].carrierHz = -120_000
        settings.transmitters[1].carrierHz = 90_000
        settings.receivers = [settings.receivers[0]]
        settings.receivers[0].tuningHz = 0
        var engine = RadioSceneEngine()
        var frame: RadioSceneFrame?
        for _ in 0..<8 {
            frame = try engine.process(inputs(settings,start: Int(engine.audioCursor),count: 1024),
                count: 1024,settings: settings)
        }
        let reception = try XCTUnwrap(frame?.receptions[settings.receivers[0].id])
        let environment = try XCTUnwrap(reception.environment)
        func peak(_ frequency: Double) -> Float {
            let index = Int(frequency/environment.binHz)+environment.powerDB.count/2
            let lo = max(0,index-3), hi = min(environment.powerDB.count,index+4)
            return environment.powerDB[lo..<hi].max() ?? -200
        }
        // Both stations appear at their real offsets; between them it is noise.
        XCTAssertGreaterThan(peak(-120_000),peak(-15_000)+20)
        XCTAssertGreaterThan(peak(90_000),peak(-15_000)+20)
        // The narrowband tap stays empty because the receiver is tuned elsewhere.
        XCTAssertEqual(reception.spectrum?.sampleRate,96_000)
        XCTAssertEqual(reception.environment?.sampleRate,RadioSceneSettings.sampleRate)
        XCTAssertEqual(reception.environment?.centerHz,0)
    }
    func testInvalidBlockDoesNotAdvanceClock() throws {
        var engine = RadioSceneEngine(), settings = RadioSceneSettings.crosstalkDemo()
        XCTAssertThrowsError(try engine.process([settings.transmitters[0].id: [.nan]],count: 1,settings: settings))
        XCTAssertEqual(engine.audioCursor,0)
        settings.transmitters[1].id = settings.transmitters[0].id
        XCTAssertThrowsError(try settings.validate())
        settings = .crosstalkDemo(); settings.transmitters[0].carrierHz = 400_000
        XCTAssertThrowsError(try settings.validate())
    }
    func testEightTXTwoRXRealtimeBudget() throws {
        #if DEBUG
        throw XCTSkip("Measure production DSP with -c release")
        #else
        var settings = RadioSceneSettings.crosstalkDemo()
        while settings.transmitters.count < 8 { settings.transmitters.append(RadioSceneTX()) }
        for n in settings.transmitters.indices { settings.transmitters[n].mode = .fm; settings.transmitters[n].carrierHz = Double(n-4)*50_000 }
        for n in settings.receivers.indices { settings.receivers[n].mode = .fm }
        var engine = RadioSceneEngine()
        _ = try engine.process(inputs(settings,start: 0,count: 1024),count: 1024,settings: settings)
        let clock = ContinuousClock.now
        for n in 0..<24 { _ = try engine.process(inputs(settings,start: Int(engine.audioCursor),count: 1024),count: 1024,settings: settings,measure: n % 4 == 0) }
        let d = clock.duration(to: .now).components
        let mean = (Double(d.seconds)+Double(d.attoseconds)/1e18)/24
        print("RADIO_SCENE_REALTIME 8 TX / 2 RX: \(mean*1000) ms / 21.33 ms")
        XCTAssertLessThan(mean,1024/48_000.0)
        #endif
    }
}
