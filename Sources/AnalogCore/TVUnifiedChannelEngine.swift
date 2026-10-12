import Foundation

/// End-to-end unified channel, composed of a transmit half and a receive half.
///
/// Vision VSB and mono FM sound are combined onto one 4fsc IQ record, propagated
/// once, and received through one shared front end, so common noise, echoes and
/// tuning affect both branches together. The two halves own disjoint state; the
/// only thing that crosses between them is the shared front-end gain, which the
/// receiver measures and the next frame's transmit pass consumes. That coupling is
/// held here, at the frame boundary, instead of being hidden inside either half.
///
/// This path is additive: TerrestrialEngine remains the legacy reference that runs
/// two independent narrowband branches.
public struct TVUnifiedChannelEngine: Sendable {
    public let system: TerrestrialSystem
    private var transmit: TVTransmitChain
    private var receive: TVReceiveChain
    /// Shared front-end gain: written from the receiver's measurement at the end
    /// of a frame, read by the transmit pass of the next frame.
    private var commonGain: Float = 1

    public init(system: TerrestrialSystem, seed: UInt64 = 42) {
        self.system = system
        transmit = TVTransmitChain(system: system, seed: seed)
        receive = TVReceiveChain(system: system)
    }

    /// Committed progress of every stage that has run. The engine is its only
    /// writer, and it writes only for frames that ran to completion.
    public private(set) var progress = TVProgressLedger()
    /// Refuse a repeated or rewound frame instead of recording it. Off by
    /// default: the player deliberately re-runs a frame to settle the loops, and
    /// strictness is for callers that can guarantee a monotonic frame sequence.
    public var strictFrameOrder = false

    @discardableResult
    private mutating func commit(_ stage: TVStage, _ identity: TVFrameIdentity) throws -> TVFrameContinuity {
        let verdict = progress.advance(stage, to: identity)
        if verdict.isViolation, strictFrameOrder { throw TVError.outOfOrderFrame }
        return verdict
    }

    /// Identity of a frame on its own sample grid.
    static func identity(of input: CompositeVideo) -> TVFrameIdentity {
        TVFrameIdentity(frameIndex: input.frameIndex,
                        sampleStart: input.standard.sampleOffset(frame: input.frameIndex),
                        sampleCount: input.samples.count)
    }

    /// Process one frame atomically. Every stage mutates a candidate copy of the
    /// engine; only a frame that runs to completion replaces the live state, so a
    /// failure cannot leave a recursive stage advanced past its own output.
    public mutating func process(_ input: CompositeVideo, settings: TerrestrialSettings,
                                 audio: [Float]? = nil) throws -> TerrestrialReception {
        var candidate = self
        let result = try candidate.processFrame(input, settings: settings, audio: audio)
        self = candidate
        return result
    }

    /// Frame prologue: apply the shared gain the receiver measured last frame and
    /// run every check that can fail, before any state is touched.
    private func prepare(_ input: CompositeVideo, settings: TerrestrialSettings,
                         audio: [Float]?) throws -> TerrestrialSettings {
        var settings = settings
        if settings.frontEnd.agcEnabled {
            // Block feedback: the previous frame's measured target sets the
            // shared gain before this frame is amplified.
            settings.frontEnd.gainDB = settings.automaticGain
                ? 20*log10(max(0.1,min(10000,commonGain))) : settings.manualGainDB
        }
        try settings.validate(rate: input.standard.sampleRate)
        if let audio {
            guard audio.allSatisfy(\.isFinite),
                  audio.count == TVSoundClock.count(frame: input.frameIndex,standard: input.standard) else {
                throw TVError.invalidSignal
            }
        }
        return settings
    }

    /// Block feedback for the next frame: the receiver measured the target for the
    /// gain already applied, so the update is multiplicative, g <- g * target.
    private mutating func updateSharedGain(_ reception: TerrestrialReception, settings: TerrestrialSettings) {
        guard settings.frontEnd.agcEnabled else { return }
        if settings.automaticGain {
            let target = pow(Float(10),reception.agcTargetDB/20)
            commonGain = max(0.1,min(10000,commonGain*target))
        } else {
            commonGain = pow(10,settings.manualGainDB/20)
        }
    }

    private mutating func processFrame(_ input: CompositeVideo, settings originalSettings: TerrestrialSettings,
                                       audio: [Float]? = nil) throws -> TerrestrialReception {
        let identity = Self.identity(of: input)
        let start = ContinuousClock.now
        let settings = try prepare(input, settings: originalSettings, audio: audio)

        let transmission = try transmit.transmit(input, settings: settings, audio: audio, measuringFrom: start)
        let continuity = try commit(.modulation, identity)
        try commit(.combination, identity)
        try TVProcessDiagnostics.check(.afterModulation)
        try commit(.channel, identity)
        try TVProcessDiagnostics.check(.afterChannel)

        // One shared receiver pass feeds both vision detection and sound extraction.
        var result = try receive.receive(transmission.channel, frameIndex: input.frameIndex,
                                         settings: settings, audio: audio)
        // The receiver runs carrier estimation, the PLL, detection and decode in
        // one call, so all four stages completed when it returns.
        try commit(.frontEnd, identity)
        try commit(.carrierEstimation, identity)
        try commit(.carrierPLL, identity)
        try commit(.detection, identity)
        try commit(.decode, identity)
        try TVProcessDiagnostics.check(.afterFrontEnd)
        updateSharedGain(result, settings: settings)
        result.lightningEvents = TVLightningTimeline.events(
            time: Double(input.frameIndex)*input.standard.frameDuration,
            duration: Double(input.samples.count)/input.standard.sampleRate,
            seed: settings.seed,settings: settings.propagation)
        result.transmitter.forwardPower = transmission.forwardPower
        result.transmitter.referencePower = audio != nil ? 1.1 : 1
        result.transmitter.saturated = transmission.saturated
        result.transmitter.overmodulated = transmission.overmodulated
        result.timings.channelCombination = transmission.combinationSeconds
        result.timings.modulation = transmission.modulationSeconds
        result.timings.channel = transmission.channelSeconds
        if audio != nil {
            try commit(.sound, identity)
            try TVProcessDiagnostics.check(.afterSound)
        }
        result.transmitter.reflectedPower = result.transmitter.forwardPower*settings.transmitter.reflectedFraction
        try TVProcessDiagnostics.check(.beforeCommit)
        result.frameIdentity = identity
        result.frameContinuity = continuity
        return result
    }
}
