import Foundation
@preconcurrency import AVFoundation
import AnalogCore
import AppKit
import UniformTypeIdentifiers

struct TapePlaybackSnapshot: Sendable {
    var inputPeak: Float = 0
    var outputPeak: Float = 0
    var leftPeak: Float = 0
    var rightPeak: Float = 0
    var processingMS: Double = 0
    var ended = false
    var error: String?
}

/// File decoding, resampling and tape DSP all run on this private producer queue.
/// The Core Audio callback only drains the preallocated SPSC queues.
final class TapePlaybackWorker: @unchecked Sendable {
    let left = TVPCMQueue(capacity: 8192)
    let right = TVPCMQueue(capacity: 8192)
    let duration: Double
    let startSeconds: Double
    private let queue = DispatchQueue(label: "com.analine.tape.dsp", qos: .userInteractive)
    private let file: AVAudioFile
    private let converter: AVAudioConverter
    private let input: AVAudioPCMBuffer
    private let decoded: AVAudioPCMBuffer
    private let processed: AVAudioPCMBuffer
    private let processor: TapeProcessor
    private let lock = NSLock()
    private var configuration = TapeSettings()
    private var state = TapePlaybackSnapshot()
    private var timer: DispatchSourceTimer?
    private var eof = false

    init(url: URL, settings: TapeSettings, startAt: Double = 0) throws {
        file = try AVAudioFile(forReading: url)
        guard file.length > 0, file.processingFormat.sampleRate > 0,
              let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 48_000,
                                        channels: 2, interleaved: false),
              let converter = AVAudioConverter(from: file.processingFormat, to: format),
              let input = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: 8192),
              let decoded = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 1024),
              let processed = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 1024)
        else { throw TapePlaybackError.invalidFile }
        self.converter = converter; self.input = input; self.decoded = decoded; self.processed = processed
        duration = Double(file.length)/file.processingFormat.sampleRate
        startSeconds = min(max(startAt.isFinite ? startAt : 0,0),duration)
        file.framePosition = min(file.length,AVAudioFramePosition(startSeconds*file.processingFormat.sampleRate))
        processor = try TapeProcessor()
        configuration = settings; processor.configure(settings); processor.reset()
    }
    func configure(_ settings: TapeSettings) { lock.lock(); configuration = settings; lock.unlock() }
    var snapshot: TapePlaybackSnapshot { lock.lock(); defer { lock.unlock() }; return state }
    func consumeMeterSnapshot() -> TapePlaybackSnapshot {
        lock.lock(); defer { lock.unlock() }
        let result=state
        state.leftPeak=0; state.rightPeak=0; state.inputPeak=0; state.outputPeak=0
        return result
    }
    var seconds: Double { min(duration,startSeconds+Double(left.snapshot.consumed)/48_000) }
    var drained: Bool { snapshot.ended && left.snapshot.pending == 0 }
    func start() {
        queue.sync {
            guard timer == nil else { return }
            fill()
            let source = DispatchSource.makeTimerSource(queue: queue)
            source.schedule(deadline: .now(), repeating: .milliseconds(10), leeway: .milliseconds(1))
            source.setEventHandler { [weak self] in self?.fill() }
            timer = source; source.resume()
        }
    }
    func pause() { queue.sync { timer?.cancel(); timer = nil } }
    deinit { timer?.cancel() }
    private func publishError(_ error: Error) {
        lock.lock(); state.error = error.localizedDescription; state.ended = true; lock.unlock()
        eof = true
    }
    private func fill() {
        guard !eof else { return }
        // Bounded work, at most four audio blocks in one timer event.
        for _ in 0..<4 {
            guard left.snapshot.pending < 4096, right.snapshot.pending < 4096 else { return }
            let start = ContinuousClock.now
            var conversionError: NSError?
            var readError: Error?
            let result = converter.convert(to: decoded, error: &conversionError) { [self] requested, status in
                guard file.framePosition < file.length else { status.pointee = .endOfStream; return nil }
                do {
                    try file.read(into: input, frameCount: min(requested,input.frameCapacity))
                    status.pointee = input.frameLength > 0 ? .haveData : .endOfStream
                    return input.frameLength > 0 ? input : nil
                } catch { readError = error; status.pointee = .endOfStream; return nil }
            }
            if let error = readError ?? conversionError { publishError(error); return }
            if result == .error { publishError(TapePlaybackError.invalidFile); return }
            let count = Int(decoded.frameLength)
            if count > 0, let source = decoded.floatChannelData, let target = processed.floatChannelData {
                lock.lock(); let settings = configuration; lock.unlock()
                processor.configure(settings)
                processor.process(left: source[0],right: source[1],outputLeft: target[0],outputRight: target[1],count: count)
                var inPeak: Float = 0, outPeak: Float = 0
                var peaks: [Float] = [0,0]
                for ch in 0..<2 { for n in 0..<count {
                    inPeak = max(inPeak,abs(source[ch][n])); outPeak = max(outPeak,abs(target[ch][n]))
                    peaks[ch]=max(peaks[ch],abs(target[ch][n]))
                } }
                do {
                    try left.append(Array(UnsafeBufferPointer(start: target[0], count: count)))
                    try right.append(Array(UnsafeBufferPointer(start: target[1], count: count)))
                } catch { publishError(error); return }
                let elapsed = start.duration(to: .now).components
                lock.lock()
                state.inputPeak = max(state.inputPeak,inPeak); state.outputPeak = max(state.outputPeak,outPeak)
                state.leftPeak=max(state.leftPeak,peaks[0]); state.rightPeak=max(state.rightPeak,peaks[1])
                state.processingMS = Double(elapsed.seconds)*1000+Double(elapsed.attoseconds)/1e15
                lock.unlock()
            }
            if result == .endOfStream || count == 0 {
                // Flush the short FIR tail so the final samples are not cut off.
                var zero = [Float](repeating: 0,count: 64)
                var tailL = zero, tailR = zero
                zero.withUnsafeMutableBufferPointer { z in
                    tailL.withUnsafeMutableBufferPointer { l in
                        tailR.withUnsafeMutableBufferPointer { r in
                            processor.process(left: z.baseAddress!,right: z.baseAddress!,
                                outputLeft: l.baseAddress!,outputRight: r.baseAddress!,count: 64)
                        }
                    }
                }
                do { try left.append(tailL); try right.append(tailR) }
                catch { publishError(error); return }
                eof = true
                lock.lock(); state.ended = true; lock.unlock()
                return
            }
        }
    }
}

enum TapePlaybackError: LocalizedError {
    case invalidFile
    var errorDescription: String? { L("Could not decode this audio file.") }
}

@MainActor
final class TapeModel: ObservableObject {
    @Published var settings = TapeSettings() { didSet { worker?.configure(settings) } }
    @Published var muted = false { didSet { engine?.mainMixerNode.outputVolume = muted ? 0 : 1 } }
    @Published var linkedInput = true { didSet {
        settings.recordRightDB = linkedInput ? nil : settings.recordDB
    } }
    @Published private(set) var transport = TapeTransport.stopped
    @Published private(set) var meters = TapeMeterState()
    @Published private(set) var counterOrigin = 0.0
    var counterSeconds: Double { position-counterOrigin }
    func resetCounter() { counterOrigin = position }
    func recordLevel(_ channel: Int) -> Double {
        channel == 0 ? settings.recordDB : settings.recordRightDB ?? settings.recordDB
    }
    func setRecordLevel(_ db: Double, channel: Int) {
        let db=min(max(db,-24),18)
        if linkedInput { settings.recordDB=db; settings.recordRightDB=nil }
        else if channel==0 { settings.recordDB=db }
        else { settings.recordRightDB=db }
    }
    @Published private(set) var fileName = ""
    @Published private(set) var duration = 0.0
    @Published private(set) var position = 0.0
    @Published private(set) var playing = false
    @Published private(set) var telemetry = TapePlaybackSnapshot()
    @Published private(set) var message = ""
    private var url: URL?
    private var scopedURL: URL?
    private var worker: TapePlaybackWorker?
    private var engine: AVAudioEngine?
    private var monitor: Task<Void,Never>?
    private var windTask: Task<Void,Never>?
    private var meterDecay: Task<Void,Never>?
    var monitorVolume: Float { engine?.mainMixerNode.outputVolume ?? (muted ? 0 : 1) }
    deinit {
        monitor?.cancel(); windTask?.cancel(); meterDecay?.cancel()
        scopedURL?.stopAccessingSecurityScopedResource()
    }
    func choose() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.audio]; panel.canChooseDirectories = false
        if panel.runModal() == .OK, let url = panel.url { load(url) }
    }
    func load(_ url: URL) {
        stop()
        if let scopedURL { scopedURL.stopAccessingSecurityScopedResource(); self.scopedURL = nil }
        if url.startAccessingSecurityScopedResource() { scopedURL = url }
        do {
            let next = try TapePlaybackWorker(url: url,settings: settings)
            self.url = url; worker = next; fileName = url.lastPathComponent
            duration = next.duration; position = 0; counterOrigin = 0; telemetry = TapePlaybackSnapshot(); message = ""
        } catch { self.url = nil; fileName = ""; duration = 0; message = error.localizedDescription }
    }
    func play() {
        guard !playing, url != nil else { return }
        meterDecay?.cancel(); meterDecay=nil
        windTask?.cancel(); windTask=nil
        if position >= duration { position=0 }
        if worker?.drained == true { engine?.stop(); engine=nil; worker=nil }
        do {
            if worker == nil || worker?.drained == true { worker = try TapePlaybackWorker(url: url!,settings: settings,startAt: position) }
            guard let worker else { return }
            if engine == nil {
                let engine = AVAudioEngine()
                guard engine.outputNode.outputFormat(forBus: 0).sampleRate > 0,
                      let format = AVAudioFormat(standardFormatWithSampleRate: 48_000,channels: 2) else {
                    throw TVAudioError.noOutputDevice
                }
                let source = Self.source(left: worker.left,right: worker.right,format: format)
                engine.attach(source); engine.connect(source,to: engine.mainMixerNode,format: format)
                engine.mainMixerNode.outputVolume = muted ? 0 : 1
                engine.prepare(); self.engine = engine
            }
            worker.start()
            try engine?.start(); playing = true; transport = .playing; message = ""
            monitor = Task { [weak self] in
                while !Task.isCancelled {
                    try? await Task.sleep(for: .milliseconds(33))
                    guard !Task.isCancelled, let self, let worker = self.worker else { return }
                    self.position = worker.seconds; self.telemetry = worker.consumeMeterSnapshot()
                    self.meters.advance(left: Double(self.telemetry.leftPeak),right: Double(self.telemetry.rightPeak),seconds: 0.033)
                    if let error = self.telemetry.error { self.message = error; self.stop(reset: false); return }
                    if worker.drained {
                        // Empty FIFO means handed to Core Audio, not yet audible.
                        let tail=max(0.05,self.engine?.outputNode.presentationLatency ?? 0)
                        try? await Task.sleep(for: .seconds(tail))
                        guard !Task.isCancelled else { return }
                        self.position = self.duration; self.stop(reset: false); return
                    }
                }
            }
        } catch { message = error.localizedDescription; stop(reset: false) }
    }
    func pause() {
        let moving=playing || transport.isWinding
        windTask?.cancel(); windTask=nil
        monitor?.cancel(); monitor = nil
        engine?.pause(); worker?.pause(); playing = false
        if let worker { position = worker.seconds }
        if moving { transport = .paused }
        meterDecay?.cancel()
        meterDecay=Task { [weak self] in
            for _ in 0..<180 {
                try? await Task.sleep(for: .milliseconds(33))
                guard !Task.isCancelled,let self else { return }
                self.meters.advance(left: 0,right: 0,seconds: 0.033)
                if max(self.meters.holdLeft,self.meters.holdRight)<(-59.9) { return }
            }
        }
    }
    func stop(reset: Bool = true) {
        pause(); engine?.stop(); engine = nil; worker = nil
        transport = .stopped
        if reset {
            position = 0; telemetry = TapePlaybackSnapshot(); counterOrigin=0
            meterDecay?.cancel(); meterDecay=nil; meters=TapeMeterState()
        }
    }
    func seek(to seconds: Double) {
        guard url != nil, seconds.isFinite else { return }
        let resume=playing
        let wasPaused=transport == .paused
        stop(reset: false)
        position=min(max(seconds,0),duration)
        if resume && position < duration { play() }
        else if wasPaused { transport = .paused }
    }
    func wind(_ direction: TapeTransport) {
        guard url != nil, direction.isWinding else { return }
        stop(reset: false)
        guard direction == .rewinding ? position > 0 : position < duration else { return }
        transport=direction
        windTask=Task { [weak self] in
            var previous=ContinuousClock.now
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(33))
                guard !Task.isCancelled,let self else { return }
                let now=ContinuousClock.now
                let elapsed=previous.duration(to: now).components
                previous=now
                let seconds=Double(elapsed.seconds)+Double(elapsed.attoseconds)/1e18
                self.position=min(max(self.position+seconds*(direction == .rewinding ? -20 : 20),0),self.duration)
                if self.position <= 0 || self.position >= self.duration {
                    self.transport = .stopped; self.windTask=nil; return
                }
            }
        }
    }
    func togglePause() {
        guard url != nil else { return }
        if transport == .paused { play() }
        else { pause(); transport = .paused }
    }
    nonisolated private static func source(left: TVPCMQueue,right: TVPCMQueue,format: AVAudioFormat) -> AVAudioSourceNode {
        AVAudioSourceNode(format: format) { _,_,count,buffers in
            let list = UnsafeMutableAudioBufferListPointer(buffers)
            if list.count >= 2, let l = list[0].mData?.assumingMemoryBound(to: Float.self),
               let r = list[1].mData?.assumingMemoryBound(to: Float.self) {
                left.read(into: l,count: Int(count)); right.read(into: r,count: Int(count))
            }
            return noErr
        }
    }
}
