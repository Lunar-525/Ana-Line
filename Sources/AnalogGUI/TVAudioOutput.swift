import Foundation
@preconcurrency import AVFoundation

/// Bounded FIFO shared with the real-time callback. No allocation or DSP occurs
/// on the audio thread. An underrun emits silence without advancing media time.
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
    func read(into target: UnsafeMutablePointer<Float>, count: Int) {
        lock.lock(); defer { lock.unlock() }
        let actual = min(available,count)
        for n in 0..<actual {
            target[n] = storage[readIndex]
            readIndex = (readIndex+1)%storage.count
        }
        for n in actual..<count { target[n] = 0 }
        available -= actual; consumed += Int64(actual); missing += Int64(count-actual)
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
    private var speed: AVAudioUnitTimePitch?
    private var queue = TVPCMQueue()
    var pcmQueue: TVPCMQueue { queue }
    private(set) var rate: Float = 1
    var muted = false { didSet { engine?.mainMixerNode.outputVolume = muted ? 0 : 1 } }
    var pendingSeconds: Double { Double(queue.snapshot.pending)/48_000 }
    var consumedSamples: Int64 { queue.snapshot.consumed }
    var underrunSamples: Int64 { queue.snapshot.underrun }
    var latency: Double {
        (engine?.outputNode.presentationLatency ?? 0)+(speed?.latency ?? 0)
    }
    var mediaSeconds: Double { max(0,Double(consumedSamples)/48_000-latency*Double(rate)) }

    func prepare() throws {
        stop()
        let engine = AVAudioEngine()
        guard engine.outputNode.outputFormat(forBus: 0).sampleRate > 0,
              let format = AVAudioFormat(standardFormatWithSampleRate: 48_000,channels: 1) else {
            throw TVAudioError.noOutputDevice
        }
        let source = Self.makeSource(queue: queue,format: format)
        let speed = AVAudioUnitTimePitch(); speed.rate = 1; speed.pitch = 0
        engine.attach(source); engine.attach(speed)
        engine.connect(source,to: speed,format: format)
        engine.connect(speed,to: engine.mainMixerNode,format: format)
        engine.mainMixerNode.outputVolume = muted ? 0 : 1
        engine.prepare()
        self.engine = engine; self.source = source; self.speed = speed
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
    func setRate(_ requested: Float) {
        // TimePitch preserves pitch; a slow smoothed clock protects a CPU-limited
        // receiver without repeated seeks or discontinuous audio-file playback.
        let target = max(0.25,min(1,requested))
        rate = 0.85*rate+0.15*target
        speed?.rate = rate
    }
    func stop() {
        engine?.stop(); engine = nil; source = nil; speed = nil
        queue = TVPCMQueue(); rate = 1
    }
}
