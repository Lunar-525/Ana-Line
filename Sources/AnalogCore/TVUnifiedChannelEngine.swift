import Foundation

/// End-to-end unified channel. Vision VSB and mono FM sound are combined onto
/// one 4fsc IQ record, propagated once, and received through one shared front
/// end. Vision detection and sound extraction then observe the same receiver
/// pass, so common noise, echoes and tuning affect both branches together.
///
/// This path is additive: TerrestrialEngine remains the legacy reference that
/// runs two independent narrowband branches. Common-PA nonlinearity is not yet
/// modelled here; the first combined version is linear for reference comparison.
public struct TVUnifiedChannelEngine: Sendable {
    public let system: TerrestrialSystem
    static let soundRate = 384_000
    private var visionModulator: VSBModulator
    private var soundModulator: TVSoundModulator
    private var combiner: TVChannelModulator
    private var channel: TerrestrialRFChannel
    private var receiver: TerrestrialReceiver
    private var visionAmplifier = TVTransmitterAmplifier()
    private var soundAmplifier = TVTransmitterAmplifier()
    private var extractor: TVSoundExtractor
    private var extractorMode: TVSoundDetectionMode = .splitSound
    private var demodulator: TVSoundDemodulator
    private var commonGain: Float = 1
    private let soundSpectrumAnalyzer = TVSpectrumAnalyzer(log2Size: 9)

    public init(system: TerrestrialSystem, seed: UInt64 = 42) {
        self.system = system
        visionModulator = VSBModulator(system: system)
        soundModulator = TVSoundModulator(system: system)
        combiner = TVChannelModulator(system: system)
        channel = TerrestrialRFChannel(seed: seed)
        receiver = TerrestrialReceiver(system: system)
        extractor = TVSoundExtractor(system: system, outputRate: Double(Self.soundRate))
        demodulator = TVSoundDemodulator(system: system, projectFrontEnd: false)
    }

    public mutating func process(_ input: CompositeVideo, settings: TerrestrialSettings,
                                 audio: [Float]? = nil) throws -> TerrestrialReception {
        let start = ContinuousClock.now
        var settings = settings
        if settings.frontEnd.agcEnabled {
            // Block feedback: the previous frame's measured target sets the
            // shared gain before this frame is amplified.
            settings.frontEnd.gainDB = 20*log10(max(0.1,min(10000,commonGain)))
        }
        try settings.validate(rate: input.standard.sampleRate)
        if let audio {
            guard audio.allSatisfy(\.isFinite),
                  audio.count == TVSoundClock.count(frame: input.frameIndex,standard: input.standard) else {
                throw TVError.invalidSignal
            }
        }
        // Vision branch: CVBS -> VSB -> drive -> separate vision PA.
        var vision = try visionModulator.modulate(input, execution: settings.execution, filter: settings.transmitter.vsb)
        TVTransmitterSettings.drive(i: &vision.i,q: &vision.q,settings: settings.transmitter)
        // In-band cross compression still reads the measured vision envelope.
        var visionPower: [Float] = []
        if audio != nil, settings.transmitter.enabled, settings.transmitter.sharedCoupling > 0 {
            let cells = TVSoundClock.count(frame: input.frameIndex,standard: input.standard,rate: Self.soundRate)
            visionPower = vision.i.withUnsafeBufferPointer { ip in vision.q.withUnsafeBufferPointer { qp in
                [Float](unsafeUninitializedCapacity: cells) { output,initialized in
                    let i = ip.baseAddress!, q = qp.baseAddress!, target = output.baseAddress!, count = ip.count
                    for cell in 0..<cells {
                        let a = cell*count/cells, b = (cell+1)*count/cells
                        var sum: Float = 0
                        for n in a..<b { sum += i[n]*i[n]+q[n]*q[n] }
                        target.advanced(by: cell).initialize(to: sum/Float(max(1,b-a)))
                    }
                    initialized = cells
                }
            } }
        }
        (vision.i,vision.q) = visionAmplifier.apply(i: vision.i,q: vision.q,settings: settings.transmitter,
            execution: settings.execution,otherPower: visionPower.isEmpty ? [] : [0.1*settings.transmitter.powerGain])
        var forward = visionAmplifier.meanOutputPower
        var overmodulated = visionModulator.overmodulated
        // Sound branch: PCM -> FM -> separate sound PA, still narrowband.
        var soundSignal: TVSoundIQ?
        if let audio {
            var sound = soundModulator.modulate(audio,frameIndex: input.frameIndex,settings: settings,
                                                rate: Double(Self.soundRate))
            (sound.i,sound.q) = soundAmplifier.apply(i: sound.i,q: sound.q,settings: settings.transmitter,
                execution: settings.execution,otherPower: visionPower)
            forward += soundAmplifier.meanOutputPower
            overmodulated = overmodulated || soundModulator.overmodulated
            soundSignal = sound
        }
        // Linear combine, then one feedline mismatch on the combined output.
        var combined = try combiner.combine(vision: vision,sound: soundSignal)
        TVTransmitterSettings.deliver(i: &combined.i,q: &combined.q,settings: settings.transmitter)
        let modulated = ContinuousClock.now
        let transmitted = try channel.transmit(combined, settings: settings)
        let channelDone = ContinuousClock.now
        // One shared receiver pass feeds both vision detection and sound extraction.
        let reception = try receiver.receiveWithFrontEnd(transmitted, settings: settings)
        var result = reception.0
        if settings.frontEnd.agcEnabled {
            // The detector measured the target for the gain already applied, so
            // the update is multiplicative: g <- g * target.
            let target = pow(Float(10),reception.0.agcTargetDB/20)
            commonGain = max(0.1,min(10000,commonGain*target))
        }
        result.lightningEvents = TVLightningTimeline.events(
            time: Double(input.frameIndex)*input.standard.frameDuration,
            duration: Double(input.samples.count)/input.standard.sampleRate,
            seed: settings.seed,settings: settings.propagation)
        result.transmitter.forwardPower = forward
        result.transmitter.referencePower = audio != nil ? 1.1 : 1
        result.transmitter.saturated = settings.transmitter.enabled
            && (visionAmplifier.peakDrivePower >= pow(10,settings.transmitter.backoffDB/10)
                || soundAmplifier.peakDrivePower >= pow(10,settings.transmitter.backoffDB/10))
        result.transmitter.overmodulated = overmodulated
        result.timings.modulation = TerrestrialTimings.seconds(start.duration(to: modulated))
        result.timings.channel = TerrestrialTimings.seconds(modulated.duration(to: channelDone))
        if let audio {
            // Recover the companion carrier from the shared receiver pass. Split
            // Sound selects it from the IF; Intercarrier takes the beat from the
            // detected video, where a common tuning error has already cancelled.
            if extractorMode != settings.frontEnd.soundDetection {
                extractor.reset(); extractorMode = settings.frontEnd.soundDetection
            }
            let extracted: TVSoundIQ
            switch settings.frontEnd.soundDetection {
            case .intercarrier:
                extracted = extractor.extractIntercarrier(receiver.detectedVideo,frameIndex: input.frameIndex,
                    firstSampleIndex: system.video.sampleOffset(frame: input.frameIndex),
                    sampleRate: system.video.sampleRate,carrierHz: system.soundCarrierHz)
            case .splitSound:
                let shift = system.soundCarrierHz-Double(settings.tuningOffsetKHz)*1000
                extracted = extractor.extract(i: reception.1.i,q: reception.1.q,frameIndex: input.frameIndex,
                    firstSampleIndex: reception.1.firstSampleIndex,sampleRate: reception.1.sampleRate,shiftHz: shift)
            }
            // With common front-end AGC the gain is already in the shared IQ.
            let recoveryGain: Float = settings.frontEnd.agcEnabled ? 1 : receiver.currentGain
            let recovered = demodulator.demodulate(extracted,settings: settings,visionCorrectionHz: 0,
                                                   receiverGain: recoveryGain)
            result.audio = recovered.samples
            result.soundCarrierDB = recovered.carrierDB
            result.soundSeconds = recovered.seconds
            result.soundSpectrum = soundSpectrumAnalyzer.analyze(i: extracted.i,q: extracted.q,
                rate: extracted.sampleRate,centerHz: system.soundCarrierHz)
        }
        result.transmitter.reflectedPower = result.transmitter.forwardPower*settings.transmitter.reflectedFraction
        return result
    }
}
