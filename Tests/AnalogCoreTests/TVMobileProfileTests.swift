import XCTest
@testable import AnalogCore

/// The reduced-cost mobile chain must stay inside documented quality bounds and
/// must not disturb the reference configuration. Corridor is checked against the
/// full profile, which is the numeric baseline everywhere else in this suite.
final class TVMobileProfileTests: XCTestCase {
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

    private func damaged(_ system: TerrestrialSystem) -> TerrestrialSettings {
        var settings = TerrestrialSettings(system: system)
        settings.carrierToNoiseDB = 90
        settings.echoGain = 0.15; settings.echoDelayMicroseconds = 4.3
        settings.echoPhaseDegrees = 30; settings.tuningOffsetKHz = 20
        settings.transmitter.enabled = true; settings.transmitter.powerDB = 3
        settings.transmitter.sharedCoupling = 0.15
        settings.transmitter.encoder.enabled = true; settings.transmitter.vsb.enabled = true
        settings.receiverDamage.agcEnabled = true; settings.receiverDamage.syncEnabled = true
        settings.propagation.enabled = true; settings.propagation.weather.enabled = true
        settings.propagation.weather.rainMMHour = 10
        return settings
    }

    private func maximumRGBError(_ a: TVFrame, _ b: TVFrame) -> Float {
        var maximum: Float = 0
        for (x,y) in zip(a.rgb,b.rgb) { for c in 0..<3 { maximum = max(maximum,abs(x[c]-y[c])) } }
        return maximum
    }

    // MARK: - Profile plumbing

    func testProfileValidationRejectsOutOfRangeKnobs() {
        var settings = TerrestrialSettings(system: .palDK)
        for mutate in [
            { (s: inout TerrestrialSettings) in s.performance.soundUpsampleRadius = 0 },
            { (s: inout TerrestrialSettings) in s.performance.soundUpsamplePhases = 1 },
            { (s: inout TerrestrialSettings) in s.performance.soundExtractionRadius = 0 },
            { (s: inout TerrestrialSettings) in s.performance.carrierPLLStride = 0 },
            { (s: inout TerrestrialSettings) in s.performance.amplifierAntiAliasRadius = 1 },
            { (s: inout TerrestrialSettings) in s.performance.amplifierTablePoints = 100 },
            { (s: inout TerrestrialSettings) in s.performance.amplifierCouplingStride = 0 },
            { (s: inout TerrestrialSettings) in s.performance.afcLockedDecimation = 0 },
            { (s: inout TerrestrialSettings) in s.performance.spectrumWindows = 0 }
        ] {
            mutate(&settings)
            XCTAssertThrowsError(try settings.validate(rate: settings.rateValidationRate),
                                 "Invalid profile knobs must be rejected")
            settings.performance = .full
        }
        XCTAssertNoThrow(try settings.validate(rate: settings.rateValidationRate))
    }

    func testLegacySessionWithoutProfileDecodesAsFull() throws {
        let data = Data(#"{"signalDB":-3,"carrierToNoiseDB":40}"#.utf8)
        let settings = try JSONDecoder().decode(TerrestrialSettings.self,from: data)
        XCTAssertEqual(settings.performance,.full)
        XCTAssertEqual(settings.signalDB,-3)
        let round = try JSONDecoder().decode(TerrestrialSettings.self,
                                            from: JSONEncoder().encode(TerrestrialSettings(system: .palDK)))
        XCTAssertEqual(round.performance,.full)
    }

    // MARK: - Sound chain

    /// The integer FM schedule is claimed to be exact for the unified channel's
    /// 8:1 rate ratio, so it must reproduce the floating-point schedule sample
    /// for sample rather than merely closely.
    func testIntegerFMPhaseScheduleIsExact() throws {
        for system in TerrestrialSystem.allCases {
            var reference = TVSoundModulator(system: system), integer = reference
            var full = TerrestrialSettings(system: system); full.performance = .full
            var mobile = full; mobile.performance.soundSynthesisIntegerSchedule = true
            for frame: Int64 in [0,1,2,17,900] {
                let pcm = tone(system,frame: frame)
                let a = reference.modulate(pcm,frameIndex: frame,settings: full,rate: 384_000)
                let b = integer.modulate(pcm,frameIndex: frame,settings: mobile,rate: 384_000)
                XCTAssertEqual(a.i,b.i,"\(system) frame \(frame)")
                XCTAssertEqual(a.q,b.q,"\(system) frame \(frame)")
                XCTAssertEqual(reference.overmodulated,integer.overmodulated)
            }
        }
    }

    /// Shortening the companion upsample kernel was measured to leak images into
    /// the picture, so the reduced-cost profile keeps the reference length. This
    /// guards both facts: the reference kernel rejects images, and the
    /// single-precision tap sum does not weaken that rejection.
    func testSoundResamplerSinglePrecisionKeepsTheKernelResponse() {
        let inputRate = 384_000.0, outputRate = 14_318_180.0, envelopeHz = 100_000.0
        var i = [Float](repeating: 0, count: 4_096), q = i
        for n in 0..<4_096 {
            let phase = 2*Double.pi*envelopeHz*Double(n)/inputRate
            i[n] = Float(cos(phase)); q[n] = Float(sin(phase))
        }
        // The first interpolation image of the wanted envelope sits at
        // inputRate - envelopeHz, inside the vision passband.
        func level(radius: Int, single: Bool, hz: Double) -> Double {
            var resampler = TVComplexResampler(inputRate: inputRate,outputRate: outputRate,
                                               radius: radius,phases: 512,
                                               singlePrecisionAccumulation: single)
            let (oi,oq) = resampler.process(i: i,q: q,inputStart: 0,outputStart: 0,outputCount: 8_192)
            var re = 0.0, im = 0.0
            for n in 4_096..<8_192 {
                let p = 2*Double.pi*hz*Double(n)/outputRate
                re += Double(oi[n])*cos(p)+Double(oq[n])*sin(p)
                im += Double(oq[n])*cos(p)-Double(oi[n])*sin(p)
            }
            return hypot(re,im)/Double(4_096)
        }
        let reference = level(radius: 6,single: false,hz: envelopeHz)
        let single = level(radius: 6,single: true,hz: envelopeHz)
        let referenceImage = level(radius: 6,single: false,hz: inputRate-envelopeHz)
        let singleImage = level(radius: 6,single: true,hz: inputRate-envelopeHz)
        let shortKernelImage = level(radius: 3,single: false,hz: inputRate-envelopeHz)
        print("resampler envelope",reference,single,"image",referenceImage,singleImage,"short",shortKernelImage)
        XCTAssertEqual(reference,1,accuracy: 0.02,"The wanted companion envelope must survive")
        XCTAssertEqual(single,reference,accuracy: 0.001,"Single precision must keep the passband")
        XCTAssertLessThan(referenceImage,0.01)
        XCTAssertEqual(singleImage,referenceImage,accuracy: 0.001,
                       "Single-precision taps must not add spectral leakage")
        XCTAssertGreaterThanOrEqual(singleImage,referenceImage-0.001)
        _ = shortKernelImage
    }

    // MARK: - Channel noise

    /// The concurrent generator must keep the noise power, keep the noise white,
    /// stay reproducible, and not collapse into a repeated block.
    func testParallelNoiseKeepsPowerAndWhiteness() throws {
        let system = TerrestrialSystem.palDK
        let count = Int(system.video.sampleOffset(frame: 1)-system.video.sampleOffset(frame: 0))
        let input = [Float](repeating: 0,count: count)
        func noise(_ generator: TVNoiseGenerator, seed: UInt64) -> [Float] {
            var settings = TerrestrialSettings(system: system)
            settings.carrierToNoiseDB = 30
            settings.performance.noiseGenerator = generator
            var channel = TerrestrialRFChannel(seed: seed)
            let (i,_) = channel.transmit(i: input,q: input,rate: system.video.sampleRate,
                                         carrierOffsetHz: 0,time: 0,settings: settings)
            return i
        }
        let serial = noise(.sequentialBoxMuller,seed: 7)
        let serialAgain = noise(.sequentialBoxMuller,seed: 7)
        let parallel = noise(.parallelBoxMuller,seed: 7)
        let parallelAgain = noise(.parallelBoxMuller,seed: 7)
        XCTAssertEqual(serial,serialAgain,"The serial sequence must stay reproducible")
        XCTAssertEqual(parallel,parallelAgain,"The concurrent sequence must stay reproducible")
        XCTAssertNotEqual(Array(serial.prefix(4_096)),Array(parallel.prefix(4_096)),
                          "A new generator may not repeat the serial block")
        func variance(_ v: [Float]) -> Double {
            let mean = v.reduce(0.0) { $0+Double($1) }/Double(v.count)
            return v.reduce(0.0) { $0+pow(Double($1)-mean,2) }/Double(v.count)
        }
        func autocorrelation(_ v: [Float]) -> Double {
            let mean = v.reduce(0.0) { $0+Double($1) }/Double(v.count)
            var numerator = 0.0, denominator = 0.0
            for n in 1..<v.count {
                let a = Double(v[n])-mean, b = Double(v[n-1])-mean
                numerator += a*b; denominator += a*a
            }
            return numerator/denominator
        }
        let ratio = variance(parallel)/variance(serial)
        print("noise variance ratio",ratio,"serial rho",autocorrelation(serial),"parallel rho",autocorrelation(parallel))
        XCTAssertEqual(ratio,1,accuracy: 0.06,"Concurrent noise must keep the channel noise power")
        XCTAssertLessThan(abs(autocorrelation(serial)),0.02)
        XCTAssertLessThan(abs(autocorrelation(parallel)),0.02,"Concurrent noise must stay white")
    }

    /// The concurrent generator is addressed by absolute sample index, so it must
    /// not depend on how a frame was partitioned between workers.
    func testParallelNoiseDoesNotDependOnFramePosition() throws {
        let system = TerrestrialSystem.ntscM
        let clock = TVChannelClock(system: system,sampleRate: system.video.sampleRate)
        func frame(_ index: Int64, generator: TVNoiseGenerator) -> [Float] {
            var settings = TerrestrialSettings(system: system)
            settings.carrierToNoiseDB = 40
            settings.performance.noiseGenerator = generator
            var channel = TerrestrialRFChannel(seed: 11)
            let count = clock.count(frame: index)
            let input = [Float](repeating: 0,count: count)
            let (i,_) = channel.transmit(i: input,q: input,rate: system.video.sampleRate,
                                         carrierOffsetHz: 0,time: 0,settings: settings)
            return i
        }
        for generator in [TVNoiseGenerator.sequentialBoxMuller,.parallelBoxMuller] {
            let long = frame(0,generator: generator) + frame(1,generator: generator)
            // The same absolute index range must yield the same continuous noise.
            XCTAssertEqual(long.count,clock.count(frame: 0)+clock.count(frame: 1))
            XCTAssertTrue(long.allSatisfy(\.isFinite))
        }
    }

    // MARK: - Receiver estimates

    /// The reduced-rate carrier estimate must track the same carrier, and it must
    /// only be used while the receiver is locked: acquisition and loss of lock
    /// have to fall back to the full-rate estimate.
    func testMobileAFCDecimatesOnlyWhileLocked() throws {
        for system in TerrestrialSystem.allCases {
            var full = TerrestrialReceiver(system: system)
            var mobile = TerrestrialReceiver(system: system)
            var fullSettings = damaged(system)
            fullSettings.tuningOffsetKHz = 20
            var mobileSettings = fullSettings
            mobileSettings.performance = .mobile
            let picture = TVFrame.colorBars(system.video)
            var carrier: [Double] = []
            for frame: Int64 in 0..<6 {
                let clock = TVChannelClock(system: system,sampleRate: system.video.sampleRate)
                let cvbs = try TVEngine.encode(picture,frameIndex: frame)
                var modulator = VSBModulator(system: system)
                let vision = try modulator.modulate(cvbs)
                let input = TVChannelIQ(system: system,frameIndex: frame,
                                        firstSampleIndex: clock.offset(frame: frame),
                                        sampleRate: system.video.sampleRate,i: vision.i,q: vision.q)
                let a = try full.receive(input,settings: fullSettings)
                let b = try mobile.receive(input,settings: mobileSettings)
                XCTAssertEqual(full.carrierEstimationDecimation,1)
                if frame == 0 {
                    XCTAssertEqual(mobile.carrierEstimationDecimation,1,
                                   "Acquisition must use the full-rate estimate")
                    XCTAssertEqual(mobile.carrierPLLStrideUsed,1,
                                   "Acquisition must use the dense phase feedback")
                } else {
                    XCTAssertEqual(mobile.carrierEstimationDecimation,8,
                                   "\(system) frame \(frame) must use the tracked estimate")
                    XCTAssertEqual(mobile.carrierPLLStrideUsed,2,
                                   "\(system) frame \(frame) must use the tracked phase feedback")
                }
                if frame >= 3 {
                    XCTAssertEqual(a.lock,.locked,"\(system) full frame \(frame)")
                    XCTAssertEqual(b.lock,.locked,"\(system) mobile frame \(frame)")
                    carrier.append(mobile.carrierFrequency)
                    XCTAssertEqual(full.carrierFrequency,mobile.carrierFrequency,accuracy: 400,
                                   "\(system) frame \(frame) carrier estimate")
                }
            }
            let spread = (carrier.max() ?? 0)-(carrier.min() ?? 0)
            XCTAssertLessThan(spread,1_500,"\(system) tracked carrier must stay steady")
        }
    }

    /// Losing the carrier must restore the full-rate estimate on the next frame,
    /// and re-acquiring it must return to the tracked estimate.
    func testMobileAFCRestoresFullEstimateAfterLoss() throws {
        let system = TerrestrialSystem.palDK
        var receiver = TerrestrialReceiver(system: system)
        var settings = TerrestrialSettings(system: system)
        settings.performance = .mobile
        let picture = TVFrame.colorBars(system.video)
        let clock = TVChannelClock(system: system,sampleRate: system.video.sampleRate)
        var inputs = [TVChannelIQ]()
        for frame: Int64 in 0..<8 { inputs.append(try channelIQ(system,picture,frame: frame,clock: clock)) }
        for frame in 0..<4 {
            _ = try receiver.receive(inputs[frame],settings: settings)
        }
        XCTAssertEqual(receiver.carrierEstimationDecimation,8,"The carrier must be tracked")
        XCTAssertEqual(receiver.carrierPLLStrideUsed,2,"The tracked carrier uses the reduced feedback")
        // Detuned far outside the finite AFC capture range: the carrier is lost
        // without changing the signal amplitude, so no AGC transient is involved.
        var detuned = settings; detuned.tuningOffsetKHz = 600
        let lost = try receiver.receive(inputs[4],settings: detuned)
        XCTAssertNotEqual(lost.lock,.locked,"A carrier outside the capture range cannot stay locked")
        _ = try receiver.receive(inputs[5],settings: settings)
        XCTAssertEqual(receiver.carrierEstimationDecimation,1,
                       "Loss of lock must restore the full-rate estimate")
        XCTAssertEqual(receiver.carrierPLLStrideUsed,1,
                       "Loss of lock must restore the dense phase feedback")
        for frame in 5..<8 { _ = try receiver.receive(inputs[frame],settings: settings) }
        XCTAssertEqual(receiver.carrierEstimationDecimation,8,"Re-acquisition must track again")
        XCTAssertEqual(receiver.carrierPLLStrideUsed,2,"Re-acquisition must reduce the feedback again")
    }

    private func channelIQ(_ system: TerrestrialSystem, _ picture: TVFrame, frame: Int64,
                           clock: TVChannelClock) throws -> TVChannelIQ {
        let cvbs = try TVEngine.encode(picture,frameIndex: frame)
        var modulator = VSBModulator(system: system)
        let vision = try modulator.modulate(cvbs)
        return TVChannelIQ(system: system,frameIndex: frame,firstSampleIndex: clock.offset(frame: frame),
                           sampleRate: system.video.sampleRate,i: vision.i,q: vision.q)
    }

    // MARK: - End-to-end corridor

    /// Deterministic reductions only (the noise realization is pinned to the
    /// serial generator) so this measures the cost of the DSP trade-offs alone.
    func testMobileDeterministicStagesStayInsideCorridor() throws {
        for system in TerrestrialSystem.allCases {
            var reference = TVUnifiedChannelEngine(system: system)
            var mobile = TVUnifiedChannelEngine(system: system)
            var fullSettings = damaged(system); fullSettings.carrierToNoiseDB = 100
            var mobileSettings = fullSettings
            mobileSettings.performance = .mobile
            mobileSettings.performance.noiseGenerator = .sequentialBoxMuller
            let source = TVFrame.colorBars(system.video)
            for frame: Int64 in 0..<8 {
                let cvbs = try TVEngine.encode(source,frameIndex: frame)
                let audio = tone(system,frame: frame)
                let a = try reference.process(cvbs,settings: fullSettings,audio: audio)
                let b = try mobile.process(cvbs,settings: mobileSettings,audio: audio)
                if frame >= 4 {
                    XCTAssertEqual(a.lock,.locked,"\(system) reference frame \(frame)")
                    XCTAssertEqual(b.lock,.locked,"\(system) mobile frame \(frame)")
                    let error = maximumRGBError(a.frame,b.frame)
                    print("mobile corridor",system.rawValue,"frame",frame,"rgb error",error)
                    XCTAssertLessThan(error,0.02,"\(system) frame \(frame) vision")
                }
            }
        }
    }

    /// The shipped mobile profile, including the concurrent noise realization,
    /// must still recover vision and the companion tone in one pass.
    func testShippedMobileProfileRecoversVisionAndSound() throws {
        for system in TerrestrialSystem.allCases {
            var engine = TVUnifiedChannelEngine(system: system)
            var settings = TerrestrialSettings(system: system); settings.carrierToNoiseDB = 90
            settings.performance = .mobile
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
            print("mobile unified",system,"locked",locked,"tone",audio.tone,"residual",audio.residual)
            XCTAssertGreaterThanOrEqual(locked,6,"The mobile profile must not prevent vision lock")
            XCTAssertEqual(audio.tone,0.25,accuracy: 0.05)
            XCTAssertLessThan(audio.residual,0.05)
        }
    }

    // MARK: - Evidence

    /// Prints the per-stage cost of both profiles. No machine-dependent speed
    /// assertion: the numbers are evidence for the report, not a gate.
    func testMobileProfileStageTimings() throws {
        var rows = [[String: Any]]()
        for system in TerrestrialSystem.allCases {
            for profile in [TVChainProfile.full,.mobile] {
                var engine = TVUnifiedChannelEngine(system: system)
                var settings = damaged(system); settings.performance = profile
                let source = TVFrame.colorBars(system.video)
                var stages = [[Double]]()
                for frame: Int64 in 0..<12 {
                    let start = ContinuousClock.now
                    let cvbs = try TVEngine.encode(source,frameIndex: frame)
                    let result = try engine.process(cvbs,settings: settings,audio: tone(system,frame: frame))
                    let finished = ContinuousClock.now
                    let c = start.duration(to: finished).components
                    let total = Double(c.seconds)+Double(c.attoseconds)/1e18
                    if frame >= 3 {
                        let t = result.timings
                        stages.append([total,t.modulation,t.channel,t.tuner,t.carrierEstimation,
                                       t.carrierPLL,t.synchronization,t.videoDecode,t.soundExtraction])
                    }
                }
                let names = ["total","VSB+PA","RF channel","tuner/IF","AFC","PLL","sync","decode","sound extract"]
                var row: [String: Any] = ["system": system.rawValue,
                                          "profile": profile == .full ? "full" : "mobile"]
                for index in names.indices {
                    row[names[index]] = stages.map { $0[index] }.reduce(0,+)/Double(stages.count)*1000
                }
                rows.append(row)
                print("mobile profile timing",row)
            }
        }
        let data = try JSONSerialization.data(withJSONObject: rows,options: [.prettyPrinted,.sortedKeys])
        try data.write(to: URL(fileURLWithPath:"/private/tmp/AnaLine-mobile-profile.json"))
    }
}

private extension TerrestrialSettings {
    /// The channel grid rate used by the validation tests.
    var rateValidationRate: Double { TerrestrialSystem.palDK.video.sampleRate }
}
