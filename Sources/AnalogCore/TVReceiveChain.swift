import Foundation

/// Shared front end as a pipeline stage: tuning, common IF filter and the
/// optional receiver nonlinearity. It owns every piece of state that pass needs
/// and reads nothing the detector writes, which is what lets a pipeline run it
/// on one frame while detection runs on the previous one.
public struct TVFrontEndStage: Sendable {
    public let system: TerrestrialSystem
    private var frontEnd: TVReceiverFrontEnd

    public init(system: TerrestrialSystem) {
        self.system = system
        frontEnd = TVReceiverFrontEnd(system: system)
    }

    /// One front-end pass. `started` is the frame's start instant so the reported
    /// tuning time keeps covering the whole receive prologue.
    public mutating func process(_ input: TVChannelIQ, settings: TerrestrialSettings,
                                 started: ContinuousClock.Instant) throws -> TVFrontEndOutput {
        try frontEnd.process(input, settings: settings, started: started)
    }
}

/// Detection as a pipeline stage: carrier recovery, the phase loop, AGC, sync,
/// slicing, raster and colour decode, then companion extraction from the same
/// receiver pass. Its state is disjoint from the front end's.
public struct TVDetectStage: Sendable {
    public let system: TerrestrialSystem
    private var receiver: TerrestrialReceiver
    private var extractor: TVSoundExtractor
    private var extractorMode: TVSoundDetectionMode = .splitSound
    private var demodulator: TVSoundDemodulator
    private let soundSpectrumAnalyzer = TVSpectrumAnalyzer(log2Size: 9)

    public init(system: TerrestrialSystem) {
        self.system = system
        receiver = TerrestrialReceiver(system: system)
        extractor = TVSoundExtractor(system: system, outputRate: Double(TVTransmitChain.soundRate))
        demodulator = TVSoundDemodulator(system: system, projectFrontEnd: false)
    }

    /// Detect an already front-ended record and recover the companion audio from
    /// that same pass when a companion frame was supplied.
    public mutating func detect(_ front: TVFrontEndOutput, settings: TerrestrialSettings,
                                audio: [Float]?,
                                started: ContinuousClock.Instant) throws -> TerrestrialReception {
        let frontEndInterval = TVSignpost.begin(.frontEnd)
        var result = try receiver.receiveDetected(front, settings: settings, started: started)
        TVSignpost.end(.frontEnd, frontEndInterval)
        if audio != nil {
            if extractorMode != settings.frontEnd.soundDetection {
                extractor.reset(); extractorMode = settings.frontEnd.soundDetection
            }
            let soundInterval = TVSignpost.begin(.sound)
            let extractingStarted = ContinuousClock.now
            let extracted: TVSoundIQ
            switch settings.frontEnd.soundDetection {
            case .intercarrier:
                extracted = extractor.extractIntercarrier(receiver.detectedVideo,frameIndex: front.frameIndex,
                    firstSampleIndex: system.video.sampleOffset(frame: front.frameIndex),
                    sampleRate: system.video.sampleRate,carrierHz: system.soundCarrierHz,
                    profile: settings.performance)
            case .splitSound:
                let shift = system.soundCarrierHz-Double(settings.tuningOffsetKHz)*1000
                extracted = extractor.extract(i: front.i,q: front.q,frameIndex: front.frameIndex,
                    firstSampleIndex: front.firstSampleIndex,sampleRate: front.sampleRate,shiftHz: shift,
                    profile: settings.performance)
            }
            result.timings.soundExtraction = TerrestrialTimings.seconds(extractingStarted.duration(to: .now))
            let recoveryGain: Float = settings.frontEnd.agcEnabled ? 1 : receiver.currentGain
            let recovered = demodulator.demodulate(extracted,settings: settings,visionCorrectionHz: 0,
                                                   receiverGain: recoveryGain)
            result.audio = recovered.samples
            result.soundCarrierDB = recovered.carrierDB
            result.soundSeconds = recovered.seconds
            result.soundSpectrum = soundSpectrumAnalyzer.analyze(i: extracted.i,q: extracted.q,
                rate: extracted.sampleRate,centerHz: system.soundCarrierHz,
                windows: settings.performance.spectrumWindows)
            TVSignpost.end(.sound, soundInterval)
        }
        return result
    }
}

/// Receive half of the unified channel, composed of the front-end stage and the
/// detection stage. The sequential path uses this facade; a pipeline holds the
/// two stages separately so they can run on different frames.
public struct TVReceiveChain: Sendable {
    public let system: TerrestrialSystem
    private var frontEnd: TVFrontEndStage
    private var detector: TVDetectStage

    public init(system: TerrestrialSystem) {
        self.system = system
        frontEnd = TVFrontEndStage(system: system)
        detector = TVDetectStage(system: system)
    }

    /// One receive pass. The returned reception already carries the recovered
    /// audio, its carrier level, and the companion spectrum when a companion
    /// frame was supplied.
    public mutating func receive(_ input: TVChannelIQ, frameIndex: Int64,
                                 settings: TerrestrialSettings,
                                 audio: [Float]?) throws -> TerrestrialReception {
        let started = ContinuousClock.now
        let front = try frontEnd.process(input, settings: settings, started: started)
        return try detector.detect(front, settings: settings, audio: audio, started: started)
    }
}
