import SwiftUI
import AppKit
import ImageIO
import AnalogCore
import AnalogImaging
import UniformTypeIdentifiers

enum EditingTool: String, CaseIterable { case film = "Film Damage", sstv = "SSTV", tv = "Terrestrial", radio = "Radio", tape = "Tape" }

@MainActor
final class PreviewModel: ObservableObject {
    let tape = TapeModel()
    let filmLab = FilmLabController()
    @Published var original: NSImage?
    @Published private var stillProcessed: NSImage?
    let tvPreviewState = TVPreviewState()
    let tvLightningState = TVLightningState()
    let tvReceptionState = TVReceptionState()
    let tvTXInstrumentState = TVTXInstrumentState()
    private var tvTelemetryBucket: Int?
    var processed: NSImage? {
        get { tool == .tv ? tvPreviewState.processed : stillProcessed }
        set { if tool == .tv { tvPreviewState.processed = newValue } else { stillProcessed = newValue } }
    }
    @Published var sstvOriginal: NSImage?
    var tvOriginal: NSImage? {
        get { tvPreviewState.original }
        set { tvPreviewState.original = newValue }
    }
    @Published var tvDuration: Double = 0 { didSet {
        if tvControlState.tvDuration != tvDuration { tvControlState.tvDuration = tvDuration }
    } }
    var tvTime: Double {
        get { tvPreviewState.time }
        set { tvPreviewState.time = newValue }
    }
    @Published private(set) var tvPlaying = false
    @Published var tvMuted = false { didSet { tvAudio.muted = tvMuted } }
    @Published private(set) var tvHasAudio = false
    private(set) var tvSoundCarrierDB: Float {
        get { tvReceptionState.soundCarrierDB }
        set { tvReceptionState.soundCarrierDB = newValue }
    }
    @Published private(set) var tvPreparationProgress: Double?
    @Published private(set) var tvPreparationStage = TVPreparationProgress.Stage.video
    @Published private(set) var tvPreparing = false
    @Published var tvChannel: TerrestrialSettings = {
        var settings = TerrestrialSettings(system: .palDK)
        settings.propagation.enabled = true
        return settings
    }() { didSet {
        if tvControlState.tvChannel != tvChannel { tvControlState.tvChannel = tvChannel }
        tvPlaybackBuffer?.settings = tvChannel
        updateSelection()
    } }
    @Published var tvStandard: TVStandard = .pal { didSet {
        if oldValue != tvStandard {
            tvPreviewState.crtHistoryID &+= 1
            if tvControlState.tvStandard != tvStandard { tvControlState.tvStandard = tvStandard }
            tvChannel.rfBandwidthMHz = TerrestrialSystem(video: tvStandard).channelMHz
            selectTVStandard()
        }
    } }
    private(set) var tvLock: TelevisionLock {
        get { tvReceptionState.lock }
        set { tvReceptionState.lock = newValue }
    }
    private(set) var tvSynchronization: TelevisionSynchronization {
        get { tvReceptionState.synchronization }
        set { tvReceptionState.synchronization = newValue }
    }
    private(set) var tvAGCDB: Float {
        get { tvReceptionState.agcDB }
        set { tvReceptionState.agcDB = newValue }
    }
    private(set) var tvCarrierErrorHz: Double {
        get { tvReceptionState.carrierErrorHz }
        set { tvReceptionState.carrierErrorHz = newValue }
    }
    private(set) var tvSyncConfidence: Float {
        get { tvReceptionState.syncConfidence }
        set { tvReceptionState.syncConfidence = newValue }
    }
    private(set) var tvRecoveredLines: Int {
        get { tvReceptionState.recoveredLines }
        set { tvReceptionState.recoveredLines = newValue }
    }
    let tvVisionSpectrum = TVSpectrumHistory()
    let tvSoundSpectrum = TVSpectrumHistory()
    var terrestrialSystem: TerrestrialSystem { TerrestrialSystem(video: tvStandard) }
    var tvLockDescription: String {
        switch tvLock {
        case .locked: L("Locked")
        case .holding: L("Sync holdover")
        case .searching: L("Acquiring sync")
        }
    }
    private var tvSourceURL: URL?
    @Published private(set) var tvExporting = false
    @Published private(set) var tvExportProgress: Double = 0
    @Published private(set) var tvExportSpeed: Double = 0
    @Published private(set) var tvExportMessage = ""
    private var tvExportTask: Task<Void, Never>?

    func cancelTVExport() { tvExportTask?.cancel() }

    func exportTVVideo() {
        guard !busy, let source = tvSourceURL else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.quickTimeMovie]
        panel.nameFieldStringValue = source.deletingPathExtension().lastPathComponent + "-AnaLine.mov"
        guard panel.runModal() == .OK, let output = panel.url else { return }
        // Export always uses its own renderer so preview/seek state cannot affect it.
        pauseTVPlayback()
        renderTask?.cancel(); renderTask = nil; renderRun += 1
        let standard = tvStandard, channel = tvChannel
        tvExporting = true; busy = true; tvExportProgress = 0; tvExportSpeed = 0; tvExportMessage = ""
        tvExportTask = Task { [self] in
            let exporter = TVRenderer()
            do {
                _ = try await exporter.loadVideo(source, standard: standard,
                    cache: tvPreferences.configuration)
                let result = try await exporter.exportVideo(to: output, channel: channel) { progress in
                    Task { @MainActor [weak self] in
                        guard let self, self.tvExporting else { return }
                        self.tvExportProgress = progress.fraction
                        self.tvExportSpeed = progress.speed
                    }
                }
                tvExportProgress = 1; tvExportSpeed = result.speed
                status = String(format: L("Export complete · %.2f× · %@"), result.speed, output.lastPathComponent)
            } catch is CancellationError {
                status = L("Export cancelled")
            } catch {
                status = L("Export failed:") + " " + error.localizedDescription
            }
            tvExportMessage = status
            await exporter.unloadVideo()
            tvExporting = false; busy = false; tvExportTask = nil
        }
    }

    @Published var sessionURL: URL?
    private var restoringSession = false
    private var queuedSessionURL: URL?
    private let tvAudio = TVAudioOutput()
    var tvAudioMediaSeconds: Double { tvAudio.mediaSeconds }
    var tvAudioConsumedSamples: Int64 { tvAudio.consumedSamples }
    var tvPlaybackRate: Float { tvAudio.rate }
    var tvAudioUnderrunSamples: Int64 { tvAudio.underrunSamples }
    private var tvPlaybackTask: Task<Void, Never>?
    private var tvPresentationTask: Task<Void, Never>?
    private var tvPlaybackActivity: NSObjectProtocol?
    private var tvPlaybackBuffer: TVPlaybackBuffer?
    private var tvLastPlaybackMetrics = TVPlaybackMetrics()
    var tvPlaybackMetrics: TVPlaybackMetrics { tvPlaybackBuffer?.metrics ?? tvLastPlaybackMetrics }
    // Test harness can suspend production without changing any RF/DSP output.
    var tvPlaybackRenderHook: (@Sendable (Int64) async throws -> Void)?
    private var tvPlaybackRun = 0
    private var tvResumeAfterScrub = false
    @Published var tool: EditingTool = .film { didSet {
        if oldValue == .film { filmLab.pause() }
        if oldValue == .tape { tape.pause() }
        pauseTVPlayback()
        stopTransmission()
        processed = tool == .sstv ? sstvOriginal : original
        restartRender()
    } }
    @Published var sstvSettings = SSTVSettings() { didSet {
        if oldValue.mode != sstvSettings.mode {
            stopTransmission(); transmissionProgress = 0; receivedRows = 0
            restartRender()
        } else { updateSelection() }
    } }
    @Published var renderedSSTV = SSTVSettings()
    @Published var sstvTiming = "Robot36 · 320 × 240 · 12 kHz"
    @Published var transmitting = false
    @Published var transmissionProgress: Double = 0
    @Published var receivedRows = 0
    @Published var channelReadout = ""
    @Published var playbackSpeed: Double = 1 { didSet { if playbackSpeed != 1 { audio.stopMonitor() } } }
    @Published var monitorTX = false { didSet { if !monitorTX { audio.stopMonitor() } } }
    @Published var microphoneEnabled = false
    @Published var microphoneLevel: Float = 0
    static let defaultMicrophoneGain: Float = 4
    @Published var microphoneGain: Float = PreviewModel.defaultMicrophoneGain
    @Published var microphoneStatus = L("Microphone off")
    private let audio = SSTVAudioController()
    private var liveTask: Task<Void,Never>?
    private var microphoneTask: Task<Void,Never>?
    private var microphoneSamples = [Float]()
    private var playbackRun = 0
    private var microphoneRequest = 0
    @Published private var stillStatus = L("Loading Bliss…")
    var status: String {
        get { tool == .tv ? tvPreviewState.status : stillStatus }
        set { if tool == .tv { tvPreviewState.status = newValue } else { stillStatus = newValue } }
    }
    let tvControlState = TVControlState()
    @Published var busy = false { didSet {
        if tvControlState.busy != busy { tvControlState.busy = busy }
        if !busy, let next = queuedSessionURL {
            queuedSessionURL = nil
            Task { openSession(next) }
        }
    } }
    @Published var rendering = false
    @Published var library: LUTLibrary?
    @Published var renderedPreset: LUTPreset?
    @Published var selected = "none" { didSet { restartRender() } }
    @Published var settings = EffectSettings() { didSet { updateSelection() } }
    @Published var renderedSettings = EffectSettings()
    @Published var collection = "Film-Luts" {
        didSet {
            if collection != oldValue {
                search = ""
                let rows = library?.presets.filter { $0.collection == collection } ?? []
                selected = rows.first(where: { p in
                    guard let library else { return false }
                    return FileManager.default.fileExists(atPath: library.root.appendingPathComponent(p.file).path)
                })?.id ?? rows.first?.id ?? "none"
            }
        }
    }
    @Published var search = ""
    private let renderer = LUTRenderer()
    private let sstvRenderer = SSTVRenderer()
    private let tvRenderer = TVRenderer()
    var displayOriginal: NSImage? { tool == .sstv ? sstvOriginal : tool == .tv ? tvOriginal : original }
    private var request = 0
    private var renderRun = 0
    private var renderTask: Task<Void,Never>?
    var started = false
    let tvPreferences: TVPreferences
    init(tvPreferences: TVPreferences = .shared) { self.tvPreferences = tvPreferences }
    var imageDescription = ""
    var collections: [String] { Array(Set(library?.presets.map(\.collection) ?? [])).sorted() }
    var visiblePresets: [LUTPreset] {
        let rows = library?.presets.filter { $0.collection == collection } ?? []
        let filtered = rows.filter { search.isEmpty || $0.name.localizedCaseInsensitiveContains(search) }
        if let current = rows.first(where: { $0.id == selected }), !filtered.contains(where: { $0.id == current.id }) {
            return [current] + filtered
        }
        return filtered
    }
    func restartRender() {
        renderTask?.cancel(); renderTask = nil; renderRun += 1
        updateSelection()
    }
    func updateSelection(immediate: Bool = false) {
        guard !restoringSession else { return }
        if tool == .radio || tool == .tape { rendering = false; return }
        request += 1
        if tool == .tv {
            guard !busy, !tvPlaying else { return }
            guard tvDuration > 0 else {
                rendering = false
                processed = tvOriginal ?? original
                status = L("Load a video to begin terrestrial reception")
                return
            }
            renderTask?.cancel(); renderTask = nil
            renderRun += 1
            let run = renderRun, time = tvTime, channel = tvChannel
            rendering = true
            status = L("Modulating VSB and acquiring terrestrial reception…")
            renderTask = Task {
                do {
                    // Coalesce rapid slider changes before starting the CPU-heavy CVBS pass.
                    if !immediate { try await Task.sleep(for: .milliseconds(90)) }
                    let result = try await tvRenderer.render(time: time, channel: channel)
                    guard run == renderRun, !Task.isCancelled else { return }
                    presentTVPreview(result)
                } catch {
                    guard run == renderRun, !Task.isCancelled else { return }
                    status = L("TV frame processing failed:") + " \(error.localizedDescription)"
                }
                if run == renderRun { renderTask = nil; rendering = false }
            }
            return
        }
        if tool == .sstv && transmitting { return }
        guard let library, original != nil, !busy, renderTask == nil else { return }
        rendering = true
        let run = renderRun
        renderTask = Task {
            while !Task.isCancelled {
                let token = request, selectedID = selected, snapshot = settings.validated
                let toolSnapshot = tool, sstvSnapshot = sstvSettings.validated
                let preset = library.presets.first(where: { $0.id == selectedID })
                status = L("Rendering… uncached LUTs may need to be downloaded on first use")
                do {
                    if toolSnapshot == .sstv {
                        let result = try await sstvRenderer.render(sstvSnapshot)
                        guard run == renderRun, !Task.isCancelled else { return }
                        sstvOriginal = NSImage(cgImage: result.original,size: NSSize(width: result.image.width,height: result.image.height))
                        processed = NSImage(cgImage: result.image,size: NSSize(width: result.image.width,height: result.image.height))
                        renderedSSTV = sstvSnapshot
                        sstvTiming = String(format: "TX %@ · %.0f ms / RX %.0f ms",result.txCached ? "cached" : "generated",result.txSeconds*1000,result.rxSeconds*1000)
                        status = imageDescription + " · " + sstvTiming
                    } else {
                    let result = try await renderer.renderImage(preset,library: library,settings: snapshot)
                    guard run == renderRun, !Task.isCancelled else { return }
                    if selectedID == selected {
                        processed = NSImage(cgImage: result.image,size: NSSize(width: result.image.width,height: result.image.height))
                        renderedPreset = preset; renderedSettings = snapshot
                        status = imageDescription + String(format: " · rendered %.0f ms",result.seconds*1000)
                    }
                    }
                } catch {
                    guard run == renderRun, !Task.isCancelled else { return }
                    status = L("Rendering failed; keeping the previous result:") + " \(error)"
                }
                if token == request { break }
                // Coalesce drag events while continuously displaying completed frames.
                try? await Task.sleep(for: .milliseconds(16))
            }
            if run == renderRun { renderTask = nil; rendering = false }
        }
    }
    func start() {
        guard !started else { return }; started = true
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        do {
            library = try LUTLibrary(root: Bundle.main.resourceURL?.appendingPathComponent("LUTLibrary")
                .existingDirectory ?? root.appendingPathComponent("Assets/LUTLibrary"))
            selected = filmLab.scannerPreset
        } catch { status = L("Could not read LUT library:") + " \(error)"; return }
        let argument = CommandLine.arguments.dropFirst().first
        load(argument.map { URL(fileURLWithPath: $0) } ?? filmLab.resumeURL ?? Bundle.main.url(forResource: "bliss", withExtension: "jpg") ?? root.appendingPathComponent("Assets/bliss.jpg"))
    }
    func choose() {
        if tool == .tape { tape.choose(); return }
        let panel = NSOpenPanel()
        // FFmpeg supports containers which macOS may not classify as UTType.movie.
        if tool != .tv { panel.allowedContentTypes = [.image] }
        panel.canChooseDirectories = false
        if panel.runModal() == .OK, let url = panel.url { load(url) }
    }
    func chooseSession() {
        guard !busy else { return }
        let panel = NSOpenPanel(); panel.allowedContentTypes = [.anaLineSession]
        panel.canChooseDirectories = false
        if panel.runModal() == .OK,let url = panel.url { openSession(url) }
    }
    func sessionSnapshot(at url: URL) -> TVSessionDocument {
        TVSessionDocument(video: tvSourceURL.map { .init(video: $0,session: url) },
            standard: tvStandard,channel: tvChannel,position: tvTime,muted: tvMuted,
            bypassedEchoGain: tvControlState.bypassedSceneEchoGain)
    }
    func writeSession(to url: URL) throws {
        guard !busy else { throw TVSessionDocument.SessionError.busy }
        try sessionSnapshot(at: url).write(to: url)
        sessionURL = url
        NSDocumentController.shared.noteNewRecentDocumentURL(url)
    }
    func saveSession(asNew: Bool = false) {
        guard tool == .tv,!busy else { return }
        var destination = asNew ? nil : sessionURL
        if destination == nil {
            let panel = NSSavePanel(); panel.allowedContentTypes = [.anaLineSession]
            panel.nameFieldStringValue = sessionURL?.lastPathComponent ?? "Terrestrial.analine"
            if panel.runModal() == .OK { destination = panel.url } else { return }
        }
        do { try writeSession(to: destination!) }
        catch { sessionFailure(error) }
    }
    private func sessionFailure(_ error: Error) {
        let alert = NSAlert(); alert.messageText = L("Could not open or save session")
        alert.informativeText = error.localizedDescription; alert.alertStyle = .warning
        alert.runModal()
    }
    func openSession(_ url: URL) {
        if busy { queuedSessionURL = url; return }
        // Decode and resolve the media before changing the active settings.
        do {
            let document = try TVSessionDocument.read(from: url)
            var video = document.video?.resolve(relativeTo: url)
            if let reference = document.video,video == nil {
                let alert = NSAlert(); alert.messageText = L("Locate missing video")
                alert.informativeText = L("Video not found:") + " " + reference.name
                alert.addButton(withTitle: L("Locate Video…")); alert.addButton(withTitle: L("Cancel"))
                guard alert.runModal() == .alertFirstButtonReturn else { return }
                let panel = NSOpenPanel(); panel.canChooseDirectories = false
                panel.message = L("Select the original video or its replacement.")
                guard panel.runModal() == .OK,let replacement = panel.url else { return }
                video = replacement
            }
            let resolved = video
            Task {
                do {
                    try await restoreSession(document,at: url,video: resolved)
                    NSDocumentController.shared.noteNewRecentDocumentURL(url)
                } catch { sessionFailure(error) }
            }
        } catch { sessionFailure(error) }
    }
    func restoreSession(_ document: TVSessionDocument,at url: URL,video: URL?) async throws {
        try document.validate()
        guard !busy else { throw TVSessionDocument.SessionError.busy }
        if let reference = document.video,video == nil { throw TVSessionDocument.SessionError.missingVideo(reference.name) }
        pauseTVPlayback(); stopTransmission(); tvResumeAfterScrub = false
        renderTask?.cancel(); renderTask = nil; renderRun += 1; rendering = false
        restoringSession = true; busy = true
        defer { restoringSession = false; busy = false }
        // FFmpeg caches are rebuilt, never embedded in the small session file.
        let duration: Double
        if let video { duration = try await prepareTVVideo(video,standard: document.standard) }
        else { await tvRenderer.unloadVideo(); duration = 0 }
        tool = .tv; tvStandard = document.standard; tvChannel = document.channel
        tvControlState.restoreSceneEcho(document.bypassedEchoGain)
        tvSourceURL = video; tvDuration = duration; tvMuted = document.muted
        tvHasAudio = video != nil ? await tvRenderer.hasAudioTrack() : false
        let limit = max(0,duration-tvStandard.frameDuration)
        tvTime = floor(min(limit,document.position)*tvStandard.frameRate+1e-7)/tvStandard.frameRate
        tvPreviewState.crtHistoryID &+= 1
        tvOriginal = nil; processed = nil
        tvPreviewState.droppedFrames = 0; tvPreviewState.playbackRate = 1
        imageDescription = video?.lastPathComponent ?? ""
        tvVisionSpectrum.reset(); tvSoundSpectrum.reset(); tvLightningState.reset()
        tvTXInstrumentState.reading = nil; tvSynchronization = TelevisionSynchronization()
        tvLock = .searching; tvAGCDB = 0; tvCarrierErrorHz = 0; tvSyncConfidence = 0; tvRecoveredLines = 0
        sessionURL = url
        restoringSession = false; busy = false
        updateSelection(immediate: true)
    }
    private func selectTVStandard() {
        guard tool == .tv, tvSourceURL != nil, !tvPreparing, !restoringSession else { return }
        pauseTVPlayback()
        renderTask?.cancel(); renderTask = nil; renderRun += 1
        let run = renderRun, standard = tvStandard
        busy = true
        tvVisionSpectrum.reset(); tvSoundSpectrum.reset(); tvLightningState.reset()
        tvTXInstrumentState.reading = nil
        tvSynchronization = TelevisionSynchronization()
        Task {
            do {
                let duration = try await tvRenderer.selectStandard(standard)
                guard run == renderRun else { return }
                tvDuration = duration
                let lastFrame = floor(max(0,duration-standard.frameDuration)*standard.frameRate+1e-7)
                tvTime = min(lastFrame,max(0,(tvTime*standard.frameRate).rounded()))/standard.frameRate
                busy = false; updateSelection(immediate: true)
            } catch {
                guard run == renderRun else { return }
                busy = false; status = L("TV frame processing failed:") + " \(error.localizedDescription)"
            }
        }
    }

    private func prepareTVVideo(_ url: URL,standard: TVStandard? = nil) async throws -> Double {
        tvVisionSpectrum.reset(); tvSoundSpectrum.reset(); tvLightningState.reset()
        tvTXInstrumentState.reading = nil
        tvSynchronization = TelevisionSynchronization()
        tvPreviewState.crtHistoryID &+= 1
        tvPreparing = true; tvPreparationProgress = nil; tvPreparationStage = .video
        defer { tvPreparing = false; tvPreparationProgress = nil }
        return try await tvRenderer.loadVideo(url,standard: standard ?? tvStandard,cache: tvPreferences.configuration) { [weak self] progress in
            Task { @MainActor [weak self] in
                guard let self, self.tvPreparing else { return }
                self.tvPreparationStage = progress.stage
                self.tvPreparationProgress = progress.fraction
            }
        }
    }

    private func presentTVPreview(_ result: TVRenderer.Preview) {
        tvOriginal = NSImage(cgImage: result.original, size: NSSize(width: tvStandard.squarePixelWidth, height: tvStandard.height))
        processed = NSImage(cgImage: result.image, size: NSSize(width: tvStandard.squarePixelWidth, height: tvStandard.height))
        tvTime = Double(result.frameIndex) / tvStandard.frameRate
        tvLightningState.present(events: result.reception.lightningEvents,time: tvTime)
        let bucket = Int(floor(tvTime*10+1e-7))
        // Waterfall buckets are 100 ms. Keep image/transport at the source frame
        // rate, but update telemetry and spectrum together at that bucket cadence.
        if tvPlaying, tvTelemetryBucket == bucket { return }
        tvTelemetryBucket = bucket
        tvTXInstrumentState.reading = result.reception.transmitter
        tvVisionSpectrum.update(result.reception.visionSpectrum, time: tvTime)
        tvSoundSpectrum.update(result.reception.soundSpectrum, time: tvTime)
        tvLock = result.reception.lock; tvAGCDB = result.reception.agcDB
        tvSynchronization = result.reception.synchronization
        tvCarrierErrorHz = result.reception.carrierErrorHz
        tvSyncConfidence = result.reception.syncConfidence
        tvRecoveredLines = result.reception.recoveredLines
        tvSoundCarrierDB = result.reception.soundCarrierDB
        status = String(format: "%@ · %.2f / %.2f s · %@ · %@ · RF %.0f ms / %@ %.0f ms",
            imageDescription, tvTime, result.duration, terrestrialSystem.rawValue, tvLockDescription,
            result.decodeSeconds * 1000,L("Frame total"),(result.totalSeconds-result.prerollSeconds)*1000)
        if tvPlaying {
            status += String(format: " · %@ %.0f ms",L("Peak"),tvPlaybackMetrics.maximumProductionSeconds*1000)
        }
    }

    func toggleTVPlayback() {
        if tvPlaying { pauseTVPlayback() } else { startTVPlayback() }
    }

    private func startTVPlayback() {
        guard tool == .tv, tvDuration > 0, !busy, !tvPlaying else { return }
        renderTask?.cancel(); renderTask = nil; renderRun += 1
        let lastTime = max(0, tvDuration - tvStandard.frameDuration)
        if tvTime >= lastTime { tvTime = 0; tvLightningState.reset(); tvPreviewState.crtHistoryID &+= 1 }
        let startTime = tvTime, standard = tvStandard
        tvPlaybackRun += 1
        let run = tvPlaybackRun
        tvLastPlaybackMetrics = TVPlaybackMetrics()
        tvPreviewState.droppedFrames = 0; tvPreviewState.playbackRate = 1
        tvTelemetryBucket = nil
        tvPlaybackActivity = ProcessInfo.processInfo.beginActivity(
            options: [.userInitiatedAllowingIdleSystemSleep,.latencyCritical],
            reason: "Real-time terrestrial video and audio reception")
        tvPlaying = true; rendering = true
        tvPlaybackTask = Task(priority: .userInitiated) { [self] in
            do {
                await tvRenderer.endPlayback()
                guard run == tvPlaybackRun, !Task.isCancelled else { return }
                let capacity = min(60,max(1,tvPreferences.bufferFrames))
                try tvAudio.prepare(capacity: (capacity+4)*Int(ceil(48_000*standard.frameDuration)))
                let firstFrame = Int64((startTime*standard.frameRate).rounded())
                let startSample = TVSoundClock.offset(frame: firstFrame,standard: standard)
                let buffer = TVPlaybackBuffer(settings: tvChannel,capacity: capacity,firstFrame: firstFrame,frameRate: standard.frameRate)
                tvPlaybackBuffer = buffer
                let pcmQueue = tvAudio.pcmQueue, renderer = tvRenderer, hook = tvPlaybackRenderHook
                // The hot producer loop must never await the main actor merely to
                // deliver a frame. Window layout/painting cannot consume its budget.
                let producer = Task.detached(priority: .userInitiated) { [self] in
                    var time = startTime, exhausted = false, outputStarted = false
                    var recentCosts = [Double]()
                    while !Task.isCancelled {
                        var produced = false
                        while !exhausted && buffer.queuedFrames < capacity && Double(pcmQueue.snapshot.pending)/48_000 < Double(capacity)*standard.frameDuration {
                            if outputStarted {
                                let next = TVPlaybackPacing.nextFrame(after: Int64((time*standard.frameRate).rounded()),
                                    consumedSamples: pcmQueue.snapshot.consumed,startSample: startSample,standard: standard,
                                    leadSeconds: buffer.queuedFrames == 0
                                        ? min(Double(capacity+2)*standard.frameDuration,(recentCosts.max() ?? standard.frameDuration)*1.1) : 0)
                                if Double(next)/standard.frameRate > lastTime+1e-7 { exhausted = true; break }
                                time = Double(next)/standard.frameRate
                            }
                            let productionStart = ContinuousClock.now
                            try await hook?(Int64((time*standard.frameRate).rounded()))
                            let result = try await renderer.render(time: time,channel: buffer.settings,settleAfterSeek: !outputStarted)
                            try Task.checkCancellation()
                            let pcm = result.reception.audio.isEmpty
                                ? [Float](repeating: 0,count: TVSoundClock.count(frame: result.frameIndex,standard: standard))
                                : result.reception.audio
                            try pcmQueue.append(pcm,at: TVSoundClock.offset(frame: result.frameIndex,standard: standard)-startSample)
                            buffer.append(result,frameRate: standard.frameRate)
                            produced = true
                            let wallCost = TVPlaybackMetrics.seconds(productionStart.duration(to: .now))-result.prerollSeconds
                            recentCosts.append(wallCost)
                            if recentCosts.count > 8 { recentCosts.removeFirst() }
                            if outputStarted {
                                buffer.produced(seconds: wallCost,frameDuration: standard.frameDuration,
                                    preview: result)
                            }
                            exhausted = time >= lastTime
                            time = min(lastTime,Double(result.frameIndex+1)/standard.frameRate)
                            if outputStarted { break }
                        }
                        if !outputStarted {
                            guard try await beginTVAudioPresentation(buffer,startTime: startTime,run: run) else { return }
                            outputStarted = true
                        }
                        if exhausted && pcmQueue.snapshot.pending == 0 {
                            let latency = await tvAudio.latency
                            try await Task.sleep(for: .seconds(min(0.5,max(0.03,latency))))
                            try Task.checkCancellation()
                            return
                        }
                        if produced { await Task.yield() }
                        else { try await Task.sleep(for: .milliseconds(2)) }
                    }
                    try Task.checkCancellation()
                }
                try await withTaskCancellationHandler {
                    try await producer.value
                } onCancel: { producer.cancel() }
                guard run == tvPlaybackRun, !Task.isCancelled else { return }
                if let last = buffer.lastPreview { presentTVPreview(last) }
                tvTime = tvDuration
            } catch {
                guard run == tvPlaybackRun, !Task.isCancelled else { return }
                status = L("TV playback failed:") + " \(error.localizedDescription)"
            }
            if run == tvPlaybackRun {
                tvPresentationTask?.cancel(); tvPresentationTask = nil
                tvLastPlaybackMetrics = tvPlaybackMetrics; tvPlaybackBuffer = nil
                tvAudio.stop(); tvPlaying = false; rendering = false; tvPlaybackTask = nil
                endTVPlaybackActivity()
                await tvRenderer.endPlayback()
            }
        }
    }

    private func beginTVAudioPresentation(_ buffer: TVPlaybackBuffer, startTime: Double, run: Int) throws -> Bool {
        guard run == tvPlaybackRun, !Task.isCancelled else { return false }
        try tvAudio.start()
        tvPresentationTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self, run == self.tvPlaybackRun else { return }
                self.presentTVPlayback(buffer,startTime: startTime)
                do { try await Task.sleep(for: .milliseconds(2)) }
                catch { return }
            }
        }
        return true
    }

    private func presentTVPlayback(_ buffer: TVPlaybackBuffer, startTime: Double) {
        // The paused frame is already visible. Cadence begins after device startup.
        let audioTime = tvAudio.mediaSeconds
        guard audioTime > 0 else { return }
        if let visible = buffer.visible(at: startTime+audioTime) { presentTVPreview(visible) }
        let currentFrame = floor(min(tvDuration,startTime+audioTime)*tvStandard.frameRate+1e-7)
        if floor(tvTime*tvStandard.frameRate+1e-7) != currentFrame { tvTime = currentFrame/tvStandard.frameRate }
        let drops = buffer.metrics.skippedFrames
        if tvPreviewState.droppedFrames != drops { tvPreviewState.droppedFrames = drops }
        if tvPreviewState.playbackRate != tvAudio.rate { tvPreviewState.playbackRate = tvAudio.rate }
    }

    func pauseTVPlayback() {
        let wasPlaying = tvPlaying
        tvPlaybackRun += 1; tvPlaybackTask?.cancel(); tvPlaybackTask = nil
        tvPresentationTask?.cancel(); tvPresentationTask = nil
        tvLastPlaybackMetrics = tvPlaybackMetrics; tvPlaybackBuffer = nil
        tvAudio.stop(); tvPlaying = false
        endTVPlaybackActivity()
        if wasPlaying { rendering = false }
    }

    private func endTVPlaybackActivity() {
        if let activity = tvPlaybackActivity {
            ProcessInfo.processInfo.endActivity(activity)
            tvPlaybackActivity = nil
        }
    }

    func seekTV(to time: Double) {
        guard tool == .tv, tvDuration > 0, !busy else { return }
        tvPreviewState.crtHistoryID &+= 1
        tvVisionSpectrum.reset(); tvSoundSpectrum.reset(); tvLightningState.reset()
        let resume = tvPlaying
        pauseTVPlayback()
        let clamped = min(max(0, time), max(0, tvDuration - tvStandard.frameDuration))
        tvTime = floor(clamped * tvStandard.frameRate + 1e-7) / tvStandard.frameRate
        updateSelection()
        if resume && tvTime < max(0, tvDuration - tvStandard.frameDuration) { startTVPlayback() }
    }

    func beginTVScrubbing() {
        tvResumeAfterScrub = tvPlaying
        pauseTVPlayback()
    }

    func endTVScrubbing() {
        let resume = tvResumeAfterScrub; tvResumeAfterScrub = false
        if resume && tvTime < max(0, tvDuration - tvStandard.frameDuration) { startTVPlayback() }
    }
    func pasteImage() {
        guard !busy else { return }
        let board = NSPasteboard.general
        if let url = board.readObjects(forClasses: [NSURL.self], options: [
            .urlReadingFileURLsOnly: true,
            .urlReadingContentsConformToTypes: [UTType.image.identifier]
        ])?.first as? URL {
            load(url)
            return
        }
        guard let data = board.data(forType: .png) ?? board.data(forType: .tiff)
                ?? NSImage(pasteboard: board)?.tiffRepresentation else {
            status = L("No image found on the clipboard"); NSSound.beep(); return
        }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("AnaLine-paste-\(UUID().uuidString).png")
        do {
            try data.write(to: url,options: .atomic)
            load(url,name: "Clipboard",removeAfterRead: true)
        } catch { status = L("Paste failed:") + " \(error.localizedDescription)" }
    }
    func dropImages(_ providers: [NSItemProvider]) {
        guard !busy else { return }
        guard let provider = providers.first(where: {
            $0.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) ||
            $0.hasItemConformingToTypeIdentifier(UTType.image.identifier)
        }) else { return }

        status = tool == .tv ? L("Reading dropped video…") : L("Reading dropped image…")
        if provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
            provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, error in
                let droppedURL: URL?
                if let data = item as? Data { droppedURL = URL(dataRepresentation: data, relativeTo: nil) }
                else if let nsURL = item as? NSURL { droppedURL = nsURL as URL }
                else { droppedURL = item as? URL }
                Task { @MainActor in
                    guard error == nil else { self.status = L("Drop failed:") + " \(error!.localizedDescription)"; return }
                    guard let droppedURL else { self.status = L("Drop failed: could not read file"); return }
                    self.load(droppedURL)
                }
            }
            return
        }

        provider.loadDataRepresentation(forTypeIdentifier: UTType.image.identifier) { data, error in
            Task { @MainActor in
                guard let data, error == nil else {
                    self.status = L("Drop failed:") + " \(error?.localizedDescription ?? L("could not read image"))"
                    return
                }
                let url = FileManager.default.temporaryDirectory
                    .appendingPathComponent("AnaLine-drop-\(UUID().uuidString).png")
                do {
                    try data.write(to: url, options: .atomic)
                    self.load(url, name: "Dropped image", removeAfterRead: true)
                } catch { self.status = L("Drop failed:") + " \(error.localizedDescription)" }
            }
        }
    }
    func load(_ url: URL,name: String? = nil,removeAfterRead: Bool = false) {
        guard !busy else { return }
        if url.pathExtension.lowercased() == "analine" { openSession(url); return }
        pauseTVPlayback(); tvResumeAfterScrub = false
        let isVideo = tool == .tv || UTType(filenameExtension: url.pathExtension)?.conforms(to: .movie) == true
        if isVideo && tool != .tv { tool = .tv }
        stopTransmission()
        request += 1; renderTask?.cancel(); renderTask = nil; renderRun += 1; rendering = false
        busy = true; status = L("Reading image and ICC profile…")
        Task {
            defer { if removeAfterRead { try? FileManager.default.removeItem(at: url) } }
            do {
                if isVideo {
                    status = L("Preparing video with FFmpeg…")
                    let duration = try await prepareTVVideo(url)
                    tvSourceURL = url
                    tvPreviewState.crtHistoryID &+= 1
                    tvOriginal = nil; processed = nil
                    tvPreviewState.droppedFrames = 0; tvPreviewState.playbackRate = 1
                    tvDuration = duration
                    tvTime = 0
                    imageDescription = name ?? url.lastPathComponent
                    tvHasAudio = await tvRenderer.hasAudioTrack()
                    busy = false
                    updateSelection()
                    return
                }
                let result = try await renderer.loadSource(url)
                try await sstvRenderer.loadSource(result.original)
                var bypass = sstvSettings; bypass.mix = 0
                let prepared = try await sstvRenderer.render(bypass)
                sstvOriginal = NSImage(cgImage: prepared.original,size: NSSize(width: prepared.original.width,height: prepared.original.height))
                guard let image = NSImage(data: result.original) else { throw CocoaError(.fileReadCorruptFile) }
                filmLab.loaded(url)
                settings.laboratory = filmLab.session
                original = image; processed = tool == .sstv ? sstvOriginal : image; renderedPreset = nil
                tvDuration = 0; tvOriginal = nil; tvSourceURL = nil
                tvVisionSpectrum.reset(); tvSoundSpectrum.reset(); tvLightningState.reset()
                tvAudio.stop(); tvHasAudio = false
                await tvRenderer.unloadVideo()
                imageDescription = "\(name ?? url.lastPathComponent) · \(result.width) × \(result.height) · \(result.profile)"
                busy = false; updateSelection()
            } catch {
                status = (isVideo ? L("Could not read video:") : L("Could not read image:")) + " \(error.localizedDescription)"
                busy = false
            }
        }
    }
    func toggleMicrophone() {
        if microphoneEnabled { stopMicrophone(); return }
        microphoneRequest += 1
        let token = microphoneRequest
        microphoneEnabled = true; microphoneStatus = L("Requesting microphone permission…")
        microphoneTask = Task {
            do {
                let granted = try await audio.startMicrophone()
                guard token == microphoneRequest, !Task.isCancelled else { return }
                guard granted else {
                    microphoneEnabled = false; microphoneStatus = L("Microphone permission denied; allow AnaLine in System Settings"); return
                }
                microphoneStatus = L("Microphone on · processed in local memory only")
                while !Task.isCancelled {
                    let chunk = audio.microphoneChunk()
                    microphoneLevel = min(1,chunk.level*4)
                    if transmitting {
                        microphoneSamples.append(contentsOf: chunk.pcm)
                        if microphoneSamples.count > 12000 { microphoneSamples.removeFirst(microphoneSamples.count-12000) }
                    }
                    try await Task.sleep(for: .milliseconds(50))
                }
            } catch {
                guard token == microphoneRequest, !Task.isCancelled else { return }
                audio.stopMicrophone(); microphoneEnabled = false; microphoneLevel = 0
                microphoneStatus = L("Microphone unavailable:") + " \(error.localizedDescription)"
            }
        }
    }
    func stopMicrophone() {
        microphoneRequest += 1; microphoneTask?.cancel(); microphoneTask = nil
        audio.stopMicrophone(); microphoneEnabled = false; microphoneLevel = 0
        microphoneSamples.removeAll(); microphoneStatus = L("Microphone off")
    }
    func stopTransmission(stopMic: Bool = true) {
        if transmitting { status = imageDescription + " · " + L("stopped") + " · RX \(receivedRows) / \(sstvSettings.mode.height) " + L("rows") }
        playbackRun += 1; liveTask?.cancel(); liveTask = nil
        transmitting = false; audio.stopMonitor()
        if stopMic { stopMicrophone() }
    }
    func startTransmission() {
        guard !busy, original != nil, tool == .sstv else { return }
        stopTransmission(stopMic: false)
        renderTask?.cancel(); renderTask = nil; renderRun += 1; rendering = false
        transmitting = true; transmissionProgress = 0; receivedRows = 0
        microphoneSamples.removeAll()
        let run = playbackRun
        liveTask = Task {
            do {
                let mode = sstvSettings.mode
                var bypass = sstvSettings; bypass.mix = 0
                let prepared = try await sstvRenderer.render(bypass)
                guard run == playbackRun, !Task.isCancelled else { return }
                sstvOriginal = NSImage(cgImage: prepared.original,size: NSSize(width: mode.width,height: mode.height))
                let session = try await sstvRenderer.beginTransmission(mode: mode)
                let clock = ContinuousClock()
                var previous = clock.now, elapsed: Double = 0
                while !Task.isCancelled {
                    let now = clock.now, duration = previous.duration(to: now).components
                    elapsed += (Double(duration.seconds)+Double(duration.attoseconds)/1e18)*playbackSpeed
                    previous = now
                    let mic = microphoneSamples; microphoneSamples.removeAll(keepingCapacity: true)
                    let snapshot = sstvSettings.validated
                    let monitor = monitorTX && playbackSpeed == 1
                    let result = try await sstvRenderer.advanceTransmission(session: session,to: elapsed,settings: snapshot,
                        microphone: mic,micGain: microphoneEnabled ? microphoneGain : 0,monitor: monitor)
                    guard run == playbackRun, !Task.isCancelled else { return }
                    processed = NSImage(cgImage: result.image,size: NSSize(width: result.image.width,height: result.image.height))
                    transmissionProgress = result.progress; receivedRows = result.rows; renderedSSTV = snapshot
                    channelReadout = String(format: "Current Noise %.0f%% · Offset %+.0f Hz · Clock %+.0f ppm · Signal %.0f%%",
                        result.channel.noise*100,result.channel.offset,result.channel.clockPPM,result.channel.gain*100)
                    sstvTiming = String(format: "TX → RX · %.1f / %.1f s · %d / %d rows",min(snapshot.mode.duration,elapsed),snapshot.mode.duration,result.rows,snapshot.mode.height)
                    status = imageDescription + " · " + sstvTiming
                    if monitor { try audio.play(result.audio) } else { audio.stopMonitor() }
                    if result.complete { status = imageDescription + " · reception complete · \(snapshot.mode.rawValue)"; break }
                    try await Task.sleep(for: .milliseconds(80))
                }
            } catch {
                guard run == playbackRun, !Task.isCancelled else { return }
                status = L("Transmission stopped; keeping received image:") + " \(error.localizedDescription)"
            }
            if run == playbackRun {
                transmitting = false; liveTask = nil
                // Let the last scheduled audio buffer finish before releasing the output device.
                try? await Task.sleep(for: .milliseconds(150))
                guard run == playbackRun else { return }
                audio.stopMonitor(); stopMicrophone()
            }
        }
    }
}

private extension URL {
    var existingDirectory: URL? { FileManager.default.fileExists(atPath: path) ? self : nil }
}

struct ComparisonView: View {
    let before: NSImage
    let after: NSImage
    var scanProgress: CGFloat? = nil
    var crtEnabled = false
    var crtHDR = true
    var crtBrightness = 2.0
    var crtScanlines = 0.0
    var crtLines = 240.0
    var crtMaskStrength = 0.8
    var crtMaxLines = 576.0
    var crtMaskType = TVCRTMaskType.apertureGrille.rawValue
    var crtHistoryID: UInt64 = 0
    var onCRTBrightness: ((TVCRTBrightnessReading) -> Void)? = nil
    var onCRTDrawableSize: ((CGSize) -> Void)? = nil
    var pasteImage: () -> Void = {}
    var pasteEnabled = true
    @State private var split: CGFloat = 0.5
    private func copyProcessedImage() {
        // Copy the rendered pixels at their native size, without comparison overlays.
        guard let cg = after.cgImage(forProposedRect: nil,context: nil,hints: nil),
              let png = NSBitmapImageRep(cgImage: cg).representation(using: .png,properties: [:]) else {
            NSSound.beep(); return
        }
        let item = NSPasteboardItem()
        item.setData(png,forType: .png)
        if let tiff = after.tiffRepresentation { item.setData(tiff,forType: .tiff) }
        NSPasteboard.general.clearContents()
        if !NSPasteboard.general.writeObjects([item]) { NSSound.beep() }
    }
    var body: some View {
        GeometryReader { geometry in
            let scale = min(geometry.size.width/before.size.width, geometry.size.height/before.size.height)
            let w = before.size.width*scale, h = before.size.height*scale
            ZStack(alignment: .topLeading) {
                if crtEnabled, TVCRTDisplay.isAvailable {
                    TVCRTDisplay(image: after, hdr: crtHDR, brightness: crtBrightness, crtLines: crtLines, maskStrength: crtMaskStrength, scanlines: crtScanlines, maxLines: crtMaxLines, maskType: crtMaskType, historyID: crtHistoryID, onBrightness: onCRTBrightness, onDrawableSize: onCRTDrawableSize)
                        .frame(width: w, height: h).allowsHitTesting(false)
                } else {
                    Image(nsImage: after).resizable().frame(width: w,height: h)
                }
                Image(nsImage: before).resizable().frame(width: w,height: h)
                    .mask(alignment: .leading) { Rectangle().frame(width: w*split) }
                if let scanProgress {
                    Rectangle().fill(.orange).frame(width: w,height: 2)
                        .position(x: w/2,y: h*scanProgress)
                }
                HStack {
                Text(L("Original")); Spacer(); Text(L("Processed"))
                }.font(.caption.weight(.semibold)).padding(10)
                    .background(LinearGradient(colors: [.black.opacity(0.55),.clear],startPoint: .top,endPoint: .bottom))
                Path { path in path.move(to: CGPoint(x: w*split,y: 0)); path.addLine(to: CGPoint(x: w*split,y: h)) }
                    .stroke(.black.opacity(0.5),lineWidth: 3)
                Path { path in path.move(to: CGPoint(x: w*split,y: 0)); path.addLine(to: CGPoint(x: w*split,y: h)) }
                    .stroke(.white,style: StrokeStyle(lineWidth: 1.5,dash: [7,5]))
                Image(systemName: "arrow.left.and.right")
                    .font(.system(size: 13,weight: .bold)).padding(10).background(.black.opacity(0.7),in: Circle())
                    .position(x: w*split,y: h/2)
            }
            .frame(width: w,height: h).clipped().contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0).onChanged { split = max(0,min(1,$0.location.x/w)) })
            .contextMenu {
                Button(L("Copy"),systemImage: "doc.on.doc") { copyProcessedImage() }
                Button(L("Paste"),systemImage: "doc.on.clipboard") { pasteImage() }.disabled(!pasteEnabled)
            }
            .accessibilityLabel(L("Original and processed image comparison"))
            .accessibilityValue("Original image shown at \(Int(split*100)) percent")
            .accessibilityAdjustableAction { direction in
                split = max(0,min(1,split + (direction == .increment ? 0.05 : -0.05)))
            }
            .position(x: geometry.size.width/2,y: geometry.size.height/2)
        }
    }
}

struct ContentView: View {
    @ObservedObject var languageStore: LanguageStore
    @ObservedObject private var model: PreviewModel
    @State private var dropIsTargeted = false
    init(languageStore: LanguageStore, model: PreviewModel = PreviewModel()) {
        self.languageStore = languageStore
        self.model = model
    }
    var parameters: [(String,String)] {
        if model.tool == .tv {
            return [(L("Broadcast standard"), model.terrestrialSystem.rawValue),
                (L("Video frame"), String(format: "%.2f / %.2f s", model.tvTime, model.tvDuration)),
                (L("Receiver lock"), model.tvLockDescription)]
        }
        if model.tool == .sstv {
            let s = model.renderedSSTV
            return [("Mode","\(model.renderedSSTV.mode.rawValue) · \(model.renderedSSTV.mode.dimensions)"),("TX / RX",model.sstvTiming),
                ("Noise / Dropout",String(format: "%.0f%% / %.0f%%",s.noise*100,s.dropout*100)),
                ("Offset / Drift",String(format: "%+.0f Hz / %+.0f Hz",s.frequencyOffset,s.drift)),
                ("Clock / Sync",String(format: "%+.0f ppm · %@",s.clockPPM,s.trackSync ? "Tracking" : "Fixed")),
                ("Interference / Mix",String(format: "%.0f%% @ %.0f Hz · %.0f%%",s.interference*100,s.interferenceHz,s.mix*100)),
                ("Seed",String(s.seed))]
        }
        let s = model.renderedSettings
        return [("LUT Mix",String(format: "%.0f%%",s.lutMix*100)),
            ("Pre-LUT Exposure",model.renderedPreset?.role == "sceneToDisplay" ? String(format: "%+.2f EV",s.lutExposureEV) : "N/A"),
            ("Grain",String(format: "%.0f%% · Size %.1f · Texture %.2f · Blur %.2f",s.grain.amount*100,s.grain.size,s.grain.texture,s.grain.blur)),
            ("Light Leak",String(format: "%.0f%% · Hue %.0f° · Seed %u",s.leak.amount*100,s.leak.hue,s.leak.seed)),
            ("LUT Space", model.renderedPreset?.colorDescription ?? "No LUT / sRGB")]
    }
    var body: some View {
        VStack(spacing: 16) {
            // One header, four modes; see `WorkspaceHeader`. The negative
            // padding bleeds its own 20 pt gutter out to the window's side and
            // top edges. Turning off isMovableByWindowBackground stopped AppKit
            // from treating the header as title-bar background, which
            // re-inserted a safe-area inset the old drag path used to absorb;
            // `-20` here takes that same inset back out, once, for every mode.
            WorkspaceHeader(model: model)
                .padding(.horizontal, -20)
                .padding(.top, -20)
            if model.tvPreparing { TVPreparationBar(model: model) }
            if model.tool == .film && model.settings.laboratory?.stage == .scan { HStack {
                TextField(L("Search film stocks…"),text: $model.search).textFieldStyle(.roundedBorder).frame(width: 220)
                Picker(L("Library"),selection: $model.collection) {
                    ForEach(model.collections,id: \.self) { Text($0).tag($0) }
                }.frame(width: 200).disabled(model.busy || model.library == nil)
                Picker(L("Film LUT"),selection: $model.selected) {
                    Text(L("No LUT (keep grain / light leak)")).tag("none")
                    ForEach(model.visiblePresets) { p in Text(p.name).tag(p.id) }
                }.disabled(model.busy || model.library == nil)
                    Text("\(model.library?.presets.filter { $0.collection == model.collection }.count ?? 0) presets")
                    .font(.caption).foregroundStyle(.secondary)
            } }
            if model.tool == .tv {
                ScrollView {
                    VStack(spacing: 16) {
                        HStack(alignment: .top,spacing: 16) {
                            TVPlayerView(model: model)
                                .onDrop(of: [UTType.fileURL,UTType.movie],isTargeted: $dropIsTargeted) { providers in
                                    model.dropImages(providers); return true
                                }
                                .overlay { if dropIsTargeted { Rectangle().stroke(EditingTool.tv.logoAccentColor,lineWidth: 3) } }
                            VStack(spacing: 12) {
                                TVControls(model: model)
                                TVPropagationView(model: model).frame(maxHeight: .infinity)
                            }.frame(minWidth: 300,maxWidth: .infinity).frame(height: 480)
                        }.frame(maxWidth: .infinity,alignment: .leading)
                        HStack(alignment: .top,spacing: 16) {
                            TVTransmitterControls(model: model).frame(width: 420)
                            TVReceiverControls(model: model)
                        }
                    }.padding(.bottom,8).padding(.horizontal,6)
                }.padding(.horizontal,-6)
            } else if model.tool == .radio {
                RadioView()
            } else if model.tool == .tape {
                TapeView(model: model.tape)
            } else if model.tool == .film {
                FilmLabWorkspace(model: model,lab: model.filmLab)
            } else {
            HStack(alignment: .top,spacing: 16) {
                VStack(spacing: 12) {
                    PreviewCanvasView(model: model).overlay {
                        if dropIsTargeted {
                            RoundedRectangle(cornerRadius: 8)
                                .stroke(Color.accentColor, style: StrokeStyle(lineWidth: 3, dash: [8, 5]))
                                .background(Color.accentColor.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
                                .overlay { Text(L("Release to load image")).font(.headline).foregroundStyle(.white) }
                        }
                    }
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                    .onDrop(of: [UTType.fileURL, UTType.image, UTType.movie], isTargeted: $dropIsTargeted) { providers in
                        model.dropImages(providers)
                        return true
                    }
                }.frame(maxWidth: .infinity, maxHeight: .infinity)
                Group {
                    if model.tool == .film { EffectsControls(model: model) }
                    else { SSTVControls(model: model) }
                }.frame(width: 280)
                    .disabled(model.busy || model.original == nil)
            }.frame(minHeight: 360)
            }
            if model.tool == .sstv { HStack {
                Spacer()
                Text(model.tool == .sstv ? "\(model.renderedSSTV.mode.rawValue) · \(L("Signal simulation"))" : model.renderedPreset?.name ?? L("Original / No LUT"))
            }
                .font(.caption).foregroundStyle(.secondary)
            }
            if model.tool == .sstv { Text(model.tool == .sstv ? "\(L("Fit")) \(model.renderedSSTV.mode.dimensions) → TX cache → \(L("baseband channel impairment")) → FM demodulation → \(model.renderedSSTV.mode.rawValue) \(L("reconstruction"))" : L("Source ICC → LUT color transform → LUT Mix → Grain → procedural light leak → sRGB display"))
                .font(.caption2).foregroundStyle(.secondary)
            }
            if model.tool == .film && model.settings.laboratory == nil && model.renderedPreset?.role == "sceneToDisplay" {
                Text(L("PoLUT: adjust pre-LUT exposure to place middle gray; Adobe RGB output is gamut-compressed to sRGB. JPEG already has tone mapping, so scene light is approximate."))
                    .font(.caption).foregroundStyle(.orange)
            }
            if model.tool == .sstv { Divider()
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 300),alignment: .leading)],alignment: .leading,spacing: 12) {
                ForEach(parameters,id: \.0) { name,value in
                    HStack { Text(name).foregroundStyle(.secondary); Spacer(); Text(value).monospacedDigit() }
                        .font(.system(size: 12)).padding(10).background(.white.opacity(0.04),in: RoundedRectangle(cornerRadius: 6))
                }
            }
            }
        }.id(languageStore.language).padding(20).frame(minWidth: 1000,minHeight: 760)
            // Top only: with the native drag surface in the header the window
            // no longer reports the title bar as movable background, so the
            // safe-area inset reappears. Ignoring it again pushes the header
            // back up and restores the pre-drag-refactor title-bar height.
            .ignoresSafeArea(.container, edges: .top)
            .background { WorkspaceGlassBackground().ignoresSafeArea() }
            .preferredColorScheme(.dark)
            .focusedSceneObject(model)
            .onOpenURL { model.openSession($0) }
            .navigationTitle(model.sessionURL?.lastPathComponent ?? L("AnaLine"))
            .environment(\.locale, Locale(identifier: languageStore.language.rawValue))
            .task { model.start() }
            .onAppear {
                // TEMPORARY profiling hook: ANALINE_TOOL=radio opens the radio
                // page so the real app can be sampled in that state.
                if let name = ProcessInfo.processInfo.environment["ANALINE_TOOL"],
                   let tool = EditingTool.allCases.first(where: { $0.rawValue.caseInsensitiveCompare(name) == .orderedSame }) {
                    model.tool = tool
                }
            }
            .onDisappear { model.stopTransmission(); model.pauseTVPlayback(); model.tape.pause() }
            .onPasteCommand(of: [.image, .fileURL]) { _ in model.pasteImage() }
    }
}

@main
struct AnaLineApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var delegate
    @StateObject private var languageStore = LanguageStore()
    @StateObject private var model = PreviewModel()
    var body: some Scene {
        WindowGroup(L("AnaLine")) { ContentView(languageStore: languageStore, model: model) }.defaultSize(width: 1200,height: 900)
            .windowStyle(.hiddenTitleBar)
            .commands { AnaLineAboutCommands(); TVSessionCommands() }
        Window(L("About Ana-Line"), id: "about") {
            AnaLineAboutView()
        }
        .windowResizability(.contentSize)
        .defaultPosition(.center)
        Settings {
            AnaLineSettingsView(languageStore: languageStore)
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular); NSApp.activate(ignoringOtherApps: true)
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}
