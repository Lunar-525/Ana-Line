import SwiftUI
import PhotosUI
import Combine
import AVFoundation
import UniformTypeIdentifiers

/// A video chosen from the photo library. PHPicker hands over a file that lives
/// only for the duration of the call, so it is copied before returning.
struct PickedVideo: Transferable {
    let url: URL
    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(contentType: .movie) { video in
            SentTransferredFile(video.url)
        } importing: { received in
            let name = "AnaLine-import-\(UUID().uuidString)." + (received.file.pathExtension.isEmpty ? "mov" : received.file.pathExtension)
            let copy = FileManager.default.temporaryDirectory.appendingPathComponent(name)
            try? FileManager.default.removeItem(at: copy)
            try FileManager.default.copyItem(at: received.file, to: copy)
            return Self(url: copy)
        }
    }
}

struct MobileSession: Codable {
    var version = 1
    var mediaName: String
    var standard: TVStandard
    var settings: TerrestrialSettings
    var position: Double
    var muted: Bool
}
struct SessionFile: FileDocument {
    static var readableContentTypes: [UTType] { [.json] }
    var data: Data
    init(data: Data) { self.data = data }
    init(configuration: ReadConfiguration) throws { data = configuration.file.regularFileContents ?? Data() }
    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper { FileWrapper(regularFileWithContents: data) }
}

@MainActor
final class MobileSound {
    private let engine = AVAudioEngine()
    private let player = AVAudioPlayerNode()
    private let format = AVAudioFormat(standardFormatWithSampleRate: 48000, channels: 1)!
    private var connected = false
    func append(_ samples: [Float], muted: Bool) throws {
        if !connected {
            engine.attach(player); engine.connect(player, to: engine.mainMixerNode, format: format); connected = true
        }
        if !engine.isRunning {
            try AVAudioSession.sharedInstance().setCategory(.playback, mode: .default)
            try AVAudioSession.sharedInstance().setActive(true)
            try engine.start()
        }
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count)) else { return }
        buffer.frameLength = AVAudioFrameCount(samples.count)
        samples.withUnsafeBufferPointer { pointer in
            buffer.floatChannelData![0].update(from: pointer.baseAddress!, count: samples.count)
        }
        player.volume = muted ? 0 : 1
        player.scheduleBuffer(buffer)
        if !player.isPlaying { player.play() }
    }
    func mute(_ muted: Bool) { player.volume = muted ? 0 : 1 }
    func stop() {
        player.stop(); engine.pause()
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }
}

@MainActor
final class MobileModel: ObservableObject {
    @Published var standard = TVStandard.pal
    @Published var settings = TerrestrialSettings(system: .palDK)
    @Published var position: Double = 0
    @Published var duration: Double = 0
    @Published var original: UIImage?
    @Published var simulated: UIImage?
    @Published var compare: Double = 0
    @Published var playing = false
    @Published var busy = false
    @Published var exporting = false
    @Published var progress: Double = 0
    @Published var speed: Double = 0
    @Published var fps: Double = 0
    @Published var processingMS: Double = 0
    @Published var locked = false
    @Published var muted = false { didSet { sound.mute(muted) } }
    /// The chosen 4:3 window onto the video, applied by the reader. Nil until the
    /// user picks one, which keeps the long-standing whole-picture fit.
    @Published var crop: MobileCrop?
    @Published var message = "从文件导入视频，或打开内置串扰演示。"
    @Published var output: URL?
    @Published var thermal = ProcessInfo.processInfo.thermalState
    private var source: URL?
    private var pendingSession: MobileSession?
    private var task: Task<Void, Never>?
    private var generation = UUID()
    private let media = MobileMedia()
    private let sound = MobileSound()

    static var mediaDirectory: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("Media")
    }
    var loaded: Bool { source != nil && duration > 0 }
    var thermalText: String {
        switch thermal { case .nominal: "正常"; case .fair: "温热"; case .serious: "高温"; case .critical: "最高热状态"; @unknown default: "未知" }
    }
    func pause() {
        generation = UUID(); task?.cancel(); task = nil; playing = false; sound.stop()
    }
    func cancel() { pause() }

    func importFile(_ url: URL) {
        guard !busy else { return }
        pause()
        let token = generation
        busy = true; progress = 0; output = nil; duration = 0; original = nil; simulated = nil; message = "正在导入…"
        // A window chosen for one video means nothing for the next.
        if url.pathExtension.lowercased() != "json" { crop = nil }
        task = Task { [self] in
            let accessible = url.startAccessingSecurityScopedResource()
            defer { if accessible { url.stopAccessingSecurityScopedResource() } }
            do {
                if url.pathExtension.lowercased() == "json" {
                    let session = try JSONDecoder().decode(MobileSession.self, from: Data(contentsOf: url))
                    guard session.version == 1, session.position.isFinite, session.position >= 0,
                          URL(fileURLWithPath: session.mediaName).lastPathComponent == session.mediaName else {
                        throw MobileMediaError.message("会话格式无效。")
                    }
                    try session.settings.validate(rate: session.standard.sampleRate)
                    let local = Self.mediaDirectory.appendingPathComponent(session.mediaName)
                    pendingSession = session
                    guard FileManager.default.fileExists(atPath: local.path) else {
                        throw MobileMediaError.message("会话的视频不在本机，请导入原视频或替代视频；会话参数将保留。")
                    }
                    source = local
                } else {
                    try FileManager.default.createDirectory(at: Self.mediaDirectory, withIntermediateDirectories: true)
                    let local = Self.mediaDirectory.appendingPathComponent(UUID().uuidString+"-"+url.lastPathComponent)
                    try FileManager.default.copyItem(at: url, to: local)
                    source = local
                }
                if let session = pendingSession {
                    standard = session.standard; settings = session.settings; position = session.position; muted = session.muted
                } else { position = 0 }
                guard let source else { return }
                duration = try await media.load(source, standard: standard, settings: settings) { value in
                    Task { @MainActor [weak self] in if self?.generation == token { self?.progress = value } }
                }
                try Task.checkCancellation()
                position = min(position, max(0, duration-standard.frameDuration))
                try await media.configure(standard: standard, settings: settings, at: position, crop: crop)
                if let frame = try await media.next(), generation == token { present(frame) }
                pendingSession = nil; message = "视频已准备好。"; progress = 1
                // Test hook: the same launch-argument pattern as --preview-demo, so a
                // headless run can measure playback without tapping the button.
                if ProcessInfo.processInfo.arguments.contains("--autoplay") { play() }
            } catch is CancellationError { message = "已取消。" }
            catch { await media.close(); source = nil; duration = 0; message = error.localizedDescription }
            if generation == token || !playing { busy = false; task = nil }
        }
    }
    func present(_ frame: MobileFrame) {
        original = frame.original; simulated = frame.simulated; position = frame.seconds
        processingMS = frame.processingMS; locked = frame.locked
    }
    func refresh() {
        guard loaded, !busy else { return }
        pause(); let token = generation
        let standard = standard, settings = settings, time = position
        task = Task { [self] in
            do {
                try await media.configure(standard: standard, settings: settings, at: time, crop: crop)
                if let frame = try await media.next(), token == generation { present(frame) }
            } catch is CancellationError { }
            catch { if token == generation { message = error.localizedDescription } }
        }
    }
    /// Adopt a window and re-render the current position with it.
    func apply(_ crop: MobileCrop?) {
        self.crop = crop
        refresh()
    }
    /// The whole, un-cropped picture for the crop editor.
    func cropPreview() async -> UIImage? {
        try? await media.sourcePreview(at: position)
    }
    func play() {
        guard loaded, !busy else { return }
        if playing { pause(); return }
        pause(); playing = true; let token = generation
        if position >= duration-standard.frameDuration { position = 0 }
        let time = position, standard = standard, settings = settings
        task = Task { [self] in
            do {
                try await media.configure(standard: standard, settings: settings, at: time, crop: crop)
                let start = ContinuousClock.now
                var delivered = 0
                while let frame = try await media.next() {
                    try Task.checkCancellation(); guard generation == token else { break }
                    let deadline = start.advanced(by: .seconds(Double(delivered)/standard.frameRate))
                    if let audio = frame.audio { try sound.append(audio, muted: muted) }
                    if deadline > .now { try await Task.sleep(until: deadline, clock: .continuous) }
                    present(frame); delivered += 1
                    let elapsed = max(standard.frameDuration, MobileMedia.seconds(start.duration(to: .now)))
                    fps = Double(delivered)/elapsed; speed = fps/standard.frameRate
                }
                if token == generation { playing = false; sound.stop(); message = "播放结束。" }
            } catch is CancellationError { }
            catch { if token == generation { playing = false; sound.stop(); message = error.localizedDescription } }
        }
    }
    func preset(_ name: String) {
        guard !busy else { return }
        let profile = settings.performance
        var next = TerrestrialSettings(system: TerrestrialSystem(video: standard))
        next.performance = profile
        switch name {
        case "串扰", "干净":
            next.carrierToNoiseDB = 100; next.frontEnd.enabled = name == "串扰"
            next.frontEnd.inputSaturationDB = 0; next.frontEnd.inputHardness = 1
            next.frontEnd.inputAMPMDegrees = 30; next.frontEnd.ifSaturationDB = 60
        case "多径": next.echoGain = 0.25; next.echoDelayMicroseconds = 6; next.carrierToNoiseDB = 35
        case "雨天": next.propagation.enabled = true; next.propagation.weather.enabled = true; next.propagation.weather.rainMMHour = 30
        default: break
        }
        settings = next
    }
    func demo() {
        guard !busy else { return }
        if let url = Bundle.main.url(forResource: "crosstalk-source", withExtension: "mov") {
            standard = .ntsc; preset("串扰"); importFile(url)
        }
        else { message = "内置演示资源缺失。" }
    }

    /// Test hook: play the bundled demo for a fixed window and write down what was
    /// measured, so playback speed can be checked without a person watching. A
    /// Debug build is -Onone and runs the whole DSP chain unoptimised, so only a
    /// Release build says anything about the phone.
    func measurePlayback(seconds: Double = 20) {
        demo()
        Task { [self] in
            // Wait for the import to settle first: play() refuses while busy, and the
            // first frame after an import is a cold start rather than steady state.
            for _ in 0..<600 where !(loaded && !busy) { try? await Task.sleep(for: .milliseconds(200)) }
            play()
            try? await Task.sleep(for: .seconds(seconds))
            let report: [String: Any] = ["fps": fps, "speed": speed, "processingMS": processingMS,
                                         "standard": standard.rawValue, "windowSeconds": seconds,
                                         "message": message]
            let url = Self.mediaDirectory.deletingLastPathComponent()
                .appendingPathComponent("playback-measurement.json")
            if let data = try? JSONSerialization.data(withJSONObject: report, options: .prettyPrinted) {
                try? data.write(to: url, options: .atomic)
            }
            print("PLAYBACKMEASURE \(report)")
        }
    }
    func session() throws -> SessionFile {
        guard let source else { throw MobileMediaError.message("请先导入视频。") }
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return SessionFile(data: try encoder.encode(MobileSession(mediaName: source.lastPathComponent,
            standard: standard, settings: settings, position: position, muted: muted)))
    }
    func export() {
        guard loaded, !busy, let source else { return }
        pause(); let token = generation
        busy = true; exporting = true; progress = 0; speed = 0; output = nil; message = "正在渲染并输出…"
        let standard = standard, settings = settings
        task = Task { [self] in
            let exporter = MobileMedia()
            let file = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("AnaLine-"+UUID().uuidString+".mov")
            do {
                _ = try await exporter.load(source, standard: standard, settings: settings) { _ in }
                speed = try await exporter.export(to: file) { progress in
                    Task { @MainActor [weak self] in
                        if self?.generation == token { self?.progress = progress.fraction; self?.speed = progress.speed }
                    }
                }
                try Task.checkCancellation()
                output = file; progress = 1; message = String(format: "输出完成 · %.2f×", speed)
            } catch is CancellationError { try? FileManager.default.removeItem(at: file); message = "输出已取消。" }
            catch { try? FileManager.default.removeItem(at: file); message = error.localizedDescription }
            await exporter.close()
            busy = false; exporting = false; task = nil
        }
    }
}

struct MobileContentView: View {
    @StateObject private var model = MobileModel()
    @Environment(\.scenePhase) private var scenePhase
    @State private var importing = false
    @State private var pickedVideo: PhotosPickerItem?
    @State private var cropping = false
    @State private var cropPreview: UIImage?
    @State private var cameraMode = false
    @State private var saving = false
    @State private var document = SessionFile(data: Data())
    @State private var scrubbing = false
    private let timer = Timer.publish(every: 1, on: .main, in: .common).autoconnect()
    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 16) {
                    preview
                    HStack {
                        Button { model.play() } label: { Label(model.playing ? "暂停" : "播放", systemImage: model.playing ? "pause.fill" : "play.fill") }
                            .disabled(!model.loaded || model.busy)
                        Spacer()
                        Text(String(format: "%.1f / %.1f s", model.position, model.duration)).monospacedDigit().font(.caption)
                        Button { model.muted.toggle() } label: { Image(systemName: model.muted ? "speaker.slash.fill" : "speaker.wave.2.fill") }
                    }
                    Slider(value: Binding(get: { min(max(0, model.position), max(0.001, model.duration-model.standard.frameDuration)) },
                        set: { model.position = $0 }), in: 0...max(0.001, model.duration-model.standard.frameDuration)) { editing in
                        scrubbing = editing
                        if editing { model.pause() } else { model.refresh() }
                    }.disabled(!model.loaded || model.busy)
                    HStack {
                        Picker("制式", selection: $model.standard) { Text("PAL").tag(TVStandard.pal); Text("NTSC").tag(TVStandard.ntsc) }
                        Picker("模拟档位", selection: Binding(get: { model.settings.performance == .mobile },
                            set: { model.settings.performance = $0 ? .mobile : .full })) {
                            Text("Full").tag(false); Text("Fast").tag(true)
                        }
                    }.pickerStyle(.segmented).disabled(model.busy)
                    Text("Full 保留参考精度；Fast 使用经过容差验证的加速档位。").font(.caption).foregroundStyle(.secondary)
                    HStack {
                        Text(String(format: "%.1f fps · %.2f× · %.1f ms", model.fps, model.speed, model.processingMS))
                        Spacer(); Text(model.thermalText).foregroundStyle(model.thermal.rawValue >= 2 ? .orange : .secondary)
                    }.font(.caption).monospacedDigit()
                    Text(model.message).font(.caption).frame(maxWidth: .infinity, alignment: .leading).textSelection(.enabled)
                    if model.busy {
                        ProgressView(value: model.progress)
                        HStack { Text(String(format: "%.0f%% · %.2f×", model.progress*100, model.speed)); Spacer(); Button("取消") { model.cancel() } }
                    }
                    HStack {
                        Button("渲染并输出") { model.export() }.buttonStyle(.borderedProminent).disabled(!model.loaded || model.busy)
                        if let output = model.output { ShareLink(item: output) { Label("保存／分享", systemImage: "square.and.arrow.up") } }
                    }
                    DisclosureGroup("模拟参数") {
                        VStack(spacing: 12) {
                            parameter("调谐偏移 · kHz", value: $model.settings.tuningOffsetKHz, range: -150...150)
                            parameter("信号强度 · dB", value: $model.settings.signalDB, range: -40...12)
                            parameter("载噪比 · dB", value: $model.settings.carrierToNoiseDB, range: 10...100)
                            parameter("多径幅度", value: $model.settings.echoGain, range: 0...0.8)
                            parameter("多径延迟 · µs", value: $model.settings.echoDelayMicroseconds, range: 0...20)
                            Toggle("发射功放", isOn: $model.settings.transmitter.enabled)
                            parameter("发射功率 · dB", value: $model.settings.transmitter.powerDB, range: -12...12)
                            Toggle("共享前端非线性", isOn: $model.settings.frontEnd.enabled)
                            parameter("输入饱和功率 · dB", value: $model.settings.frontEnd.inputSaturationDB, range: -20...30)
                            Toggle("传播场景", isOn: $model.settings.propagation.enabled)
                            HStack { ForEach(["干净", "串扰", "多径", "雨天"], id: \.self) { name in Button(name) { model.preset(name) } } }
                        }.padding(.top, 10)
                    }.disabled(model.busy)
                    Button(model.crop == nil ? "取景与旋转…" : "取景与旋转（已裁切）…") {
                        Task { cropPreview = await model.cropPreview(); cropping = true }
                    }.disabled(!model.loaded || model.busy)
                    HStack {
                        Button("内置串扰演示") { model.demo() }.disabled(model.busy)
                        Spacer()
                        Button("保存会话") {
                            do { document = try model.session(); saving = true } catch { model.message = error.localizedDescription }
                        }.disabled(!model.loaded || model.busy)
                    }
                    Text("预览和输出保持制式帧率，不会因高温自动降低帧率。设备处理不足时播放可能不流畅；iPhone 12 最高热状态仍待验收。").font(.caption2).foregroundStyle(.secondary)
                }.padding()
            }
            .navigationTitle("AnaLine")
            .toolbar {
                ToolbarItemGroup(placement: .topBarTrailing) {
                    // PHPicker, so no library permission is asked for and only
                    // videos can be chosen.
                    PhotosPicker(selection: $pickedVideo, matching: .videos) {
                        Label("导入", systemImage: "photo.on.rectangle")
                    }
                    .disabled(model.busy)
                    Menu {
                        Button { cameraMode = true } label: { Label("实时录制（摄像头）…", systemImage: "video") }
                        Button { importing = true } label: { Label("从文件导入…", systemImage: "folder") }
                    } label: { Image(systemName: "ellipsis.circle") }
                    .disabled(model.busy)
                }
            }
            .onChange(of: pickedVideo) { _, item in
                guard let item else { return }
                Task {
                    if let video = try? await item.loadTransferable(type: PickedVideo.self) {
                        model.importFile(video.url)
                    } else {
                        model.message = "无法读取所选视频。"
                    }
                    pickedVideo = nil
                }
            }
            .fullScreenCover(isPresented: $cameraMode) {
                CameraView(standard: model.standard) { cameraMode = false }
            }
            .sheet(isPresented: $cropping) {
                CropView(preview: cropPreview, initial: model.crop ?? .full) { choice in model.apply(choice) }
            }
            .fileImporter(isPresented: $importing, allowedContentTypes: [.movie, .video, .json]) { result in
                switch result { case .success(let url): model.importFile(url); case .failure(let error): model.message = error.localizedDescription }
            }
            .fileExporter(isPresented: $saving, document: document, contentType: .json, defaultFilename: "AnaLine-session") { result in
                if case .failure(let error) = result { model.message = error.localizedDescription }
            }
            .onChange(of: model.standard) { _, _ in
                model.settings.rfBandwidthMHz = TerrestrialSystem(video: model.standard).channelMHz; model.refresh()
            }
            .onChange(of: model.settings) { _, _ in model.refresh() }
            .onChange(of: scenePhase) { _, value in if value != .active { model.pause() } }
            .task {
                if ProcessInfo.processInfo.arguments.contains("--validate-recording") {
                    for line in await MobileCamera.recordingReport() { print("RECORD " + line) }
                } else if ProcessInfo.processInfo.arguments.contains("--validate-presets") {
                    for line in MobileCamera.presetReport() { print("PRESET " + line) }
                } else if ProcessInfo.processInfo.arguments.contains("--validate-audio") {
                    for line in MobileCamera.audioReport() { print("AUDIO " + line) }
                } else if ProcessInfo.processInfo.arguments.contains("--camera") {
                    cameraMode = true
                } else if ProcessInfo.processInfo.arguments.contains("--measure-playback") {
                    model.measurePlayback()
                } else if ProcessInfo.processInfo.arguments.contains("--validate-crop") {
                    model.busy = true; model.message = "正在验证 4:3 取景…"
                    model.message = await MobileValidation.cropReport(); model.busy = false
                } else if ProcessInfo.processInfo.arguments.contains("--validate-initial-app") {
                    model.busy = true; model.message = "正在验证原生媒体链路…"
                    model.message = await MobileValidation.run(); model.busy = false
                } else if ProcessInfo.processInfo.arguments.contains("--preview-demo") { model.demo() }
            }
            .onChange(of: model.playing) { _, value in UIApplication.shared.isIdleTimerDisabled = value || model.busy }
            .onChange(of: model.busy) { _, value in UIApplication.shared.isIdleTimerDisabled = value || model.playing }
            .onReceive(timer) { _ in model.thermal = ProcessInfo.processInfo.thermalState }
            .onReceive(NotificationCenter.default.publisher(for: AVAudioSession.interruptionNotification)) { _ in model.pause() }
        }.tint(Color(red: 0.8, green: 0.65, blue: 0.15))
    }
    @ViewBuilder private var preview: some View {
        ZStack {
            Color.black
            if let image = model.simulated {
                Image(uiImage: image).resizable()
                if let original = model.original {
                    GeometryReader { geometry in
                        Image(uiImage: original).resizable()
                            .mask(alignment: .leading) { Rectangle().frame(width: geometry.size.width*model.compare) }
                    }
                }
                VStack { HStack { Text(model.compare > 0 ? "原图／模拟对照" : "模拟结果"); Spacer(); Text(model.locked ? "已锁定" : "捕获中") }; Spacer() }
                    .font(.caption).foregroundStyle(.white).padding(8)
            } else { ContentUnavailableView("电视模拟", systemImage: "tv", description: Text("导入视频开始预览")).foregroundStyle(.white) }
        }.aspectRatio(4/3, contentMode: .fit).clipShape(RoundedRectangle(cornerRadius: 12))
        Slider(value: $model.compare, in: 0...1).accessibilityLabel("原图对照比例")
    }
    private func parameter(_ title: String, value: Binding<Float>, range: ClosedRange<Float>) -> some View {
        VStack { HStack { Text(title); Spacer(); Text(String(format: "%.1f", value.wrappedValue)).monospacedDigit() }; Slider(value: value, in: range) }.font(.caption)
    }
}

@main struct AnaLineApp: App {
    var body: some Scene { WindowGroup { MobileContentView() } }
}
