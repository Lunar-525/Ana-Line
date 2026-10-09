import XCTest
@testable import AnalogCore

final class TVDamageTests: XCTestCase {
    func testChunkedFIRRetainsCausalOverlapAtWorkerAndFrameBoundaries() {
        let kernel = (0..<97).map { Float(cos(Double($0)*0.2)/97) }
        var serial = TelevisionFIR(kernel), parallel = TelevisionFIR(kernel)
        var input = [Float](repeating: 0,count: 280_003)
        input[0] = 1; input[input.count/2-1] = -0.7; input[input.count/2] = 0.5; input[input.count-1] = 0.8
        for frame in 0..<3 {
            let a = serial.process(input), b = parallel.process(input,chunks: 2)
            XCTAssertLessThan(zip(a,b).map { abs($0-$1) }.max() ?? 0,2e-6)
            if frame == 0 { input = [Float](repeating: 0,count: input.count) }
        }
    }

    func testDisabledEncoderIsExactAndLuminanceDependentColorError() throws {
        let s = TVStandard.ntsc
        var rgb = [SIMD3<Float>](repeating: .zero,count: s.width*s.height)
        for row in 0..<s.height { for x in 0..<s.width {
            let base: Float = x < s.width/2 ? 0.15 : 0.6
            rgb[row*s.width+x] = SIMD3(base+0.12,base,base)
        } }
        let picture = try TVFrame(standard: s,rgb: rgb)
        let normal = try TVEngine.encode(picture,frameIndex: 7)
        var damage = TVEncoderDamageSettings(); damage.differentialGain = 0.7; damage.differentialPhaseDegrees = 65
        XCTAssertEqual(normal.samples,try TVEngine.encode(picture,frameIndex: 7,damage: damage).samples)
        damage.enabled = true
        let broken = try TVEngine.encode(picture,frameIndex: 7,damage: damage)
        let clean = try TVEngine.decode(normal), affected = try TVEngine.decode(broken)
        func error(_ x: Int) -> Float {
            let i = s.height/2*s.width+x, a = clean.frame.rgb[i], b = affected.frame.rgb[i]
            return abs(a.x-b.x)+abs(a.y-b.y)+abs(a.z-b.z)
        }
        XCTAssertGreaterThan(error(540),error(180)*1.5)
        damage.burstAmplitude = 0
        XCTAssertEqual(try TVEngine.decode(TVEngine.encode(picture,damage: damage)).colorLockedLines,0)
    }

    func testBurstDriftUsesAbsoluteVideoTime() throws {
        let picture = TVFrame.colorBars(.ntsc)
        var d = TVEncoderDamageSettings(); d.enabled = true; d.burstDriftDegrees = 60; d.burstDriftHz = 1
        let a = try TVEngine.encode(picture,frameIndex: 0,damage: d)
        let b = try TVEngine.encode(picture,frameIndex: 8,damage: d)
        let c = try TVEngine.encode(picture,frameIndex: 8,damage: d)
        XCTAssertEqual(b.samples,c.samples)
        XCTAssertNotEqual(a.samples,b.samples)
    }

    func testAGCTransientSettlesAndUnderdampedServoOvershoots() {
        var slow = TVAGCDynamics(), ringing = TVAGCDynamics()
        _ = slow.step(target: 1,seconds: 0.04,responseMS: 250,overshoot: 0)
        _ = ringing.step(target: 1,seconds: 0.04,responseMS: 250,overshoot: 0.8)
        let first = slow.step(target: 4,seconds: 0.04,responseMS: 250,overshoot: 0)
        XCTAssertGreaterThan(first,1); XCTAssertLessThan(first,2)
        var maximum: Float = 0, final: Float = 0
        for _ in 0..<75 {
            final = slow.step(target: 4,seconds: 0.04,responseMS: 250,overshoot: 0)
            maximum = max(maximum,ringing.step(target: 4,seconds: 0.04,responseMS: 250,overshoot: 0.8))
        }
        XCTAssertEqual(final,4,accuracy: 0.001); XCTAssertGreaterThan(maximum,4.2)
    }

    func testRasterCircuitFreeRunsAndRecapturesWithoutChangingSignal() {
        let s = TVStandard.pal, period = s.samplesPerLine
        let t = TVSyncTiming(origin: 0,samplesPerLine: period,edges: (20..<300).map { Int(Double($0)*period) })
        var r = TVRasterDynamics(), d = TVReceiverDamageSettings()
        let unchanged = r.apply(t,standard: s,settings: d,horizontalDetected: true,verticalDetected: true,seed: 1)
        XCTAssertEqual(unchanged.0.edges,t.edges)
        d.syncEnabled = true; d.horizontalResponseMS = 20; d.horizontalOscillatorPPM = 400
        d.verticalHoldHz = 2; d.verticalCaptureLines = 0
        let shifted = r.apply(t,standard: s,settings: d,horizontalDetected: true,verticalDetected: true,seed: 1)
        XCTAssertNotEqual(shifted.0.edges,t.edges); XCTAssertGreaterThan(abs(shifted.0.origin),period)
        XCTAssertFalse(shifted.2)
        d.verticalHoldHz = 0; d.verticalCaptureLines = 40
        var recovered = shifted
        for _ in 0..<40 { recovered = r.apply(t,standard: s,settings: d,horizontalDetected: true,verticalDetected: true,seed: 1) }
        XCTAssertTrue(recovered.2); XCTAssertLessThan(abs(recovered.0.origin),period*0.01)
    }

    func testVSBGroupDelayChangesImpulseAndKeepsStreamingContinuity() throws {
        let s = TVStandard.ntsc
        var samples = [Float](repeating: 0,count: Int(s.sampleOffset(frame: 1)-s.sampleOffset(frame: 0))); samples[3000] = 0.7
        let input = try CompositeVideo(standard: s,frameIndex: 0,samples: samples)
        var a = VSBModulator(system: .ntscM), b = VSBModulator(system: .ntscM)
        var d = TVVSBFilterSettings(); d.enabled = true; d.groupDelayNS = 400; d.peakingDB = 8; d.transitionMHz = 0.05
        let clean = try a.modulate(input), distorted = try b.modulate(input,filter: d)
        XCTAssertGreaterThan(zip(clean.i,distorted.i).map { abs($0-$1) }.max() ?? 0,0.02)
        XCTAssertTrue(distorted.i.allSatisfy(\.isFinite)); XCTAssertTrue(distorted.q.allSatisfy(\.isFinite))
        var c = VSBModulator(system: .ntscM)
        let disabled = try c.modulate(input)
        XCTAssertEqual(clean.i,disabled.i)
    }

    func testYCLeakageAndCombFailureChangeFineTexture() throws {
        let s = TVStandard.ntsc
        let rgb = (0..<s.width*s.height).map { index -> SIMD3<Float> in
            let x = index%s.width, y = index/s.width
            return SIMD3(repeating: (x+(y/2)%3)%4 < 2 ? 0.9 : 0.1)
        }
        let signal = try TVEngine.encode(TVFrame(standard: s,rgb: rgb))
        var d = TVDecoderSettings(); d.separation = .comb
        let clean = try TVEngine.decode(signal,settings: d)
        d.combFailure = 1; d.chromaLeakage = 0.7
        let damaged = try TVEngine.decode(signal,settings: d)
        let difference = zip(clean.frame.rgb,damaged.frame.rgb).reduce(Float(0)) { $0+abs($1.0.x-$1.1.x)+abs($1.0.z-$1.1.z) }
        XCTAssertGreaterThan(difference/Float(rgb.count),0.03)
    }

    func testAudioOverdriveProducesOddHarmonicsAfterFMReception() throws {
        let s = TerrestrialSystem.palDK
        var a = TerrestrialSoundEngine(system: s), b = TerrestrialSoundEngine(system: s)
        var clean = TerrestrialSettings(system: s); clean.carrierToNoiseDB = 90
        var broken = clean; broken.transmitter.audioDriveDB = 20
        var normal: [Float] = [], distorted: [Float] = []
        for frame: Int64 in 0..<8 {
            let start = TVSoundClock.offset(frame: frame,standard: s.video)
            let pcm = (0..<TVSoundClock.count(frame: frame,standard: s.video)).map { Float(0.25*sin(2 * .pi * 1000*Double(start+Int64($0))/48000)) }
            let x = try a.process(pcm,frameIndex: frame,settings: clean), y = try b.process(pcm,frameIndex: frame,settings: broken)
            if frame > 1 { normal += x.samples; distorted += y.samples }
        }
        func harmonic(_ data: [Float],_ hz: Double) -> Double {
            var c = 0.0, s = 0.0
            for (n,x) in data.enumerated() { let p = 2 * Double.pi*hz*Double(n)/48000; c += Double(x)*cos(p); s += Double(x)*sin(p) }
            return 2*hypot(c,s)/Double(data.count)
        }
        XCTAssertGreaterThan(harmonic(distorted,3000),harmonic(normal,3000)+0.03)
    }

    func testVerticalRollUsesCyclicSampleTimingInsteadOfBlankingWholePicture() throws {
        let s = TVStandard.ntsc, period = s.samplesPerLine
        var rgb = [SIMD3<Float>](repeating: .zero,count: s.width*s.height)
        for row in 0..<s.height { for x in 0..<s.width { rgb[row*s.width+x] = SIMD3(repeating: Float(row)/Float(s.height)) } }
        let signal = try TVEngine.encode(TVFrame(standard: s,rgb: rgb))
        let edges = (0..<s.height).map { Int((s.activeLine($0)*period).rounded()) }.sorted()
        let timing = TVSyncTiming(origin: 37.4*period,samplesPerLine: period,edges: edges,wrapFrame: true)
        let roll = try TVEngine.decode(signal,timing: timing)
        XCTAssertGreaterThan(roll.recoveredLines,s.height*85/100)
        XCTAssertGreaterThan(roll.frame.rgb[80*s.width+360].x,Float(80)/Float(s.height)+0.1)
    }

    func testSharedPAEnvelopeAffectsConstantFMCarrier() {
        var d = TVTransmitterSettings(); d.enabled = true; d.backoffDB = 0; d.sharedCoupling = 1; d.phaseDegrees = 30
        var a = TVTransmitterAmplifier(), b = TVTransmitterAmplifier()
        let i = [Float](repeating: 0.316,count: 4096), q = [Float](repeating: 0,count: i.count)
        let isolated = a.apply(i: i,q: q,settings: d,execution: .accelerated)
        let shared = b.apply(i: i,q: q,settings: d,execution: .accelerated,otherPower: [1])
        XCTAssertLessThan(shared.0.last!,isolated.0.last!*0.8)
        XCTAssertGreaterThan(abs(shared.1.last!),abs(isolated.1.last!)*2)
    }

    func testNewRFModelsMatchScalarWithContinuousState() throws {
        let system = TerrestrialSystem.ntscM
        var a = TerrestrialEngine(system: system), b = TerrestrialEngine(system: system)
        var d = TerrestrialSettings(system: system)
        d.transmitter.enabled = true; d.transmitter.sharedCoupling = 0.4
        d.transmitter.vsb.enabled = true; d.transmitter.vsb.groupDelayNS = 100
        d.receiverDamage.agcEnabled = true; d.receiverDamage.agcOvershoot = 0.3
        d.receiverDamage.agcPictureSensitivity = 0.2
        d.receiverDamage.syncEnabled = true; d.receiverDamage.horizontalJitterUS = 0.4
        d.decoder.separation = .comb; d.decoder.combFailure = 0.3; d.decoder.chromaLeakage = 0.1
        let picture = TVFrame.colorBars(system.video)
        for frame: Int64 in 0..<3 {
            if frame == 1 { d.signalDB = -8 }
            let input = try TVEngine.encode(picture,frameIndex: frame)
            let audio = [Float](repeating: 0.1,count: TVSoundClock.count(frame: frame,standard: system.video))
            d.execution = .reference
            let scalar = try a.process(input,settings: d,audio: audio)
            d.execution = .accelerated
            let parallel = try b.process(input,settings: d,audio: audio)
            let error = zip(scalar.frame.rgb,parallel.frame.rgb).map { max(abs($0.x-$1.x),abs($0.y-$1.y),abs($0.z-$1.z)) }.max() ?? 0
            XCTAssertLessThan(error,0.0001)
            XCTAssertLessThan(zip(scalar.audio,parallel.audio).map { abs($0-$1) }.max() ?? 0,0.0001)
        }
    }

    func testInvalidDamageParametersAreRejected() {
        var settings = TerrestrialSettings()
        settings.transmitter.encoder.burstDriftHz = .nan
        XCTAssertThrowsError(try settings.validate(rate: TVStandard.pal.sampleRate))
        settings = .init(); settings.receiverDamage.agcResponseMS = 0
        XCTAssertThrowsError(try settings.validate(rate: TVStandard.pal.sampleRate))
        settings = .init(); settings.decoder.chromaLeakage = 2
        XCTAssertThrowsError(try settings.validate(rate: TVStandard.pal.sampleRate))
    }
}
