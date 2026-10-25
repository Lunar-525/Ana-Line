import Foundation
@preconcurrency import AVFoundation
import CAtomicRing

/// Bounded single-producer / single-consumer ring buffer shared with the
/// real-time Core Audio callback. The producer owns `write`, the callback owns
/// `read` and `consumed`; each reads the other's counter through a C11 atomic
/// with the appropriate ordering. The render thread never blocks, never
/// allocates, and never waits on a mutex — a mutex here would let a preempted
/// producer hold the callback hostage (priority inversion), which is exactly
/// the stutter we are removing. An underrun emits silence and advances the 1x
/// timeline.
///
/// `read` (the ring index) and `consumed` (the timeline) are deliberately
/// separate: a short read advances the ring by what was really there but the
/// timeline by the whole request, so a stalled producer is heard as silence
/// rather than as a gap that shifts everything after it.
final class TVPCMQueue: @unchecked Sendable {
    private let storage: UnsafeMutablePointer<Float>
    /// Monotonic sample counters. They never wrap in practice (2^63 samples is
    /// centuries at 48 kHz), so index arithmetic stays exact and the classic
    /// "is the ring empty or full?" ambiguity cannot occur.
    private let writeCount: UnsafeMutablePointer<Int64>     // producer-owned
    private let readCount: UnsafeMutablePointer<Int64>      // consumer-owned, ring index
    private let consumedCount: UnsafeMutablePointer<Int64>  // consumer-owned, timeline
    private let missingCount: UnsafeMutablePointer<Int64>   // consumer-owned
    let capacity: Int
    init(capacity: Int = 48_000) {
        self.capacity = capacity
        storage = .allocate(capacity: capacity)
        storage.initialize(repeating: 0,count: capacity)
        writeCount = .allocate(capacity: 1); writeCount.initialize(to: 0)
        readCount = .allocate(capacity: 1); readCount.initialize(to: 0)
        consumedCount = .allocate(capacity: 1); consumedCount.initialize(to: 0)
        missingCount = .allocate(capacity: 1); missingCount.initialize(to: 0)
    }
    deinit {
        storage.deallocate(); writeCount.deallocate(); readCount.deallocate()
        consumedCount.deallocate(); missingCount.deallocate()
    }
    private var writePosition: Int64 { ring_load_relaxed(writeCount) }
    private var readPosition: Int64 { ring_load_acquire(readCount) }
    private var timelinePosition: Int64 { ring_load_relaxed(consumedCount) }
    private func store(_ value: Float,at position: Int64) {
        storage[Int(position % Int64(capacity))] = value
    }
    func append(_ samples: [Float]) throws {
        var write = writePosition
        let room = Int(Int64(capacity)-(write-readPosition))
        guard samples.count <= room else { throw TVAudioError.bufferFull }
        for value in samples { store(value,at: write); write += 1 }
        ring_store_release(writeCount,write)
    }
    /// Timestamped PCM: late samples are discarded, and gaps are silent. A slow
    /// RF producer can never queue old speech behind the current picture clock.
    func append(_ samples: [Float],at sample: Int64) throws {
        var write = writePosition
        let available = write-readPosition
        let endpoint = timelinePosition+available
        let late = Int(min(Int64(samples.count),max(0,endpoint-sample)))
        let gap = max(0,sample-endpoint)
        let room = Int64(capacity)-available
        guard gap <= room,Int64(samples.count-late) <= room-gap else { throw TVAudioError.bufferFull }
        for _ in 0..<Int(gap) { store(0,at: write); write += 1 }
        for n in late..<samples.count { store(samples[n],at: write); write += 1 }
        ring_store_release(writeCount,write)
    }
    /// Real-time safe: a fixed, bounded copy with no allocation and no locking.
    /// When the ring is short the remainder is zero-filled and the timeline
    /// still advances, so a stalled producer never blocks the callback.
    func read(into target: UnsafeMutablePointer<Float>, count: Int) {
        let read = readPosition
        let available = Int(ring_load_acquire(writeCount)-read)
        let actual = Swift.min(available,count)
        for n in 0..<actual { target[n] = storage[Int((read+Int64(n)) % Int64(capacity))] }
        for n in actual..<count { target[n] = 0 }
        ring_store_release(readCount,read+Int64(actual))
        ring_store_relaxed(consumedCount,timelinePosition+Int64(count))
        ring_fetch_add_relaxed(missingCount,Int64(count-actual))
    }
    var snapshot: (pending: Int, consumed: Int64, underrun: Int64) {
        let pending = Int(ring_load_acquire(writeCount)-ring_load_acquire(readCount))
        return (pending,ring_load_relaxed(consumedCount),ring_load_relaxed(missingCount))
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
