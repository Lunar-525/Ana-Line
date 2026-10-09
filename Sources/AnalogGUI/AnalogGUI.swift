import SwiftUI
import AppKit
import ImageIO
import AnalogCore
import AnalogImaging
import UniformTypeIdentifiers
@preconcurrency import AVFoundation

enum EditingTool: String, CaseIterable { case film = "Film Damage", sstv = "SSTV", tv = "Terrestrial" }

@MainActor
final class PreviewModel: ObservableObject {
    @Published var original: NSImage?
    @Published var processed: NSImage?
    @Published var sstvOriginal: NSImage?
    @Published var tvOriginal: NSImage?
    @Published var tvDuration: Double = 0
    @Published var tvTime: Double = 0
    @Published private(set) var tvPlaying = false
    @Published var tvMuted = false { didSet { tvAudioPlayer?.isMuted = tvMuted } }
    @Published var tvChannel = TerrestrialSettings(system: .palDK) { didSet { updateSelection() } }
    @Published var tvStandard: TVStandard = .pal { didSet {
        if oldValue != tvStandard {
            tvChannel.rfBandwidthMHz = TerrestrialSystem(video: tvStandard).channelMHz
            reloadTVVideo()
        }
    } }
    @Published private(set) var tvLock: TelevisionLock = .searching
    @Published private(set) var tvAGCDB: Float = 0
    @Published private(set) var tvCarrierErrorHz: Double = 0
    @Published private(set) var tvSyncConfidence: Float = 0
    @Published private(set) var tvRecoveredLines = 0
    var terrestrialSystem: TerrestrialSystem { TerrestrialSystem(video: tvStandard) }
    var tvLockDescription: String {
        switch tvLock {
        case .locked: L("Locked")
        case .holding: L("Sync holdover")
        case .searching: L("Acquiring sync")
        }
    }
    private var tvSourceURL: URL?
    private var tvAudioPlayer: AVPlayer?
    private var tvPlaybackTask: Task<Void, Never>?
    private var tvPlaybackRun = 0
    private var tvResumeAfterScrub = false
    @Published var tool: EditingTool = .film { didSet {
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
    @Published var status = L("Loading Bliss…")
    @Published var busy = false
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
    func updateSelection() {
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
                    try await Task.sleep(for: .milliseconds(90))
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
            selected = library?.presets.first(where: { $0.collection == "Film-Luts" && $0.name.contains("portra") })?.id ?? "none"
        } catch { status = L("Could not read LUT library:") + " \(error)"; return }
        let argument = CommandLine.arguments.dropFirst().first
        load(argument.map { URL(fileURLWithPath: $0) } ?? Bundle.main.url(forResource: "bliss", withExtension: "jpg") ?? root.appendingPathComponent("Assets/bliss.jpg"))
    }
    func choose() {
        let panel = NSOpenPanel()
        // FFmpeg supports containers which macOS may not classify as UTType.movie.
        if tool != .tv { panel.allowedContentTypes = [.image] }
        panel.canChooseDirectories = false
        if panel.runModal() == .OK, let url = panel.url { load(url) }
    }
    private func reloadTVVideo() {
        guard tool == .tv, let url = tvSourceURL, !busy else { return }
        pauseTVPlayback()
        renderTask?.cancel(); renderTask = nil; renderRun += 1
        busy = true; status = L("Preparing video with FFmpeg…")
        Task {
            do {
                let duration = try await tvRenderer.loadVideo(url, standard: tvStandard)
                tvDuration = duration; tvTime = min(tvTime, max(0, duration - 1 / tvStandard.frameRate))
                await prepareTVAudio()
                busy = false; updateSelection()
            } catch { busy = false; status = L("TV frame processing failed:") + " \(error.localizedDescription)" }
        }
    }

    private func prepareTVAudio() async {
        tvAudioPlayer?.pause()
        let url = await tvRenderer.playbackAudioURL()
        tvAudioPlayer = url.map { AVPlayer(url: $0) }
        tvAudioPlayer?.isMuted = tvMuted
    }

    private func presentTVPreview(_ result: TVRenderer.Preview) {
        tvOriginal = NSImage(cgImage: result.original, size: NSSize(width: result.original.width, height: result.original.height))
        processed = NSImage(cgImage: result.image, size: NSSize(width: result.image.width, height: result.image.height))
        tvTime = Double(result.frameIndex) / tvStandard.frameRate
        tvLock = result.reception.lock; tvAGCDB = result.reception.agcDB
        tvCarrierErrorHz = result.reception.carrierErrorHz
        tvSyncConfidence = result.reception.syncConfidence
        tvRecoveredLines = result.reception.recoveredLines
        status = String(format: "%@ · %.2f / %.2f s · %@ · %@ · RF %.0f ms",
            imageDescription, tvTime, result.duration, terrestrialSystem.rawValue, tvLockDescription,
            result.decodeSeconds * 1000)
    }

    func toggleTVPlayback() {
        if tvPlaying { pauseTVPlayback() } else { startTVPlayback() }
    }

    private func startTVPlayback() {
        guard tool == .tv, tvDuration > 0, !busy, !tvPlaying else { return }
        renderTask?.cancel(); renderTask = nil; renderRun += 1
        let lastTime = max(0, tvDuration - tvStandard.frameDuration)
        if tvTime >= lastTime { tvTime = 0 }
        let startTime = tvTime
        tvPlaybackRun += 1
        let run = tvPlaybackRun
        tvPlaying = true; rendering = true
        tvPlaybackTask = Task {
            do {
                if let player = tvAudioPlayer {
                    _ = await player.seek(to: CMTime(seconds: startTime, preferredTimescale: 60000),
                        toleranceBefore: .zero, toleranceAfter: .zero)
                    guard run == tvPlaybackRun, !Task.isCancelled else { return }
                    player.play()
                }
                let clock = ContinuousClock()
                var time = startTime
                var playbackRate: Float = 1
                while !Task.isCancelled {
                    let frameStart = clock.now
                    let result = try await tvRenderer.render(time: time, channel: tvChannel)
                    guard run == tvPlaybackRun, !Task.isCancelled, tool == .tv else { return }
                    presentTVPreview(result)
                    if time >= lastTime { tvTime = tvDuration; break }
                    let spent = frameStart.duration(to: clock.now).components
                    let spentSeconds = Double(spent.seconds) + Double(spent.attoseconds) / 1e18
                    // Keep RF samples continuous. A CPU-limited preview slows its clock,
                    // rather than discarding input frames required by the receiver state.
                    let desiredRate = Float(min(1, tvStandard.frameDuration / max(spentSeconds, tvStandard.frameDuration)))
                    playbackRate = 0.7 * playbackRate + 0.3 * desiredRate
                    if let player = tvAudioPlayer {
                        let audioTime = player.currentTime().seconds
                        if audioTime.isFinite, abs(audioTime - time) > 0.15 {
                            _ = await player.seek(to: CMTime(seconds: time, preferredTimescale: 60000),
                                toleranceBefore: .zero, toleranceAfter: .zero)
                        }
                        guard run == tvPlaybackRun, !Task.isCancelled else { return }
                        player.rate = playbackRate
                    }
                    time = min(lastTime, Double(result.frameIndex + 1) / tvStandard.frameRate)
                    let remaining = tvStandard.frameDuration - spentSeconds
                    if remaining > 0 { try await Task.sleep(for: .seconds(remaining)) }
                }
            } catch {
                guard run == tvPlaybackRun, !Task.isCancelled else { return }
                status = L("TV frame processing failed:") + " \(error.localizedDescription)"
            }
            if run == tvPlaybackRun {
                tvAudioPlayer?.pause(); tvPlaying = false; rendering = false; tvPlaybackTask = nil
                await tvRenderer.endPlayback()
            }
        }
    }

    func pauseTVPlayback() {
        let wasPlaying = tvPlaying
        tvPlaybackRun += 1; tvPlaybackTask?.cancel(); tvPlaybackTask = nil
        tvAudioPlayer?.pause(); tvPlaying = false
        if wasPlaying { rendering = false; Task { await tvRenderer.endPlayback() } }
    }

    func seekTV(to time: Double) {
        guard tool == .tv, tvDuration > 0, !busy else { return }
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
                    let duration = try await tvRenderer.loadVideo(url, standard: tvStandard)
                    tvSourceURL = url
                    tvOriginal = nil; processed = nil
                    tvDuration = duration
                    tvTime = 0
                    imageDescription = name ?? url.lastPathComponent
                    await prepareTVAudio()
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
                original = image; processed = tool == .sstv ? sstvOriginal : image; renderedPreset = nil
                tvDuration = 0; tvOriginal = nil; tvSourceURL = nil
                tvAudioPlayer = nil
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
                Image(nsImage: after).resizable().frame(width: w,height: h)
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
    @StateObject private var model = PreviewModel()
    @State private var dropIsTargeted = false
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
            HStack {
                VStack(alignment: .leading,spacing: 4) {
                    HStack(spacing: 16) {
                        AnaLineLogo(tool: model.tool, width: 240)
                        ToolModeSwitch(selection: $model.tool)
                            .disabled(model.busy)
                    }
                    Text(model.status).font(.caption).foregroundStyle(.secondary)
                        .lineLimit(1).textSelection(.enabled)
                        .help(model.status)
                }
                Spacer()
                if model.busy || (model.rendering && !model.tvPlaying) { ProgressView().controlSize(.small) }
                Button { model.choose() } label: {
                    Text(model.tool == .tv ? L("Choose Video…") : L("Choose Image…"))
                        .font(.system(size: 13, weight: .medium))
                        .frame(width: 120, height: 80)
                }
                .buttonStyle(HeaderImageButtonStyle())
                .disabled(model.busy)
            }
            .padding(20)
            .background(Color.black)
            .padding(.horizontal, -20)
            .padding(.top, -20)
            if model.tool == .film { HStack {
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
            HStack(alignment: .top,spacing: 16) {
                VStack(spacing: 12) {
                    ZStack {
                        Color.black.opacity(0.3)
                        if let before = model.displayOriginal, let after = model.processed {
                            ComparisonView(before: before,after: after,
                                scanProgress: model.transmitting ? CGFloat(model.receivedRows)/CGFloat(model.sstvSettings.mode.height) : nil,
                                pasteImage: { model.pasteImage() },pasteEnabled: !model.busy).padding(12)
                        } else {
                            VStack(spacing: 10) {
                                Image(systemName: model.tool == .tv ? "film" : "photo.badge.plus").font(.system(size: 30))
                                Text(model.busy || model.rendering ? L("Generating processed result…") : model.tool == .tv ? L("Drop a video here to start") : L("Drop an image here, or press ⌘V to paste"))
                                Text(model.tool == .tv ? L("You can also click “Choose Video…” above") : L("You can also click “Choose Image…” above")).font(.caption)
                            }.foregroundStyle(.secondary)
                        }
                    }.overlay {
                        if dropIsTargeted {
                            RoundedRectangle(cornerRadius: 8)
                                .stroke(Color.accentColor, style: StrokeStyle(lineWidth: 3, dash: [8, 5]))
                                .background(Color.accentColor.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
                                .overlay { Text(model.tool == .tv ? L("Release to load video") : L("Release to load image")).font(.headline).foregroundStyle(.white) }
                        }
                    }
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                    .onDrop(of: [UTType.fileURL, UTType.image, UTType.movie], isTargeted: $dropIsTargeted) { providers in
                        model.dropImages(providers)
                        return true
                    }
                    if model.tool == .tv { TVPlaybackBar(model: model) }
                }.frame(maxWidth: .infinity, maxHeight: .infinity)
                Group {
                    if model.tool == .film { EffectsControls(model: model) }
                    else if model.tool == .sstv { SSTVControls(model: model) }
                    else { TVControls(model: model) }
                }.frame(width: 280)
                    .disabled(model.busy || (model.tool != .tv && model.original == nil))
            }.frame(minHeight: 360)
            HStack { Text(L("Drag the divider to compare before and after")); Spacer(); Text(model.tool == .tv ? "\(model.terrestrialSystem.rawValue) · \(model.tvLockDescription)" : model.tool == .sstv ? "\(model.renderedSSTV.mode.rawValue) · \(L("Signal simulation"))" : model.renderedPreset?.name ?? L("Original / No LUT")) }
                .font(.caption).foregroundStyle(.secondary)
            Text(model.tool == .tv ? "FFmpeg → \(model.tvStandard.width) × \(model.tvStandard.height) @ \(model.tvStandard.ffmpegFrameRate) → CVBS → VSB RF → multipath / noise → tuner / AGC → sync / burst → RGB" : model.tool == .sstv ? "\(L("Fit")) \(model.renderedSSTV.mode.dimensions) → TX cache → \(L("baseband channel impairment")) → FM demodulation → \(model.renderedSSTV.mode.rawValue) \(L("reconstruction"))" : L("Source ICC → LUT color transform → LUT Mix → Grain → procedural light leak → sRGB display"))
                .font(.caption2).foregroundStyle(.secondary)
            if model.tool == .film && model.renderedPreset?.role == "sceneToDisplay" {
                Text(L("PoLUT: adjust pre-LUT exposure to place middle gray; Adobe RGB output is gamut-compressed to sRGB. JPEG already has tone mapping, so scene light is approximate."))
                    .font(.caption).foregroundStyle(.orange)
            }
            Divider()
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 300),alignment: .leading)],alignment: .leading,spacing: 12) {
                ForEach(parameters,id: \.0) { name,value in
                    HStack { Text(name).foregroundStyle(.secondary); Spacer(); Text(value).monospacedDigit() }
                        .font(.system(size: 12)).padding(10).background(.white.opacity(0.04),in: RoundedRectangle(cornerRadius: 6))
                }
            }
        }.id(languageStore.language).padding(20).frame(minWidth: 1000,minHeight: 760).preferredColorScheme(.dark)
            .environment(\.locale, Locale(identifier: languageStore.language.rawValue))
            .task { model.start() }
            .onDisappear { model.stopTransmission(); model.pauseTVPlayback() }
            .onPasteCommand(of: [.image, .fileURL]) { _ in model.pasteImage() }
    }
}

@main
struct AnaLineApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var delegate
    @StateObject private var languageStore = LanguageStore()
    var body: some Scene {
        WindowGroup(L("AnaLine")) { ContentView(languageStore: languageStore) }.defaultSize(width: 1200,height: 900)
            .commands { AnaLineAboutCommands() }
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
