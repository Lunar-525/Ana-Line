import Foundation
@preconcurrency import AVFoundation

/// Bounded FIFO shared with the real-time callback. No allocation or DSP occurs
/// on the audio thread. An underrun emits silence and advances the 1× timeline.
final class TVPCMQueue: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [Float]
    private var readIndex = 0
    private var writeIndex = 0
    private var available = 0
    private var consumed: Int64 = 0
    private var missing: Int64 = 0
    init(capacity: Int = 48_000) { storage = .init(repeating: 0,count: capacity) }
    func append(_ samples: [Float]) throws {
        lock.lock(); defer { lock.unlock() }
        guard samples.count <= storage.count-available else { throw TVAudioError.bufferFull }
        for value in samples {
            storage[writeIndex] = value
            writeIndex = (writeIndex+1)%storage.count
        }
        available += samples.count
    }
    /// Timestamped PCM: late samples are discarded, and gaps are silent. A slow
    /// RF producer can never queue old speech behind the current picture clock.
    func append(_ samples: [Float],at sample: Int64) throws {
        lock.lock(); defer { lock.unlock() }
        let endpoint = consumed+Int64(available)
        let late = Int(min(Int64(samples.count),max(0,endpoint-sample)))
        let gap = max(0,sample-endpoint)
        guard gap <= Int64(storage.count-available),samples.count-late <= storage.count-available-Int(gap)
        else { throw TVAudioError.bufferFull }
        for _ in 0..<Int(gap) { storage[writeIndex] = 0; writeIndex = (writeIndex+1)%storage.count }
        for n in late..<samples.count { storage[writeIndex] = samples[n]; writeIndex = (writeIndex+1)%storage.count }
        available += Int(gap)+samples.count-late
    }
    func read(into target: UnsafeMutablePointer<Float>, count: Int) {
        lock.lock(); defer { lock.unlock() }
        let actual = min(available,count)
        for n in 0..<actual {
            target[n] = storage[readIndex]
            readIndex = (readIndex+1)%storage.count
        }
        for n in actual..<count { target[n] = 0 }
        available -= actual; consumed += Int64(count); missing += Int64(count-actual)
    }
    var snapshot: (pending: Int, consumed: Int64, underrun: Int64) {
        lock.lock(); defer { lock.unlock() }
        return (available,consumed,missing)
    }
}

enum TVAudioError: LocalizedError {
    case bufferFull, noOutputDevice
    var errorDescription: String? {
        switch self {
        case .bufferFull: "The television audio buffer is full"
        case .noOutputDevice: "No usable audio output device was found"
        }
    }
}

@MainActor
final class TVAudioOutput {
    private var engine: AVAudioEngine?
    private var source: AVAudioSourceNode?
    private var queue = TVPCMQueue()
    var pcmQueue: TVPCMQueue { queue }
    private(set) var rate: Float = 1
    var muted = false { didSet { engine?.mainMixerNode.outputVolume = muted ? 0 : 1 } }
    var pendingSeconds: Double { Double(queue.snapshot.pending)/48_000 }
    var consumedSamples: Int64 { queue.snapshot.consumed }
    var underrunSamples: Int64 { queue.snapshot.underrun }
    var latency: Double {
        engine?.outputNode.presentationLatency ?? 0
    }
    var mediaSeconds: Double { max(0,Double(consumedSamples)/48_000-latency*Double(rate)) }

    func prepare(capacity: Int = 48_000) throws {
        stop()
        queue = TVPCMQueue(capacity: capacity)
        let engine = AVAudioEngine()
        guard engine.outputNode.outputFormat(forBus: 0).sampleRate > 0,
              let format = AVAudioFormat(standardFormatWithSampleRate: 48_000,channels: 1) else {
            throw TVAudioError.noOutputDevice
        }
        let source = Self.makeSource(queue: queue,format: format)
        engine.attach(source)
        engine.connect(source,to: engine.mainMixerNode,format: format)
        engine.mainMixerNode.outputVolume = muted ? 0 : 1
        engine.prepare()
        self.engine = engine; self.source = source
    }
    // Construct the render block outside MainActor isolation. It is invoked by
    // Core Audio's IO thread and may touch only the lock-protected PCM queue.
    nonisolated private static func makeSource(queue: TVPCMQueue,format: AVAudioFormat) -> AVAudioSourceNode {
        AVAudioSourceNode(format: format) { _,_,count,buffers in
            let list = UnsafeMutableAudioBufferListPointer(buffers)
            if let target = list[0].mData?.assumingMemoryBound(to: Float.self) {
                queue.read(into: target,count: Int(count))
            }
            return noErr
        }
    }
    func append(_ samples: [Float]) throws { try queue.append(samples) }
    func start() throws { try engine?.start() }
    func stop() {
        engine?.stop(); engine = nil; source = nil
        queue = TVPCMQueue(); rate = 1
    }
}
