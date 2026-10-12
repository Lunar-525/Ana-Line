import Foundation

/// One frame to run through the pipeline. Construction of the composite frame
/// (CVBS encoding and the companion PCM) is expressed as a closure so the
/// pipeline can perform it on the transmit thread, where it overlaps the rest of
/// the chain instead of sitting on the caller's critical path.
public struct TVFrameRequest: Sendable {
    public let frameIndex: Int64
    public let settings: TerrestrialSettings
    public let build: @Sendable (Int64) throws -> (CompositeVideo, [Float]?)
    public init(frameIndex: Int64, settings: TerrestrialSettings,
                build: @escaping @Sendable (Int64) throws -> (CompositeVideo, [Float]?)) {
        self.frameIndex = frameIndex
        self.settings = settings
        self.build = build
    }
}

/// Three-stage frame pipeline.
///
/// Frame N+1 is built and transmitted on one thread, its shared front end runs on
/// a second thread, and detection for frame N runs on the calling thread, so three
/// different frames are in flight at once and the longest single stage — not their
/// sum — sets the frame time. The stages own disjoint state: the transmit chain,
/// the front end (`TVFrontEndStage`) and detection (`TVDetectStage`) share nothing
/// except the values handed between them.
///
/// One thing that does cross frames is the shared front-end gain: with
/// `frontEnd.agcEnabled`, frame N+1's front end consumes a gain the detector only
/// measures during frame N, so the pipeline refuses that combination with
/// `TVError.pipelineCoupling` rather than quietly changing the AGC loop.
/// `allowsLookahead` reports when the caller may keep the stages full.
///
/// Ownership is arranged so no stage can keep the pipeline alive: every submitted
/// frame gets its own `Slot`, and the worker blocks capture the stage boxes and
/// that slot, never the pipeline itself. There is therefore no deinit work, and
/// every wait is bounded so a stall surfaces as `TVError.pipelineStalled` instead
/// of a hang.
///
/// Usage keeps frames in order:
/// ```swift
/// try pipeline.submit(request0)
/// for n in 0..<count {
///     if pipeline.allowsLookahead, n+1 < count { try pipeline.submit(request(n+1)) }
///     let reception = try pipeline.receive()
///     ...
/// }
/// ```
public final class TVFramePipeline: @unchecked Sendable {
    public let system: TerrestrialSystem
    /// Frames in flight, counted across all three stages. Two is the smallest
    /// depth that lets every stage work on a different frame.
    private let depth = 2
    /// A stalled stage is a bug, not a slow frame; fail loudly.
    private let stepTimeout: DispatchTimeInterval = .seconds(20)

    /// The transmit chain lives in a box so its worker can own it without owning
    /// the pipeline.
    private final class TransmitBox: @unchecked Sendable {
        var chain: TVTransmitChain
        init(_ chain: TVTransmitChain) { self.chain = chain }
    }
    /// Same for the shared front end.
    private final class FrontBox: @unchecked Sendable {
        var stage: TVFrontEndStage
        init(_ stage: TVFrontEndStage) { self.stage = stage }
    }
    /// One frame's hand-off. Written by the transmit thread and then the front-end
    /// thread, read by the thread that detects it; the semaphore orders them.
    private final class Slot: @unchecked Sendable {
        struct Payload {
            let identity: TVFrameIdentity
            let frameIndex: Int64
            let sampleCount: Int
            let output: TVTransmitChain.Output
            let settings: TerrestrialSettings
            let audio: [Float]?
        }
        let ready = DispatchSemaphore(value: 0)
        var transmit: Payload?
        var front: TVFrontEndOutput?
        var started = ContinuousClock.now
        var failure: Error?
    }

    /// Counters the workers and the caller both touch, kept apart from the
    /// pipeline so no worker block captures the pipeline itself.
    private final class Shared: @unchecked Sendable {
        let lock = NSLock()
        var submitSerial = 0
        var receivedSerial = 0
        var overlapped = 0
    }

    private let box: TransmitBox
    private let frontBox: FrontBox
    private let shared = Shared()
    private let transmitQueue: DispatchQueue
    private let frontQueue: DispatchQueue
    // Caller-thread state.
    private var detector: TVDetectStage
    private var commonGain: Float = 1
    private var slots = [Slot]()
    private let lock = NSLock()
    private let free: DispatchSemaphore
    private var couplingsInFlight = 0
    private var inFlight = 0

    /// Committed progress of every stage of every frame that completed.
    public private(set) var progress = TVProgressLedger()
    /// Refuse a repeated or rewound frame instead of recording it.
    public var strictFrameOrder = false
    /// Transmit passes that demonstrably ran while an earlier frame was still
    /// being received: deterministic evidence of overlap.
    public var overlapped: Int { shared.lock.lock(); defer { shared.lock.unlock() }; return shared.overlapped }

    public init(system: TerrestrialSystem, seed: UInt64 = 42, qos: DispatchQoS = .userInitiated) {
        self.system = system
        box = TransmitBox(TVTransmitChain(system: system, seed: seed))
        frontBox = FrontBox(TVFrontEndStage(system: system))
        detector = TVDetectStage(system: system)
        transmitQueue = DispatchQueue(label: "com.analine.frame.transmit", qos: qos)
        frontQueue = DispatchQueue(label: "com.analine.frame.frontend", qos: qos)
        free = DispatchSemaphore(value: depth)
    }

    /// True while the stages may run ahead of the caller. False once a submitted
    /// frame carries the shared-gain coupling, so the caller stops prefetching
    /// until that frame has been received.
    public var allowsLookahead: Bool {
        lock.lock(); defer { lock.unlock() }
        return couplingsInFlight == 0 && inFlight < depth
    }

    /// Frames submitted but not yet received.
    public var pendingFrames: Int {
        lock.lock(); defer { lock.unlock() }
        return inFlight
    }

    private func prepare(_ input: CompositeVideo, settings: TerrestrialSettings,
                         audio: [Float]?) throws -> TerrestrialSettings {
        var settings = settings
        if settings.frontEnd.agcEnabled {
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

    /// Queue one frame. Construction, transmission and the front end all run on
    /// the pipeline's threads; only detection runs on the caller.
    public func submit(_ request: TVFrameRequest) throws {
        // Only settings can be validated here; the frame does not exist yet.
        var prepared = request.settings
        if prepared.frontEnd.agcEnabled {
            prepared.frontEnd.gainDB = prepared.automaticGain
                ? 20*log10(max(0.1,min(10000,commonGain))) : prepared.manualGainDB
        }
        try prepared.validate(rate: system.video.sampleRate)
        try enqueue(prepared: prepared, index: request.frameIndex, input: nil, audio: nil, build: request.build)
    }

    /// Queue one frame whose composite already exists, e.g. reused across runs.
    public func submit(_ input: CompositeVideo, settings: TerrestrialSettings, audio: [Float]? = nil) throws {
        let prepared = try prepare(input, settings: settings, audio: audio)
        try enqueue(prepared: prepared, index: input.frameIndex, input: input, audio: audio, build: nil)
    }

    private func enqueue(prepared: TerrestrialSettings, index: Int64,
                         input: CompositeVideo?, audio: [Float]?,
                         build: (@Sendable (Int64) throws -> (CompositeVideo, [Float]?))?) throws {
        let slot = Slot()
        lock.lock()
        if prepared.frontEnd.agcEnabled, inFlight > 0 {
            lock.unlock()
            throw TVError.pipelineCoupling
        }
        if prepared.frontEnd.agcEnabled { couplingsInFlight += 1 }
        inFlight += 1
        let serial = shared.submitSerial
        shared.submitSerial += 1
        slots.append(slot)
        let box = self.box, frontBox = self.frontBox, shared = self.shared
        let frontQueue = self.frontQueue
        lock.unlock()
        free.wait()
        let frameSystem = system
        transmitQueue.async {
            shared.lock.lock()
            if shared.receivedSerial < serial { shared.overlapped += 1 }
            shared.lock.unlock()
            var candidate = box.chain
            var payload: Slot.Payload?
            do {
                let frame: CompositeVideo
                let frameAudio: [Float]?
                if let build {
                    let made = try build(index)
                    frame = made.0; frameAudio = made.1
                } else {
                    guard let input else { throw TVError.invalidSignal }
                    frame = input; frameAudio = audio
                }
                if let frameAudio {
                    guard frameAudio.allSatisfy(\.isFinite),
                          frameAudio.count == TVSoundClock.count(frame: index,standard: frameSystem.video) else {
                        throw TVError.invalidSignal
                    }
                }
                let identity = TVFrameIdentity(frameIndex: index,
                                               sampleStart: frame.standard.sampleOffset(frame: index),
                                               sampleCount: frame.samples.count)
                let output = try candidate.transmit(frame, settings: prepared, audio: frameAudio,
                                                    measuringFrom: ContinuousClock.now)
                box.chain = candidate
                payload = Slot.Payload(identity: identity,frameIndex: index,sampleCount: frame.samples.count,
                                       output: output,settings: prepared,audio: frameAudio)
            } catch {
                slot.failure = error
            }
            slot.transmit = payload
            guard let payload else {
                slot.ready.signal()
                return
            }
            // Hand the record straight to the front-end stage, which runs on its
            // own thread so three different frames are in flight at once.
            let channel = payload.output.channel
            frontQueue.async {
                var front = frontBox.stage
                let started = ContinuousClock.now
                do {
                    let output = try front.process(channel, settings: prepared, started: started)
                    frontBox.stage = front
                    slot.started = started
                    slot.front = output
                } catch {
                    slot.failure = error
                }
                slot.ready.signal()
            }
        }
    }

    @discardableResult
    private func commit(_ stage: TVStage, _ identity: TVFrameIdentity) throws -> TVFrameContinuity {
        let verdict = progress.advance(stage, to: identity)
        if verdict.isViolation, strictFrameOrder { throw TVError.outOfOrderFrame }
        return verdict
    }

    private func updateSharedGain(_ reception: TerrestrialReception, settings: TerrestrialSettings) {
        guard settings.frontEnd.agcEnabled else { return }
        if settings.automaticGain {
            let target = pow(Float(10),reception.agcTargetDB/20)
            commonGain = max(0.1,min(10000,commonGain*target))
        } else {
            commonGain = pow(10,settings.manualGainDB/20)
        }
    }

    /// Wait for the next submitted frame's front end, then detect it here. Frames
    /// resolve in submission order.
    public func receive() throws -> TerrestrialReception {
        lock.lock()
        guard !slots.isEmpty else { lock.unlock(); throw TVError.invalidSignal }
        let slot = slots.removeFirst()
        inFlight -= 1
        lock.unlock()
        // Bounded: a stage that never signals is a bug, and a hang would be far
        // harder to diagnose than this error.
        guard slot.ready.wait(timeout: .now()+stepTimeout) == .success else {
            throw TVError.pipelineStalled
        }
        free.signal()
        if let failure = slot.failure { throw failure }
        guard let payload = slot.transmit, let front = slot.front else { throw TVError.invalidSignal }
        lock.lock()
        if payload.settings.frontEnd.agcEnabled { couplingsInFlight -= 1 }
        lock.unlock()

        var candidate = detector
        var result = try candidate.detect(front, settings: payload.settings, audio: payload.audio,
                                          started: slot.started)
        detector = candidate
        let continuity = try commit(.modulation, payload.identity)
        try commit(.combination, payload.identity)
        try commit(.channel, payload.identity)
        try commit(.frontEnd, payload.identity)
        try commit(.carrierEstimation, payload.identity)
        try commit(.carrierPLL, payload.identity)
        try commit(.detection, payload.identity)
        try commit(.decode, payload.identity)
        if payload.audio != nil { try commit(.sound, payload.identity) }
        updateSharedGain(result, settings: payload.settings)
        result.lightningEvents = TVLightningTimeline.events(
            time: Double(payload.frameIndex)*system.video.frameDuration,
            duration: Double(payload.sampleCount)/system.video.sampleRate,
            seed: payload.settings.seed,settings: payload.settings.propagation)
        result.transmitter.forwardPower = payload.output.forwardPower
        result.transmitter.referencePower = payload.audio != nil ? 1.1 : 1
        result.transmitter.saturated = payload.output.saturated
        result.transmitter.overmodulated = payload.output.overmodulated
        result.timings.channelCombination = payload.output.combinationSeconds
        result.timings.modulation = payload.output.modulationSeconds
        result.timings.channel = payload.output.channelSeconds
        result.transmitter.reflectedPower = result.transmitter.forwardPower*payload.settings.transmitter.reflectedFraction
        result.frameIdentity = payload.identity
        result.frameContinuity = continuity
        shared.lock.lock(); shared.receivedSerial += 1; shared.lock.unlock()
        return result
    }
}
