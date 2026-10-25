import Foundation
@preconcurrency import AVFoundation
import AppKit
import AnalogCore

struct RadioSceneClip: Sendable {
    let samples: [Float]
    let startSample: Int64
    /// Sequential read from a looping source: one pass, one bounds check, no
    /// modulo per sample. Imported audio is up to 14.4 M samples, so the hot
    /// path must never do per-sample index math it does not need.
    static func block(_ samples: [Float],start: Int,count: Int) -> [Float] {
        guard !samples.isEmpty else { return [Float](repeating: 0,count: count) }
        let period = samples.count
        var output = [Float](repeating: 0,count: count)
        samples.withUnsafeBufferPointer { source in
            output.withUnsafeMutableBufferPointer { destination in
                var index = ((start % period)+period) % period
                for n in 0..<count {
                    destination[n] = source[index]
                    index += 1
                    if index == period { index = 0 }
                }
            }
        }
        return output
    }
}

/// The radio's own DSP + display pipeline, running on its own high-priority
/// serial queue instead of the shared cooperative pool.
///
/// `actor` runs on the cooperative pool: a 6 ms DSP block monopolises one of
/// the pool's few threads, starving every other Task in the process (including
/// the audio-generation Task) and letting the GUI fall behind with it. A private
/// serial `DispatchQueue` at `.userInteractive` isolates radio DSP from both
/// the main queue and the shared cooperative pool. Display objects publish on
/// this queue too, so a measurement never crosses the main-actor boundary just
/// to be rendered.
final class RadioSceneProcessor: @unchecked Sendable {
    private let queue: DispatchQueue
    private var engine: RadioSceneEngine
    private var morse: [UUID:(text: String, speed: Double, start: Int64, samples: [Float])] = [:]
    init(startSample: Int64) {
        queue = DispatchQueue(label: "com.analine.radio.dsp",qos: .userInteractive)
        engine = RadioSceneEngine(audioCursor: startSample)
    }
    /// Async convenience for tests and callers that are not on the audio path.
    /// The live producer uses the callback variant below so its completion never
    /// crosses the MainActor boundary.
    func process(settings: RadioSceneSettings,clips: [UUID:RadioSceneClip]) async throws -> (frame: RadioSceneFrame, seconds: Double) {
        try await withCheckedThrowingContinuation { continuation in
            process(settings: settings,clips: clips) { outcome in
                continuation.resume(with: outcome)
            }
        }
    }
    /// One block of the scene. `clips` is passed per call so a source change
    /// cannot tear mid-block: the caller owns the immutable value it sends.
    /// Completion runs on the producer's own queue, so a block never crosses
    /// the MainActor boundary on its way to the FIFO.
    func process(settings: RadioSceneSettings,clips: [UUID:RadioSceneClip],
                 completion: @escaping (Result<(frame: RadioSceneFrame, seconds: Double),Error>) -> Void) {
            queue.async {
                do {
                    let start = ContinuousClock.now
                    let cursor = self.engine.audioCursor, count = 1024
                    let ids = Set(settings.transmitters.map(\.id))
                    self.morse = self.morse.filter { ids.contains($0.key) }
                    var inputs: [UUID:[Float]] = [:]
                    for tx in settings.transmitters {
                        if tx.mode == .cw {
                            if self.morse[tx.id]?.text != tx.morseText || self.morse[tx.id]?.speed != tx.wordsPerMinute {
                                self.morse[tx.id] = (tx.morseText,tx.wordsPerMinute,cursor,(try? CWMorse.encode(tx.morseText,wordsPerMinute: tx.wordsPerMinute)) ?? [])
                            }
                            let key = self.morse[tx.id]!
                            inputs[tx.id] = RadioSceneClip.block(key.samples,start: Int(cursor-key.start),count: count)
                        } else if let clip = clips[tx.id], !clip.samples.isEmpty {
                            inputs[tx.id] = RadioSceneClip.block(clip.samples,start: Int(max(0,cursor-clip.startSample)),count: count)
                        } else {
                            inputs[tx.id] = (0..<count).map { Float(0.18*sin(2 * Double.pi*tx.toneHz*Double(cursor+Int64($0))/48_000)) }
                        }
                    }
                    let frame = try self.engine.process(inputs,count: count,settings: settings,measure: cursor/1024 % 4 == 0)
                    let d = start.duration(to: .now).components
                    completion(.success((frame,Double(d.seconds)+Double(d.attoseconds)/1e18)))
                } catch { completion(.failure(error)) }
            }
    }
}

/// Stereo output for the scene. The DSP producer and the Core Audio callback
/// are the only two parties that touch the FIFOs; the MainActor controls the
/// engine and reads statistics but never writes audio, so a busy GUI cannot
/// stall a block on its way into the ring buffer.
final class RadioSceneAudioOutput: @unchecked Sendable {
    private let lock = NSLock()
    private var engine: AVAudioEngine?
    private var left = TVPCMQueue(capacity: 24_000), right = TVPCMQueue(capacity: 24_000)
    private(set) var running = false
    private(set) var startRequested = false
    private(set) var callbackCount: Int64 = 0
    private(set) var ranSeconds = 0.0
    private(set) var overruns = 0
    var snapshotValue: (pending: Int, consumed: Int64, underrun: Int64) { left.snapshot }
    private var lastCallback = ContinuousClock.now
    var currentLatency: Double { lock.lock(); defer { lock.unlock() }; return latency }
    var volume: Float = 0.4 { didSet { lock.lock(); let e = engine; lock.unlock(); e?.mainMixerNode.outputVolume = muted ? 0 : volume } }
    var muted = false { didSet { lock.lock(); let e = engine; lock.unlock(); e?.mainMixerNode.outputVolume = muted ? 0 : volume } }
    private var latency = 0.0
    var pending: Int { left.snapshot.pending }
    var consumed: Int64 { left.snapshot.consumed }
    var missing: Int64 { max(left.snapshot.underrun,right.snapshot.underrun) }
    /// Lowest FIFO level seen since the last read. When this is zero the
    /// producer is behind the callback, no matter how fast the DSP itself is.
    var lowWatermark: Int { lock.lock(); defer { lock.unlock() }; let value = watermark; watermark = left.snapshot.pending; return value }
    private var watermark = Int.max
    var mediaSeconds: Double { lock.lock(); defer { lock.unlock() }; return max(0,Double(consumed)/48_000-latency) }
    /// Configured from the MainActor; the FIFOs themselves are replaced only
    /// when no callback can be running.
    func prepare() throws {
        lock.lock(); engine = nil; left = TVPCMQueue(capacity: 24_000); right = TVPCMQueue(capacity: 24_000); latency = 0; watermark = Int.max
        let engine = AVAudioEngine()
        lock.unlock()
        guard engine.outputNode.outputFormat(forBus: 0).sampleRate > 0,
              let format = AVAudioFormat(standardFormatWithSampleRate: 48_000,channels: 2) else { throw TVAudioError.noOutputDevice }
        let source = Self.makeSource(left: left,right: right,format: format, owner: self)
        engine.attach(source); engine.connect(source,to: engine.mainMixerNode,format: format)
        engine.mainMixerNode.outputVolume = muted ? 0 : volume; engine.prepare()
        lock.lock(); self.engine = engine; lock.unlock()
    }
    /// Runs on the DSP producer's queue. The engine may be gone by now, so the
    /// FIFOs stay alive regardless: only the MainActor frees them.
    /// Runs on the DSP producer's queue. The engine may be gone by now, so the
    /// FIFOs stay alive regardless: only the MainActor frees them.
    func bumpCallback() { callbackCount &+= 1 }
    func noteInterval(_ seconds: Double) { ranSeconds += seconds; if seconds > 0.02 { overruns += 1 }; if seconds > 0.05 { print(String(format: "AUDIO_CALLBACK interval %.4f", seconds)) } }
    func append(left: [Float],right: [Float],at sample: Int64) throws {
        lock.lock(); let level = self.left.snapshot.pending; lock.unlock()
        if level < watermark { watermark = level }
        try self.left.append(left.map { max(-1,min(1,$0)) },at: sample)
        try self.right.append(right.map { max(-1,min(1,$0)) },at: sample)
    }
    /// True when the ring can accept one more block. The producer must check
    /// this before running DSP, or the append throws and the scene stops.
    var hasRoomForBlock: Bool { pending + 1024 <= left.capacity }
    func start() throws {
        lock.lock(); let e = engine; lock.unlock()
        guard let e else { return }
        latency = e.outputNode.presentationLatency
        try e.start()
        lock.lock(); running = true; startRequested = true; lock.unlock()
    }
    func stop() {
        lock.lock(); let e = engine; engine = nil; left = TVPCMQueue(capacity: 24_000); right = TVPCMQueue(capacity: 24_000); latency = 0; watermark = Int.max; running = false; startRequested = false
        lock.unlock()
        e?.stop()
    }
    nonisolated private static func makeSource(left: TVPCMQueue,right: TVPCMQueue,format: AVAudioFormat,owner: RadioSceneAudioOutput) -> AVAudioSourceNode {
        var last = ContinuousClock.now
        return AVAudioSourceNode(format: format) { [weak owner] _,_,count,buffers in
            let now = ContinuousClock.now
            let interval = last.duration(to: now).components
            last = now
            owner?.noteInterval(Double(interval.seconds) + Double(interval.attoseconds) / 1e18)
            owner?.bumpCallback()
            let list = UnsafeMutableAudioBufferListPointer(buffers)
            if let p = list[0].mData?.assumingMemoryBound(to: Float.self) { left.read(into: p,count: Int(count)) }
            if list.count > 1, let p = list[1].mData?.assumingMemoryBound(to: Float.self) { right.read(into: p,count: Int(count)) }
            return noErr
        }
    }
}

/// The renderer-facing half of a station's live state. It is a plain object
/// whose publisher runs on a background queue, so the DSP actor can hand data to
/// the UI without a MainActor hop; SwiftUI's `@ObservedObject` coalesces
/// `objectWillChange` and re-evaluates the view on the main queue afterwards.
/// No property here is ever read by the DSP.
final class RadioSceneTXDisplay: ObservableObject, @unchecked Sendable {
    private let lock = NSLock()
    private var _spectrum: TVSpectrum?
    private var _profile: [Float] = []
    var spectrum: TVSpectrum? { lock.lock(); defer { lock.unlock() }; return _spectrum }
    /// Per-row power profile, computed once when a measurement arrives instead of
    /// slicing 2048 bins inside the renderer for every transmitter every frame.
    var profile: [Float] { lock.lock(); defer { lock.unlock() }; return _profile }
    static let profileRows = 160
    /// Producer-side: store the newest measurement without notifying.
    func apply(_ spectrum: TVSpectrum?) {
        let profile = Self.profile(spectrum)
        lock.lock(); _spectrum = spectrum; _profile = profile; lock.unlock()
    }
    /// UI-side: tell SwiftUI to re-read.
    func publish() { objectWillChange.send() }
    static func profile(_ spectrum: TVSpectrum?,rows: Int = profileRows) -> [Float] {
        guard let spectrum, !spectrum.powerDB.isEmpty else { return [] }
        return (0..<rows).map { row in
            let lower = (rows-1-row)*spectrum.powerDB.count/rows
            let upper = min(spectrum.powerDB.count,max(lower+1,(rows-row)*spectrum.powerDB.count/rows))
            return spectrum.powerDB[lower..<upper].max() ?? -120
        }
    }
}
final class RadioSceneRXDisplay: ObservableObject, @unchecked Sendable {
    let history = TVSpectrumHistory()
    /// Wideband RF at this receiver, on a wider raster so the environment
    /// waterfall can be zoomed by cropping instead of magnifying pixels.
    let environmentHistory = TVSpectrumHistory(width: 1024)
    private let lock = NSLock()
    private var _overloaded = false
    private var _levelDB: Float = -100
    private var _scope: [Float] = []
    var overloaded: Bool { lock.lock(); defer { lock.unlock() }; return _overloaded }
    /// Peak of the recovered audio in dBFS, updated once per DSP block.
    var levelDB: Float { lock.lock(); defer { lock.unlock() }; return _levelDB }
    /// Peak envelope of the most recent recovered block, so the card can show
    /// what the demodulator actually produced rather than the source audio.
    var scope: [Float] { lock.lock(); defer { lock.unlock() }; return _scope }
    static let scopeColumns = 96
    /// Producer-side: store the newest measurement without notifying.
    func apply(_ reception: RadioSceneReception,time: Double) {
        let scope = Self.envelope(reception.samples)
        lock.lock()
        _overloaded = reception.overloaded; _levelDB = reception.levelDB; _scope = scope
        lock.unlock()
        history.render(reception.spectrum,time: time)
        environmentHistory.render(reception.environment,time: time)
    }
    /// UI-side: tell SwiftUI to re-read.
    func publish() {
        objectWillChange.send()
        history.publish(); environmentHistory.publish()
    }
    func clear() {
        lock.lock(); _overloaded = false; _levelDB = -100; _scope = []; lock.unlock()
        history.reset(); environmentHistory.reset()
    }
    /// Absolute peak per column over the most recent block: a 21.33 ms envelope
    /// of the demodulated audio, so a beat between two carriers is visible as a
    /// slow amplitude swing rather than aliased sample dots.
    static func envelope(_ samples: [Float],columns: Int = scopeColumns) -> [Float] {
        guard !samples.isEmpty, columns > 0 else { return [] }
        return (0..<columns).map { column in
            let first = column*samples.count/columns
            let end = min(samples.count,max(first+1,(column+1)*samples.count/columns))
            var peak: Float = 0
            for n in first..<end { peak = max(peak,abs(samples[n])) }
            return min(1,peak)
        }
    }
}
/// Shared mutable state between the MainActor (controls) and the DSP producer.
/// Displays are get-or-created here so the producer and the view always hold the
/// same objects even when a station is added mid-playback.
final class RadioSceneStateBox: @unchecked Sendable {
    private let lock = NSLock()
    private var _settings: RadioSceneSettings
    private var _monitor: RadioSceneMonitor
    private var _clips: [UUID:RadioSceneClip]
    private var _txDisplays: [UUID:RadioSceneTXDisplay] = [:]
    private var _rxDisplays: [UUID:RadioSceneRXDisplay] = [:]
    let firstSample: Int64
    init(settings: RadioSceneSettings, monitor: RadioSceneMonitor, clips: [UUID:RadioSceneClip], firstSample: Int64) {
        _settings = settings; _monitor = monitor; _clips = clips; self.firstSample = firstSample
    }
    func snapshot() -> (RadioSceneSettings, RadioSceneMonitor, [UUID:RadioSceneClip]) {
        lock.lock(); defer { lock.unlock() }
        return (_settings,_monitor,_clips)
    }
    func update(settings: RadioSceneSettings? = nil, monitor: RadioSceneMonitor? = nil, clips: [UUID:RadioSceneClip]? = nil) {
        let began = ContinuousClock.now
        lock.lock()
        if let settings { _settings = settings }
        if let monitor { _monitor = monitor }
        if let clips { _clips = clips }
        lock.unlock()
        let d = began.duration(to: .now).components
        RadioSceneTelemetry.knobDragPushNanos += Int(Double(d.seconds)*1e9+Double(d.attoseconds)/1e9)
        RadioSceneTelemetry.knobDragPushes += 1
    }
    func txDisplay(_ id: UUID) -> RadioSceneTXDisplay {
        lock.lock(); defer { lock.unlock() }
        if let existing = _txDisplays[id] { return existing }
        let next = RadioSceneTXDisplay(); _txDisplays[id] = next; return next
    }
    func rxDisplay(_ id: UUID) -> RadioSceneRXDisplay {
        lock.lock(); defer { lock.unlock() }
        if let existing = _rxDisplays[id] { return existing }
        let next = RadioSceneRXDisplay(); _rxDisplays[id] = next; return next
    }
    func removeRX(_ id: UUID) { lock.lock(); _rxDisplays[id] = nil; lock.unlock() }
    func clearDisplays() { lock.lock(); _txDisplays = [:]; _rxDisplays = [:]; lock.unlock() }
    var rxDisplayValues: [RadioSceneRXDisplay] {
        lock.lock(); defer { lock.unlock() }
        return Array(_rxDisplays.values)
    }
    var txDisplayCount: Int { lock.lock(); defer { lock.unlock() }; return _txDisplays.count }
    /// UI-side: one invalidation pass over every display, driven by the 20 Hz
    /// timer. Whatever the producer rendered last is what SwiftUI reads.
    func publishDisplays() {
        lock.lock()
        let tx = Array(_txDisplays.values), rx = Array(_rxDisplays.values)
        lock.unlock()
        for display in tx { display.publish() }
        for display in rx { display.publish() }
    }
}

/// The audio producer. Runs its own loop on the radio DSP queue: produce one
/// block, append it straight into the FIFO, store the display snapshot, then
/// sleep only long enough for the ring to want feeding. It never touches the
/// MainActor and never notifies SwiftUI — the UI timer decides when to draw.
final class RadioSceneProducer: @unchecked Sendable {
    private let queue = DispatchQueue(label: "com.analine.radio.producer",qos: .userInteractive)
    private let processor: RadioSceneProcessor
    private let audio: RadioSceneAudioOutput
    private let firstSample: Int64
    private let lock = NSLock()
    private var _running = false
    private var _processingMS = 0.0, _scheduleMS = 0.0, _fifoMinimum = Int.max
    private var _blocks = 0
    var running: Bool { lock.lock(); defer { lock.unlock() }; return _running }
    var processingMS: Double { lock.lock(); defer { lock.unlock() }; return _processingMS }
    /// Time from wanting a block to having it in the FIFO: DSP plus the wait for
    /// the queue. When this exceeds the block budget, the audio stutters even
    /// though the DSP itself is fast.
    var scheduleMS: Double { lock.lock(); defer { lock.unlock() }; return _scheduleMS }
    /// Lowest FIFO level observed while producing. Zero means the callback found
    /// nothing to play.
    var fifoMinimum: Int { lock.lock(); defer { lock.unlock() }; return _fifoMinimum }
    var blocksProduced: Int { lock.lock(); defer { lock.unlock() }; return _blocks }
    var displayCount: Int { state.txDisplayCount }
    let state: RadioSceneStateBox
    init(state: RadioSceneStateBox, processor: RadioSceneProcessor, audio: RadioSceneAudioOutput) {
        self.state = state
        self.processor = processor; self.audio = audio; self.firstSample = state.firstSample
    }
    func start() {
        lock.lock(); guard !_running else { lock.unlock(); return }; _running = true; lock.unlock()
        queue.async { [self] in self.loop() }
    }
    func stop() { lock.lock(); _running = false; lock.unlock() }
    private func loop() {
        guard running else { return }
        // Backpressure. The producer must never race ahead of the callback:
        // a full ring makes the timestamped append throw, and killing the
        // producer on that error is what silenced the whole scene. Only run
        // DSP when the ring has room for one more block.
        guard audio.hasRoomForBlock else {
            queue.asyncAfter(deadline: .now() + .milliseconds(2)) { [weak self] in self?.loop() }
            return
        }
        let started = ContinuousClock.now
        let (settings, monitor, clips) = state.snapshot()
        processor.process(settings: settings, clips: clips) { [weak self] outcome in
            guard let self else { return }
            let result: (frame: RadioSceneFrame, seconds: Double)
            do { result = try outcome.get() } catch { self.stop(); return }
            do {
                let frame = result.frame, count = 1024
                let zero = [Float](repeating: 0,count: count)
                let rxIDs = settings.receivers.map(\.id)
                let first = rxIDs.first.flatMap { frame.receptions[$0]?.samples } ?? zero
                let second = rxIDs.dropFirst().first.flatMap { frame.receptions[$0]?.samples } ?? zero
                let left: [Float], right: [Float]
                switch monitor {
                case .first: left = first; right = first
                case .second: left = second; right = second
                case .stereo: left = first; right = rxIDs.count > 1 ? second : first
                }
                try audio.append(left: left,right: right,at: frame.firstAudioSample-firstSample)
                let time = Double(frame.firstAudioSample)/48_000
                for (station,spectrum) in frame.transmitSpectra where settings.transmitters.contains(where: { $0.id == station }) {
                    state.txDisplay(station).apply(spectrum)
                }
                for (receiver,reception) in frame.receptions where settings.receivers.contains(where: { $0.id == receiver }) {
                    state.rxDisplay(receiver).apply(reception,time: time)
                }
                let d = started.duration(to: .now).components
                let elapsed = Double(d.seconds)+Double(d.attoseconds)/1e18
                self.lock.lock()
                self._processingMS = result.seconds*1000
                self._scheduleMS = elapsed*1000
                self._fifoMinimum = min(self._fifoMinimum,self.audio.pending)
                self._blocks += 1
                self.lock.unlock()
                // The producer must never wait on the MainActor. Sleep only as
                // long as the ring can afford; the next loop re-checks room
                // before running any DSP.
                let sleep = self.audio.pending < 3072 ? 3_000_000 : 1_500_000
                self.queue.asyncAfter(deadline: .now() + .nanoseconds(sleep)) { [weak self] in self?.loop() }
            } catch {
                // A full ring is not fatal: the callback is behind. Retry.
                self.queue.asyncAfter(deadline: .now() + .milliseconds(2)) { [weak self] in self?.loop() }
            }
        }
    }
}

/// Per-station change signal. `ObservableObject` invalidates at object level, so
/// a `@Published settings` on the model rebuilt all eight transmitter cards and
/// both receivers on every knob tick (measured: 14–17 ms for one move). Each
/// station gets its own signal, so dragging a knob invalidates that card alone.
final class RadioSceneStationSignal: ObservableObject {
    func notify() { objectWillChange.send() }
}

@MainActor
final class RadioSceneClock: ObservableObject {
    @Published var playing = false
    @Published var seconds = 0.0
    @Published var processingMS = 0.0
    /// DSP compute time for the last block, and the end-to-end cost of getting
    /// that block into the FIFO. The difference is scheduling delay.
    @Published var scheduleMS = 0.0
    /// Lowest FIFO level seen while producing. A drop to zero means the audio
    /// callback found nothing to play, whatever the DSP numbers say.
    @Published var fifoMinimum = Int.max
    @Published var underruns: Int64 = 0
    @Published var status = "默认近频场景可直接听到串台；各 TX 可导入独立音源。"
}

enum RadioSceneMonitor: String, CaseIterable { case first = "RX 1", second = "RX 2", stereo = "L / R" }
@MainActor
final class RadioSceneModel: ObservableObject {
    /// Not published on purpose: ObservableObject invalidation is object-level,
    /// so a published settings blob would rebuild the whole scene on every knob
    /// tick. Edits go through `editTX` / `editRX`, which notify only the affected
    /// station's signal. Structural changes bump `structureVersion` instead.
    private(set) var settings = RadioSceneSettings.eightStationScene() { didSet { pushParameters() } }
    /// Bumped when the scene is reconfigured.
    @Published private(set) var structureVersion = 0
    private var signals: [UUID:RadioSceneStationSignal] = [:]
    func stationSignal(_ id: UUID) -> RadioSceneStationSignal {
        if let existing = signals[id] { return existing }
        let next = RadioSceneStationSignal(); signals[id] = next; return next
    }
    func editTX(_ id: UUID,_ body: (inout RadioSceneTX) -> Void) {
        guard let n = settings.transmitters.firstIndex(where: { $0.id == id }) else { return }
        body(&settings.transmitters[n]); stationSignal(id).notify()
    }
    func editRX(_ id: UUID,_ body: (inout RadioSceneRX) -> Void) {
        guard let n = settings.receivers.firstIndex(where: { $0.id == id }) else { return }
        body(&settings.receivers[n]); stationSignal(id).notify()
    }
    private func bumpStructure() { structureVersion += 1 }
    /// Global scene knobs (noise floor, reflection, reference carrier). They move
    /// every marker in the scene, so a scene-wide refresh is correct here; they
    /// live in a popover and are adjusted far less often than a station knob.
    func edit(_ body: (inout RadioSceneSettings) -> Void) {
        body(&settings); bumpStructure()
    }
    /// Scenario setup helper: replaces part of the configuration and refreshes
    /// every marker, since a setup change can move any of them.
    func configure(_ body: (inout RadioSceneSettings) -> Void) {
        body(&settings); bumpStructure()
    }
    @Published var monitor: RadioSceneMonitor = .first { didSet { pushParameters() } }
    @Published var muted = false { didSet { audio.muted = muted } }
    @Published var volume: Float = 0.4 { didSet { audio.volume = volume } }
    @Published var sourceNames: [UUID:String] = [:]
    @Published var loading: UUID?
    /// Which receiver feeds the environment waterfall. `nil` follows the first
    /// receiver, so removing RX 1 falls back instead of leaving an empty panel.
    @Published var environmentRX: UUID?
    let clock = RadioSceneClock()
    private let audio = RadioSceneAudioOutput()
    private(set) var clips: [UUID:RadioSceneClip] = [:] { didSet { sourcesRevision += 1 } }
    /// Bumped whenever the decoded sources change, so the DSP actor is told at
    /// most once per edit instead of every audio block.
    private var sourcesRevision = 0
    private var task: Task<Void,Never>?
    private var generation = 0
    private var playbackStart = 0.0
    /// The parameter snapshot the running producer reads. Kept alive by the
    /// MainActor so the producer never sees a freed box.
    private var state: RadioSceneStateBox?
    /// Kept for diagnostics and for tests to observe block production.
    private var producer: RadioSceneProducer?
    var producerBlocks: Int { producer?.blocksProduced ?? 0 }
    /// Diagnostic: whether the producer's display dictionary is the model's.
    var producerDisplayCount: Int { producer?.displayCount ?? -1 }
    /// Diagnostic: whether the native output engine actually started.
    var audioRunning: Bool { audio.running }
    /// Diagnostic: FIFO level as seen by the producer loop.
    var audioPending: Int { audio.pending }
    var audioConsumed: Int64 { audio.consumed }
    var playbackStarted: Bool { audio.startRequested }
    var audioLatency: Double { audio.currentLatency }
    var audioBlocksConsumed: Int64 { audio.callbackCount }
    var audioSnapshot: (pending: Int, consumed: Int64, underrun: Int64) { audio.snapshotValue }
    var audioRanTime: Double { audio.ranSeconds }
    var audioOverruns: Int { audio.overruns }
    /// Let the MainActor push a knob turn to the producer without awaiting it.
    private func pushParameters() {
        state?.update(settings: settings, monitor: monitor, clips: clips)
    }
    func txDisplay(_ id: UUID) -> RadioSceneTXDisplay { state?.txDisplay(id) ?? cachedBox.txDisplay(id) }
    func rxDisplay(_ id: UUID) -> RadioSceneRXDisplay { state?.rxDisplay(id) ?? cachedBox.rxDisplay(id) }
    /// The box used before playback starts; replaced by the running producer's.
    private lazy var cachedBox = RadioSceneStateBox(settings: settings, monitor: monitor, clips: clips, firstSample: 0)
    var environmentReceiverID: UUID? {
        if let environmentRX, settings.receivers.contains(where: { $0.id == environmentRX }) { return environmentRX }
        return settings.receivers.first?.id
    }
    func addRX() {
        guard settings.receivers.count < RadioSceneSettings.receiverSlots else { return }
        var next = RadioSceneRX(); next.tuningHz = settings.transmitters.last?.carrierHz ?? 0
        settings.receivers.append(next); bumpStructure()
    }
    func removeRX(_ id: UUID) {
        settings.receivers.removeAll { $0.id == id }
        state?.removeRX(id); cachedBox.removeRX(id)
        if environmentRX == id { environmentRX = nil }
        if settings.receivers.isEmpty { pause() }
        bumpStructure()
    }
    /// The scenarios only ever compare two stations. Rather than delete the
    /// other six, they are powered down: the rack is fixed at eight slots, so a
    /// demo is a configuration of the same eight, not a different list.
    func demo(_ kind: Int) {
        let resume = clock.playing; pause(); clock.seconds = 0
        var next = RadioSceneSettings.eightStationScene()
        for slot in next.transmitters.indices {
            next.transmitters[slot].enabled = slot < 2
            next.transmitters[slot].mode = .am
            next.transmitters[slot].powerDB = slot == 1 ? -3 : 0
            next.transmitters[slot].carrierHz = slot == 1 ? 1_500 : 0
        }
        next.transmitters[0].toneHz = 440
        next.transmitters[1].toneHz = 880
        var sideband = RadioSceneRX(); sideband.mode = .usb
        next.receivers[1] = sideband
        if kind == 1 {
            next.transmitters[1].carrierHz = 12_000
            next.receivers[1].mode = .am; next.receivers[1].tuningHz = 12_000
        } else if kind == 2 {
            for n in next.transmitters.indices { next.transmitters[n].mode = .fm; next.transmitters[n].carrierHz = 0 }
            next.transmitters[1].powerDB = -12
            for n in next.receivers.indices { next.receivers[n].mode = .fm }
        }
        settings = next
        clips = [:]; sourceNames = [:]; environmentRX = nil
        state?.clearDisplays(); cachedBox.clearDisplays(); bumpStructure()
        clock.status = kind == 2 ? "FM 同频捕获：调整第二台功率，比较强弱台与等功率竞争。" : kind == 1 ? "邻频场景：收窄 RX 带宽可减少相邻台进入。" : "串台场景：关闭第二个 TX，比较真实 RF 叠加前后的声音。"
        if resume { play() }
    }
    func chooseSource(_ id: UUID) {
        guard loading == nil else { return }
        let panel = NSOpenPanel(); panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        loading = id
        Task {
            do {
                let pcm = try await Task.detached { try RadioAudioFile.read(url) }.value
                if settings.transmitters.contains(where: { $0.id == id }) { setSource(id,samples: pcm,name: url.lastPathComponent) }
            } catch { clock.status = error.localizedDescription }
            loading = nil
        }
    }
    /// Installs a looping source for one transmitter. Shared by the importer and
    /// by tests so both take exactly the same path.
    func setSource(_ id: UUID,samples: [Float],name: String) {
        guard !samples.isEmpty else { return }
        clips[id] = RadioSceneClip(samples: samples,startSample: Int64(clock.seconds*48_000))
        sourceNames[id] = name
        pushParameters()
    }
    func clearSource(_ id: UUID) { clips[id] = nil; sourceNames[id] = nil; pushParameters() }
    func toggle() { if clock.playing { pause() } else { play() } }
    func pause() {
        if clock.playing { clock.seconds = playbackStart+audio.mediaSeconds }
        generation += 1; task?.cancel(); task = nil; clock.playing = false; audio.stop(); state = nil; producer?.stop(); producer = nil
    }
    func resetTime() {
        let resume = clock.playing; pause(); clock.seconds = 0
        // Clear every live receiver display, not a stale side dictionary.
        for display in (state ?? cachedBox).rxDisplayValues { display.clear() }
        if resume { play() }
    }
    func play() {
        guard !settings.receivers.isEmpty else { clock.status = "请先添加 RX。"; return }
        pause()
        do { try settings.validate(); try audio.prepare() } catch { clock.status = "场景启动失败：\(error)"; return }
        let id = generation, firstSample = Int64(clock.seconds*48_000)
        playbackStart = Double(firstSample)/48_000; clock.playing = true; clock.underruns = 0
        let box = RadioSceneStateBox(settings: settings, monitor: monitor, clips: clips, firstSample: firstSample)
        // Starting swaps the display objects that cards observe. Publish this
        // structural change once; clock-only updates cannot reconnect a card
        // that was created before playback to the producer's new display box.
        objectWillChange.send()
        cachedBox = box
        self.state = box
        let producer = RadioSceneProducer(state: box,
            processor: RadioSceneProcessor(startSample: firstSample), audio: audio)
        self.producer = producer
        task = Task { [weak self] in
            guard let self else { return }
            producer.start()
            var published = false, lastUI = ContinuousClock.now
            while !Task.isCancelled, self.generation == id, producer.running {
                // The producer never waits on the MainActor; the MainActor only
                // publishes statistics and reads the parameter box it owns.
                let now = ContinuousClock.now
                if !published || now-lastUI >= .milliseconds(50) {
                    published = true; lastUI = now
                    self.clock.seconds = self.playbackStart+self.audio.mediaSeconds
                    self.clock.underruns = self.audio.missing
                    self.clock.processingMS = producer.processingMS
                    self.clock.scheduleMS = producer.scheduleMS
                    self.clock.fifoMinimum = producer.fifoMinimum
                    // One invalidation pass per tick. The producer has already
                    // rendered the newest snapshot; a slow GUI simply draws that
                    // instead of queueing one update per audio block.
                    self.state?.publishDisplays()
                }
                if self.audio.pending >= 3072, !self.audio.running { try? self.audio.start() }
                try? await Task.sleep(for: .milliseconds(50))
            }
            producer.stop()
        }
        clock.status = "共享 I/Q 场景正在运行；L / R 将两台 RX 分别送到左右声道。"
    }
}
