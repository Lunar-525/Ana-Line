import Foundation

/// Transmit half of the unified channel: CVBS to VSB, drive and separate vision
/// and companion power amplifiers, then the one linear combiner and the RF
/// channel. It owns every stateful stage on the transmit side and nothing else,
/// so a pipeline can run it for frame N+1 while the receive half runs frame N.
///
/// One input the transmit half does *not* own is the shared front-end gain: the
/// receiver measures it and the next frame consumes it, which is the cross-frame
/// coupling the pipeline has to respect. Callers set `settings.frontEnd.gainDB`
/// before calling in.
public struct TVTransmitChain: Sendable {
    public let system: TerrestrialSystem
    public static let soundRate = 384_000
    private var visionModulator: VSBModulator
    private var soundModulator: TVSoundModulator
    private var combiner: TVChannelModulator
    private var channel: TerrestrialRFChannel
    private var visionAmplifier = TVTransmitterAmplifier()
    private var soundAmplifier = TVTransmitterAmplifier()

    public init(system: TerrestrialSystem, seed: UInt64 = 42) {
        self.system = system
        visionModulator = VSBModulator(system: system)
        soundModulator = TVSoundModulator(system: system)
        combiner = TVChannelModulator(system: system)
        channel = TerrestrialRFChannel(seed: seed)
    }

    /// One transmit pass. `channel` is the record the receive half consumes; the
    /// rest is the transmitter telemetry that belongs to this pass.
    public struct Output: Sendable {
        public let channel: TVChannelIQ
        public let forwardPower: Float
        public let overmodulated: Bool
        public let saturated: Bool
        public let modulationSeconds: Double
        public let combinationSeconds: Double
        public let channelSeconds: Double
    }

    /// `measuringFrom` is the frame's own start instant, so the reported
    /// modulation time keeps covering the whole frame prologue exactly as it did
    /// before the chains were split.
    public mutating func transmit(_ input: CompositeVideo, settings: TerrestrialSettings,
                                  audio: [Float]?,
                                  measuringFrom start: ContinuousClock.Instant) throws -> Output {
        let modulationInterval = TVSignpost.begin(.modulation)
        // Vision branch: CVBS -> VSB -> drive -> separate vision PA.
        var vision = try visionModulator.modulate(input, execution: settings.execution, filter: settings.transmitter.vsb)
        TVTransmitterSettings.drive(i: &vision.i,q: &vision.q,settings: settings.transmitter)
        // In-band cross compression still reads the measured vision envelope.
        var visionPower: [Float] = []
        if audio != nil, settings.transmitter.enabled, settings.transmitter.sharedCoupling > 0 {
            let cells = TVSoundClock.count(frame: input.frameIndex,standard: input.standard,rate: Self.soundRate)
            // The cross-compression envelope is a companion-rate cell average.
            // The profile may estimate it from a sub-sample stride; at stride 1
            // this averages exactly the samples the cell spans.
            let step = max(1,settings.performance.amplifierCouplingStride)
            visionPower = vision.i.withUnsafeBufferPointer { ip in vision.q.withUnsafeBufferPointer { qp in
                [Float](unsafeUninitializedCapacity: cells) { output,initialized in
                    let i = ip.baseAddress!, q = qp.baseAddress!, target = output.baseAddress!, count = ip.count
                    for cell in 0..<cells {
                        let a = cell*count/cells, b = (cell+1)*count/cells
                        var sum: Float = 0, samples = 0
                        for n in stride(from: a,to: b,by: step) { sum += i[n]*i[n]+q[n]*q[n]; samples += 1 }
                        target.advanced(by: cell).initialize(to: sum/Float(max(1,samples)))
                    }
                    initialized = cells
                }
            } }
        }
        (vision.i,vision.q) = visionAmplifier.apply(i: vision.i,q: vision.q,settings: settings.transmitter,
            execution: settings.execution,otherPower: visionPower.isEmpty ? [] : [0.1*settings.transmitter.powerGain],
            profile: settings.performance)
        var forward = visionAmplifier.meanOutputPower
        var overmodulated = visionModulator.overmodulated
        // Sound branch: PCM -> FM -> separate sound PA, still narrowband.
        var soundSignal: TVSoundIQ?
        if let audio {
            var sound = soundModulator.modulate(audio,frameIndex: input.frameIndex,settings: settings,
                                                rate: Double(Self.soundRate))
            (sound.i,sound.q) = soundAmplifier.apply(i: sound.i,q: sound.q,settings: settings.transmitter,
                execution: settings.execution,otherPower: visionPower,profile: settings.performance)
            forward += soundAmplifier.meanOutputPower
            overmodulated = overmodulated || soundModulator.overmodulated
            soundSignal = sound
        }
        // Linear combine, then one feedline mismatch on the combined output.
        let combinationInterval = TVSignpost.begin(.combination)
        let combiningStarted = ContinuousClock.now
        var combined = try combiner.combine(vision: vision,sound: soundSignal,profile: settings.performance)
        TVTransmitterSettings.deliver(i: &combined.i,q: &combined.q,settings: settings.transmitter)
        let modulated = ContinuousClock.now
        TVSignpost.end(.combination, combinationInterval)
        TVSignpost.end(.modulation, modulationInterval)
        let channelInterval = TVSignpost.begin(.channel)
        let transmitted = try channel.transmit(combined, settings: settings)
        let channelDone = ContinuousClock.now
        TVSignpost.end(.channel, channelInterval)
        let saturated = settings.transmitter.enabled
            && (visionAmplifier.peakDrivePower >= pow(10,settings.transmitter.backoffDB/10)
                || (audio != nil && soundAmplifier.peakDrivePower >= pow(10,settings.transmitter.backoffDB/10)))
        return Output(channel: transmitted,
                      forwardPower: forward,
                      overmodulated: overmodulated,
                      saturated: saturated,
                      modulationSeconds: TerrestrialTimings.seconds(start.duration(to: modulated)),
                      combinationSeconds: TerrestrialTimings.seconds(combiningStarted.duration(to: modulated)),
                      channelSeconds: TerrestrialTimings.seconds(modulated.duration(to: channelDone)))
    }
}
