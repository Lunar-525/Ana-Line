import Foundation
@preconcurrency import AVFoundation
import AnalogCore

/// Only this lock-protected object crosses the audio callback boundary.
private final class MicrophoneBuffer: @unchecked Sendable {
    private let lock = NSLock()
    private var samples = [Float]()
    private var rate: Double = 48000
    func append(_ buffer: AVAudioPCMBuffer) {
        guard let channels = buffer.floatChannelData, buffer.format.channelCount > 0 else { return }
        let n = Int(buffer.frameLength), channelCount = Int(buffer.format.channelCount)
        var mono = [Float](repeating: 0,count: n)
        for c in 0..<channelCount { for i in 0..<n {
            mono[i] += (buffer.format.isInterleaved ? channels[0][i*channelCount+c] : channels[c][i])/Float(channelCount)
        } }
        lock.lock(); defer { lock.unlock() }
        if rate != buffer.format.sampleRate { samples.removeAll(); rate = buffer.format.sampleRate }
        samples.append(contentsOf: mono)
        let limit = Int(rate) // At most one second of local, volatile audio.
        if samples.count > limit { samples.removeFirst(samples.count-limit) }
    }
    func drain() -> ([Float],Double) {
        lock.lock(); defer { lock.unlock() }
        let result = samples; samples = []; return (result,rate)
    }
}

@MainActor
final class SSTVAudioController {
    private var inputEngine: AVAudioEngine?
    private var outputEngine: AVAudioEngine?
    private var player: AVAudioPlayerNode?
    private let inputBuffer = MicrophoneBuffer()
    private var resampler = SSTVPCMResampler()
    private var microphoneRequest = 0
    func startMicrophone() async throws -> Bool {
        microphoneRequest += 1
        let token = microphoneRequest
        guard await AVCaptureDevice.requestAccess(for: .audio), token == microphoneRequest else { return false }
        let engine = AVAudioEngine(), input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else { throw CocoaError(.featureUnsupported) }
        let buffer = inputBuffer
        input.installTap(onBus: 0,bufferSize: 1024,format: format) { pcm,_ in buffer.append(pcm) }
        do { engine.prepare(); try engine.start(); inputEngine = engine; resampler = SSTVPCMResampler() }
        catch { input.removeTap(onBus: 0); engine.stop(); throw error }
        return true
    }
    func stopMicrophone() {
        microphoneRequest += 1
        if let engine = inputEngine { engine.inputNode.removeTap(onBus: 0); engine.stop() }
        inputEngine = nil; _ = inputBuffer.drain(); resampler = SSTVPCMResampler()
    }
    func microphoneChunk() -> (pcm: [Float],level: Float) {
        let (samples,rate) = inputBuffer.drain()
        guard !samples.isEmpty else { return ([],0) }
        let rms = sqrt(samples.reduce(Float(0)) { $0+$1*$1 }/Float(samples.count))
        return (resampler.convert(samples,inputRate: rate),rms)
    }
    func play(_ samples: [Float]) throws {
        guard !samples.isEmpty else { return }
        let format = AVAudioFormat(standardFormatWithSampleRate: 12000,channels: 1)!
        if outputEngine == nil {
            let engine = AVAudioEngine(), node = AVAudioPlayerNode()
            engine.attach(node); engine.connect(node,to: engine.mainMixerNode,format: format)
            engine.prepare(); try engine.start(); node.play()
            outputEngine = engine; player = node
        }
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format,frameCapacity: AVAudioFrameCount(samples.count)),
              let target = buffer.floatChannelData?[0] else { throw CocoaError(.coderInvalidValue) }
        buffer.frameLength = AVAudioFrameCount(samples.count)
        samples.withUnsafeBufferPointer { target.update(from: $0.baseAddress!,count: samples.count) }
        player?.scheduleBuffer(buffer)
    }
    func stopMonitor() { player?.stop(); outputEngine?.stop(); player = nil; outputEngine = nil }
}
