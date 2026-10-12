import AVFoundation
import Photos
import UIKit

/// The impairments the live mode offers. Built here so the camera can switch them
/// between frames, mirroring the idea of the imported clip's presets.
enum LivePreset: String, CaseIterable, Identifiable {
    case clean = "干净"
    case snow = "雪花"
    case ghost = "重影"
    case adjacent = "邻频"
    case weak = "弱信号"
    case rain = "雨衰"

    var id: String { rawValue }

    func settings(standard: TVStandard, performance: TVChainProfile) -> TerrestrialSettings {
        var next = TerrestrialSettings(system: TerrestrialSystem(video: standard))
        next.performance = performance
        switch self {
        case .clean:
            next.carrierToNoiseDB = 100
        case .snow:
            next.carrierToNoiseDB = 16
        case .ghost:
            next.carrierToNoiseDB = 40
            next.echoGain = 0.35
            next.echoDelayMicroseconds = 8
        case .adjacent:
            next.carrierToNoiseDB = 45
            next.frontEnd.enabled = true
            next.frontEnd.inputSaturationDB = 6
            next.frontEnd.inputHardness = 1
            next.frontEnd.inputAMPMDegrees = 40
            next.frontEnd.ifSaturationDB = 48
        case .weak:
            next.carrierToNoiseDB = 24
        case .rain:
            next.carrierToNoiseDB = 30
            next.propagation.enabled = true
            next.propagation.weather.enabled = true
            next.propagation.weather.rainMMHour = 30
        }
        return next
    }
}

/// Live camera → transmitter → receiver, optionally recorded to a file.
///
/// Real time is the priority and frames may drop. That is deliberate at three
/// points: the capture output is told to discard late frames, the pixels pass
/// through a single-slot mailbox where the newest frame always wins, and the
/// chain runs on its own queue so one slow frame can never accumulate a backlog.
/// Every drop is counted and reported rather than hidden.
final class MobileCamera: NSObject, ObservableObject {
    @Published private(set) var simulated: UIImage?
    @Published private(set) var source: UIImage?
    @Published private(set) var fps = 0.0
    @Published private(set) var processingMS = 0.0
    @Published private(set) var dropped = 0
    @Published private(set) var recording = false
    @Published private(set) var output: URL?
    @Published private(set) var message = ""

    private let session = AVCaptureSession()
    private let video = AVCaptureVideoDataOutput()
    private let mailbox = FrameMailbox()
    private let videoQueue = DispatchQueue(label: "AnaLine.Camera.Capture", qos: .userInteractive)
    private let chainQueue = DispatchQueue(label: "AnaLine.Camera.Chain", qos: .userInteractive)

    private var configured = false
    private var running = false
    private var pipeline: TVFramePipeline?
    private var standard = TVStandard.ntsc
    private var settings = TerrestrialSettings(system: .ntscM)
    private var index: Int64 = 0
    private var windowStart = ContinuousClock.now
    private var windowFrames = 0
    private var writer: AVAssetWriter?
    private var writerInput: AVAssetWriterInput?
    private var bufferPool: CVPixelBufferPool?
    private var pixelAdaptor: AVAssetWriterInputPixelBufferAdaptor?
    private var audioInput: AVAssetWriterInput?
    private let microphone = AVCaptureAudioDataOutput()
    private let sound = AudioMailbox()
    private var started = ContinuousClock.now
    private var recordStart = ContinuousClock.now
    /// Frame number the recording began at, so the file's timeline starts at zero
    /// while the audio ring keeps working in stream time.
    private var recordBaseIndex: Int64 = 0
    /// Control changes are parked here and picked up by the chain loop. The loop
    /// owns `chainQueue` for its entire life, so anything queued on that serial
    /// queue behind it would never run — the reason a preset tap did nothing.
    private let stateLock = NSLock()
    private var pendingSettings: TerrestrialSettings?
    private var pendingStandard: TVStandard?
    @Published private(set) var audioGaps = 0
    @Published private(set) var savedToPhotos = false
    @Published private(set) var preset: LivePreset = .clean

    /// The standard the live chain is running at. Changing it rebuilds the chain.
    var currentStandard: TVStandard { standard }

    /// The live mode's impairment control is the preset, so switching either the
    /// standard or the preset rebuilds the settings from it.
    func apply(_ preset: LivePreset) {
        // Publish the choice at once so the picker shows it, and hand the settings
        // to the chain for the next frame. Never queue on chainQueue: the loop
        // never leaves it.
        let next = preset.settings(standard: standard, performance: settings.performance)
        stateLock.lock()
        pendingSettings = next
        self.preset = preset
        stateLock.unlock()
        message = "\(standard.rawValue) · \(preset.rawValue)"
    }

    func setStandard(_ standard: TVStandard, settings: TerrestrialSettings) {
        let next = preset.settings(standard: standard, performance: settings.performance)
        stateLock.lock()
        pendingStandard = standard
        pendingSettings = next
        stateLock.unlock()
    }

    /// Runs on the chain loop only: takes whatever a control changed.
    private func applyPendingChanges() {
        stateLock.lock()
        let requested = pendingStandard
        let wanted = pendingSettings
        pendingStandard = nil; pendingSettings = nil
        stateLock.unlock()
        guard requested != nil || wanted != nil else { return }
        if let requested {
            standard = requested
            pipeline = TVFramePipeline(system: TerrestrialSystem(video: requested),
                                       seed: wanted?.seed ?? settings.seed)
        }
        if let wanted { settings = wanted }
        publish { self.message = "\(self.standard.rawValue) · \(self.preset.rawValue)" }
    }

    // MARK: - Session

    /// Whether the microphone may be used. Recorded sound goes through the sound
    /// carrier, so without a microphone the picture simply runs alone.
    private var microphoneDeviceAvailable: Bool {
        AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
    }

    func start(standard: TVStandard, settings: TerrestrialSettings) async {
        self.standard = standard
        self.settings = preset.settings(standard: standard, performance: settings.performance)
        let granted = await AVCaptureDevice.requestAccess(for: .video)
        _ = await AVCaptureDevice.requestAccess(for: .audio)
        guard granted else {
            publish { self.message = "没有摄像头权限。请在系统设置里允许 AnaLine 使用摄像头。" }
            return
        }
        if !configured {
            guard let device = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back)
                    ?? AVCaptureDevice.default(for: .video),
                  let input = try? AVCaptureDeviceInput(device: device) else {
                publish { self.message = "找不到可用的摄像头。" }
                return
            }
            session.beginConfiguration()
            // 4:3 at the smallest useful size: the analogue frame is 4:3 and real
            // time matters more than resolution here.
            session.sessionPreset = session.canSetSessionPreset(.vga640x480) ? .vga640x480 : .high
            if session.canAddInput(input) { session.addInput(input) }
            video.alwaysDiscardsLateVideoFrames = true
            video.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
            video.setSampleBufferDelegate(mailbox, queue: videoQueue)
            if session.canAddOutput(video) { session.addOutput(video) }
            if microphoneDeviceAvailable,
               let device = AVCaptureDevice.default(for: .audio),
               let input = try? AVCaptureDeviceInput(device: device), session.canAddInput(input) {
                session.addInput(input)
                // iOS hands capture audio over in the hardware's own format — unlike
                // macOS there is no audioSettings to ask with — so the delegate
                // converts whatever arrives to the clock the sound chain uses.
                let audioSession = AVAudioSession.sharedInstance()
                try? audioSession.setCategory(.playAndRecord, mode: .default,
                                              options: [.defaultToSpeaker, .allowBluetooth])
                try? audioSession.setPreferredSampleRate(Double(TVSoundClock.pcmRate))
                try? audioSession.setActive(true)
                microphone.setSampleBufferDelegate(sound, queue: videoQueue)
                if session.canAddOutput(microphone) { session.addOutput(microphone) }
            }
            if let connection = video.connection(with: .video) {
                if connection.isVideoOrientationSupported { connection.videoOrientation = .landscapeRight }
                if connection.isVideoMirroringSupported { connection.isVideoMirrored = false }
            }
            session.commitConfiguration()
            configured = true
        }
        pipeline = TVFramePipeline(system: TerrestrialSystem(video: standard), seed: settings.seed)
        running = true
        index = 0
        started = .now; windowStart = .now; windowFrames = 0
        sound.reset()
        startSession()
        startChain()
        publish { self.message = "\(standard.rawValue) · 实时" }
    }

    func stop() {
        running = false
        endRecording()
        session.stopRunning()
        // Not sync: this runs on the main thread when the mode closes, and the loop
        // owns the queue until it notices `running`. The loop returns first, so an
        // async block is enough and the interface never waits.
        chainQueue.async { [self] in pipeline = nil }
        publish { self.simulated = nil; self.source = nil; self.fps = 0; self.processingMS = 0 }
    }

    private func startSession() {
        let session = self.session
        DispatchQueue.global(qos: .userInitiated).async { if !session.isRunning { session.startRunning() } }
    }

    /// The consumer. It always takes the newest frame and never queues: if the
    /// chain is slower than the camera, the mailbox is what drops frames.
    private func startChain() {
        chainQueue.async { [self] in
            while running {
                applyPendingChanges()
                guard let (buffer, drops) = mailbox.take() else {
                    Thread.sleep(forTimeInterval: 0.002)
                    continue
                }
                let started = ContinuousClock.now
                autoreleasepool {
                    do { try process(buffer) } catch { publish { self.message = error.localizedDescription } }
                }
                let elapsed = MobileCamera.seconds(started.duration(to: .now))
                windowFrames += 1
                let window = MobileCamera.seconds(windowStart.duration(to: .now))
                let frames = windowFrames, gaps = sound.gaps
                if window >= 0.5 {
                    windowStart = .now; windowFrames = 0
                    publish { self.fps = Double(frames)/window; self.processingMS = elapsed*1000
                              self.dropped = drops; self.audioGaps = gaps }
                } else {
                    publish { self.processingMS = elapsed*1000; self.dropped = drops; self.audioGaps = gaps }
                }
            }
        }
    }

    private func process(_ buffer: CVPixelBuffer) throws {
        guard let pipeline else { return }
        // The frame index follows the clock rather than a counter, so a dropped
        // frame leaves the sound where it belongs instead of pulling it forward.
        let elapsed = MobileCamera.seconds(started.duration(to: .now))
        let index = Int64(elapsed*standard.frameRate)
        // Sound for this frame's own sample window, taken at its absolute offset.
        // Taking whatever sits at the front of the buffer instead would let the
        // audio drift further behind the picture with every dropped frame.
        let audio = sound.take(TVSoundClock.count(frame: index, standard: standard),
                               at: Int(TVSoundClock.offset(frame: index, standard: standard)))
        let frame = try Self.frame(buffer, standard: standard)
        let settings = self.settings
        self.index = index
        try pipeline.submit(TVFrameRequest(frameIndex: index, settings: settings) { index in
            (try TVEngine.encode(frame, frameIndex: index, execution: settings.execution,
                                 damage: settings.transmitter.encoder), audio)
        })
        let result = try pipeline.receive()
        let simulated = try Self.image(result.frame)
        let source = try Self.image(frame)
        // Presentation times are relative to the moment recording began, not to the
        // start of the live stream, or a recording started later would open with a
        // long empty stretch.
        // Both tracks are written on the broadcast frame timeline, so a dropped
        // frame leaves the same gap in each and the file's clock starts at zero.
        let base = recordBaseIndex
        append(result.frame, audio: result.audio, at: Double(index - base)/standard.frameRate)
        publish { self.simulated = simulated; self.source = source }
    }

    // MARK: - Recording

    func beginRecording() {
        guard !recording, let pipeline = writerURL() else { return }
        do {
            let writer = try AVAssetWriter(outputURL: pipeline, fileType: .mov)
            let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
                AVVideoCodecKey: AVVideoCodecType.h264,
                AVVideoWidthKey: standard.width, AVVideoHeightKey: standard.height])
            input.expectsMediaDataInRealTime = true
            let sound = AVAssetWriterInput(mediaType: .audio, outputSettings: [
                AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVSampleRateKey: Double(TVSoundClock.pcmRate),
                AVNumberOfChannelsKey: 1,
                AVEncoderBitRateKey: 96_000])
            sound.expectsMediaDataInRealTime = true
            let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input,
                sourcePixelBufferAttributes: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                                              kCVPixelBufferWidthKey as String: standard.width,
                                              kCVPixelBufferHeightKey as String: standard.height])
            guard writer.canAdd(input), writer.canAdd(sound) else { throw MobileMediaError.message("无法写入录制文件。") }
            writer.add(input); writer.add(sound)
            guard writer.startWriting() else { throw writer.error ?? MobileMediaError.message("录制启动失败。") }
            writer.startSession(atSourceTime: .zero)
            self.writer = writer; writerInput = input; audioInput = sound
            pixelAdaptor = adaptor; bufferPool = adaptor.pixelBufferPool
            recordStart = .now
            stateLock.lock(); recordBaseIndex = index; stateLock.unlock()
            recording = true; savedToPhotos = false
            publish { self.message = "录制中…（含电视伴音）"; self.output = nil }
        } catch {
            publish { self.message = error.localizedDescription }
        }
    }

    func endRecording() {
        guard recording, let writer, let input = writerInput else { return }
        recording = false
        input.markAsFinished()
        audioInput?.markAsFinished()
        let url = writer.outputURL
        writer.finishWriting { [self] in
            let failed = writer.status != .completed
            self.writer = nil; self.writerInput = nil; self.audioInput = nil
            self.bufferPool = nil; self.pixelAdaptor = nil
            publish { self.output = url
                      self.message = failed ? "录制未完成。" : "录好了 \(url.lastPathComponent)，正在存入相册…" }
            if !failed { saveToPhotos(url) }
        }
    }

    /// The recording belongs in the photo library, which is where a video is
    /// expected to end up. The file stays in the app's documents either way, so a
    /// refused permission costs nothing.
    private func saveToPhotos(_ url: URL) {
        PHPhotoLibrary.requestAuthorization(for: .addOnly) { [self] status in
            guard status == .authorized || status == .limited else {
                publish { self.message = "没有相册写入权限；文件已保存在应用文稿中。" }
                return
            }
            PHPhotoLibrary.shared().performChanges {
                PHAssetCreationRequest.forAsset().addResource(with: .video, fileURL: url, options: nil)
            } completionHandler: { [self] success, error in
                publish {
                    self.savedToPhotos = success
                    self.message = success ? "已保存到相册（含电视伴音）。"
                        : "存入相册失败：\(error?.localizedDescription ?? "未知错误")；文件在应用文稿中。"
                }
            }
        }
    }

    private func append(_ frame: TVFrame, audio: [Float]?, at seconds: Double) {
        guard recording, let input = writerInput, let writer, writer.status == .writing else { return }
        var buffer: CVPixelBuffer?
        if let pool = bufferPool, CVPixelBufferPoolCreatePixelBuffer(nil, pool, &buffer) != kCVReturnSuccess { buffer = nil }
        guard let target = buffer else { return }
        CVPixelBufferLockBaseAddress(target, [])
        if let base = CVPixelBufferGetBaseAddress(target) {
            let row = CVPixelBufferGetBytesPerRow(target)
            for y in 0..<frame.standard.height {
                let line = base.advanced(by: y*row).assumingMemoryBound(to: UInt8.self)
                for x in 0..<frame.standard.width {
                    let pixel = frame.rgb[y*frame.standard.width + x]
                    line[x*4] = UInt8((max(0, min(1, pixel.z))*255).rounded())
                    line[x*4+1] = UInt8((max(0, min(1, pixel.y))*255).rounded())
                    line[x*4+2] = UInt8((max(0, min(1, pixel.x))*255).rounded())
                    line[x*4+3] = 255
                }
            }
        }
        CVPixelBufferUnlockBaseAddress(target, [])
        // Presentation times follow the wall clock, so a dropped frame leaves a gap
        // and the file plays back at the speed it really happened.
        let time = CMTime(seconds: seconds, preferredTimescale: 60000)
        if input.isReadyForMoreMediaData { pixelAdaptor?.append(target, withPresentationTime: time) }
        if let audio, let sound = audioInput, sound.isReadyForMoreMediaData,
           let sample = Self.sampleBuffer(audio, at: time) {
            sound.append(sample)
        }
    }

    /// Wrap float PCM as a sample buffer so the writer can encode it.
    static func sampleBuffer(_ samples: [Float], at time: CMTime) -> CMSampleBuffer? {
        guard !samples.isEmpty else { return nil }
        var description: CMAudioFormatDescription?
        var stream = AudioStreamBasicDescription(mSampleRate: Double(TVSoundClock.pcmRate),
            mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked,
            mBytesPerPacket: 4, mFramesPerPacket: 1, mBytesPerFrame: 4, mChannelsPerFrame: 1,
            mBitsPerChannel: 32, mReserved: 0)
        guard CMAudioFormatDescriptionCreate(allocator: kCFAllocatorDefault, asbd: &stream, layoutSize: 0,
            layout: nil, magicCookieSize: 0, magicCookie: nil, extensions: nil,
            formatDescriptionOut: &description) == noErr, let description else { return nil }
        let length = samples.count*4
        var block: CMBlockBuffer?
        guard CMBlockBufferCreateWithMemoryBlock(allocator: kCFAllocatorDefault, memoryBlock: nil,
            blockLength: length, blockAllocator: kCFAllocatorDefault, customBlockSource: nil,
            offsetToData: 0, dataLength: length, flags: 0, blockBufferOut: &block) == noErr,
            let block else { return nil }
        let copied = samples.withUnsafeBytes { raw in
            CMBlockBufferReplaceDataBytes(with: raw.baseAddress!, blockBuffer: block,
                                          offsetIntoDestination: 0, dataLength: length)
        }
        guard copied == noErr else { return nil }
        var sample: CMSampleBuffer?
        var timing = CMSampleTimingInfo(duration: CMTime(value: 1, timescale: CMTimeScale(TVSoundClock.pcmRate)),
                                        presentationTimeStamp: time, decodeTimeStamp: .invalid)
        guard CMSampleBufferCreateReady(allocator: kCFAllocatorDefault, dataBuffer: block,
            formatDescription: description, sampleCount: samples.count, sampleTimingEntryCount: 1,
            sampleTimingArray: &timing, sampleSizeEntryCount: 0, sampleSizeArray: nil,
            sampleBufferOut: &sample) == noErr else { return nil }
        return sample
    }

    /// Microphone buffer: if the consumer falls behind the oldest samples go, the
    /// audio equivalent of dropping a frame, so sound never drifts behind picture.
    private final class AudioMailbox: NSObject, AVCaptureAudioDataOutputSampleBufferDelegate, @unchecked Sendable {
        private let lock = NSLock()
        private var samples: [Float] = []
        private var gapCount = 0
        private let limit = TVSoundClock.pcmRate/2
        private var phase = 0.0
        /// Absolute sample index of `samples[0]` since the stream started.
        private var consumed = 0

        var gaps: Int { lock.lock(); defer { lock.unlock() }; return gapCount }
        func reset() { lock.lock(); samples.removeAll(); gapCount = 0; phase = 0; lock.unlock() }

        /// iOS hands capture audio over in the hardware's own format — there is no
        /// audioSettings to ask with, unlike macOS — so it is read according to its
        /// description and mixed down here. Doing it by hand rather than with
        /// AVAudioConverter keeps allocation, and the buffer-list machinery that
        /// goes with it, out of the capture callback: real time is the priority.
        func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer,
                           from connection: AVCaptureConnection) {
            _ = ingest(sampleBuffer)
        }

        /// Read one delivered buffer according to its own description and append it.
        /// Separated from the delegate so the formats iOS actually delivers can be
        /// exercised without a camera.
        @discardableResult
        func ingest(_ sampleBuffer: CMSampleBuffer) -> Int {
            let frames = CMSampleBufferGetNumSamples(sampleBuffer)
            guard frames > 0,
                  let description = CMSampleBufferGetFormatDescription(sampleBuffer),
                  let stream = CMAudioFormatDescriptionGetStreamBasicDescription(description),
                  let block = CMSampleBufferGetDataBuffer(sampleBuffer) else { return 0 }
            let asbd = stream.pointee
            let channels = max(1, Int(asbd.mChannelsPerFrame))
            let width = Int(asbd.mBitsPerChannel)/8
            let stride = Int(asbd.mBytesPerFrame)
            let interleaved = asbd.mFormatFlags & kAudioFormatFlagIsNonInterleaved == 0
            let isFloat = asbd.mFormatFlags & kAudioFormatFlagIsFloat != 0
            guard stride > 0, width == 2 || width == 4 else { return 0 }
            var raw = [UInt8](repeating: 0, count: frames*stride)
            let copied = raw.withUnsafeMutableBytes { buffer in
                CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: buffer.count,
                                           destination: buffer.baseAddress!)
            }
            guard copied == noErr else { return 0 }
            var mono = [Float](repeating: 0, count: frames)
            raw.withUnsafeBytes { bytes in
                for frame in 0..<frames {
                    var sum: Float = 0
                    for channel in 0..<channels {
                        let offset = interleaved ? frame*stride + channel*width
                                                 : channel*frames*width + frame*width
                        guard offset + width <= bytes.count else { continue }
                        if isFloat, width == 4 {
                            var value: Float = 0
                            withUnsafeMutableBytes(of: &value) { $0.copyBytes(from: bytes[offset..<offset+4]) }
                            sum += value
                        } else {
                            let low = UInt16(bytes[offset]), high = UInt16(bytes[offset+1])
                            sum += Float(Int16(bitPattern: low | (high << 8)))/32768
                        }
                    }
                    mono[frame] = sum/Float(channels)
                }
            }
            let chunk = resample(mono, from: asbd.mSampleRate)
            lock.lock()
            samples.append(contentsOf: chunk)
            if samples.count > limit {
                let dropped = samples.count - limit
                samples.removeFirst(dropped); consumed += dropped
            }
            lock.unlock()
            return chunk.count
        }

        /// Linear resampling to the clock the sound chain runs at, carrying the
        /// fractional position across buffers so no click appears at the joins.
        private func resample(_ input: [Float], from rate: Double) -> [Float] {
            let target = Double(TVSoundClock.pcmRate)
            guard rate > 0, abs(rate-target) > 1 else { return input }
            let step = rate/target
            var output: [Float] = []
            output.reserveCapacity(Int(Double(input.count)/step) + 2)
            var position = phase
            while position < Double(input.count) {
                let index = Int(position)
                let fraction = Float(position - Double(index))
                let a = input[index]
                let b = index+1 < input.count ? input[index+1] : a
                output.append(a + (b-a)*fraction)
                position += step
            }
            phase = position - Double(input.count)
            return output
        }

        /// Exactly `count` samples beginning at the absolute sample `offset` the
        /// frame's sound clock calls for. Anything older is discarded, so a dropped
        /// frame skips its own audio instead of leaving sound behind the picture;
        /// anything missing is silence.
        func take(_ count: Int, at offset: Int) -> [Float] {
            lock.lock(); defer { lock.unlock() }
            if offset > consumed {
                let skip = min(samples.count, offset - consumed)
                if skip > 0 { samples.removeFirst(skip); consumed += skip }
            }
            if samples.count >= count {
                let taken = Array(samples[0..<count])
                samples.removeFirst(count)
                consumed += count
                return taken
            }
            gapCount += 1
            var taken = samples
            samples.removeAll()
            consumed += taken.count
            taken.append(contentsOf: [Float](repeating: 0, count: count - taken.count))
            return taken
        }
    }

    private func writerURL() -> URL? {
        let directory = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        return directory.appendingPathComponent("AnaLine-live-\(Int(Date().timeIntervalSince1970)).mov")
    }

    // MARK: - Conversion

    /// Raw BGRA into the standard's raster, sampling with nearest neighbours so it
    /// does not matter whether the capture output honoured the requested size.
    static func frame(_ buffer: CVPixelBuffer, standard: TVStandard) throws -> TVFrame {
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(buffer) else {
            throw MobileMediaError.message("无法读取摄像头画面。")
        }
        let row = CVPixelBufferGetBytesPerRow(buffer)
        let width = CVPixelBufferGetWidth(buffer), height = CVPixelBufferGetHeight(buffer)
        var rgb = [SIMD3<Float>](repeating: .zero, count: standard.width*standard.height)
        for y in 0..<standard.height {
            let sourceY = min(height-1, y*height/standard.height)
            let line = base.advanced(by: sourceY*row).assumingMemoryBound(to: UInt8.self)
            for x in 0..<standard.width {
                let sourceX = min(width-1, x*width/standard.width)
                let p = sourceX*4
                rgb[y*standard.width + x] = SIMD3(Float(line[p+2])/255, Float(line[p+1])/255, Float(line[p])/255)
            }
        }
        return try TVFrame(standard: standard, rgb: rgb)
    }

    static func image(_ frame: TVFrame) throws -> UIImage {
        try MobileMedia.image(frame)
    }

    static func seconds(_ duration: Duration) -> Double {
        let value = duration.components
        return Double(value.seconds) + Double(value.attoseconds)/1e18
    }

    private func publish(_ body: @escaping () -> Void) {
        DispatchQueue.main.async(execute: body)
    }

    // MARK: - Recording self-check

    /// Records a known pattern and reads the file back, so the whole recording path
    /// can be checked without a camera: whether frames reach the writer at all, and
    /// whether what comes out is the picture that went in.
    static func recordingReport() async -> [String] {
        var lines: [String] = []
        let camera = MobileCamera()
        camera.standard = .ntsc
        camera.beginRecording()
        lines.append("开始录制：" + (camera.recording ? "已启动" : "未启动"))
        let width = TVStandard.ntsc.width, height = TVStandard.ntsc.height
        var wrote = 0
        for index in 0..<30 {
            let level: Float = index % 2 == 0 ? 0.9 : 0.2
            guard let frame = try? TVFrame(standard: .ntsc,
                                           rgb: [SIMD3<Float>](repeating: SIMD3(level, level, level),
                                                               count: width*height)) else { continue }
            camera.append(frame, audio: [Float](repeating: 0.1, count: 1601), at: Double(index)/30)
            wrote += 1
        }
        lines.append("写入 \(wrote) 帧；缓冲池 \(camera.bufferPool == nil ? "为空" : "可用")")
        camera.endRecording()
        try? await Task.sleep(for: .seconds(3))
        guard let url = camera.output else {
            lines.append("没有产出文件")
            for line in lines { print("RECORDCHECK " + line) }
            return lines
        }
        let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int) ?? 0
        lines.append("文件 \(url.lastPathComponent)，\(size ?? 0) 字节")
        // The timestamp bug showed up as a long empty head: the file must be as long
        // as the frames that were written, not as long as the live session.
        if let seconds = try? await AVURLAsset(url: url).load(.duration).seconds {
            lines.append(String(format: "时长 %.2f s（写入 30 帧应为约 1.0 s）→ %@",
                                seconds, abs(seconds-1.0) < 0.3 ? "通过" : "开头有空档"))
        }
        do {
            let asset = AVURLAsset(url: url)
            let track = try await asset.loadTracks(withMediaType: .video).first
            let reader = try AVAssetReader(asset: asset)
            var decoded = 0
            var levels: [Double] = []
            if let track {
                let output = AVAssetReaderTrackOutput(track: track, outputSettings: [
                    kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA])
                reader.add(output)
                reader.startReading()
                while let sample = output.copyNextSampleBuffer() {
                    defer { CMSampleBufferInvalidate(sample) }
                    guard let buffer = CMSampleBufferGetImageBuffer(sample) else { continue }
                    decoded += 1
                    if decoded <= 2 || decoded == 30 {
                        CVPixelBufferLockBaseAddress(buffer, .readOnly)
                        if let base = CVPixelBufferGetBaseAddress(buffer) {
                            let bytes = base.assumingMemoryBound(to: UInt8.self)
                            levels.append(Double(bytes[2])/255)   // one pixel's red channel
                        }
                        CVPixelBufferUnlockBaseAddress(buffer, .readOnly)
                    }
                }
            }
            lines.append("解码出 \(decoded) 帧，样本亮度 \(levels.map { String(format: "%.2f", $0) }.joined(separator: ", "))")
            lines.append(decoded >= 25 && levels.contains { $0 > 0.5 } ? "结论：录制有画面 → 通过" : "结论：文件没有可用画面 → 不符")
        } catch {
            lines.append("回读失败：\(error.localizedDescription)")
        }
        try? FileManager.default.removeItem(at: url)
        for line in lines { print("RECORDCHECK " + line) }
        return lines
    }

    // MARK: - Control self-check

    /// A preset tap must show up at once *and* reach the chain, and neither may go
    /// through the queue the chain loop occupies for its whole life. This runs the
    /// whole path without a camera.
    static func presetReport() -> [String] {
        var lines: [String] = []
        let camera = MobileCamera()
        camera.apply(.snow)
        lines.append("选择立即反映：preset = \(camera.preset.rawValue) → " + (camera.preset == .snow ? "通过" : "不符"))
        let parked = camera.pendingSettings?.carrierToNoiseDB
        lines.append("已交给链路：载噪比 = \(parked.map { String(format: "%.0f", $0) } ?? "无") → "
                     + (parked == 16 ? "通过" : "不符"))
        camera.applyPendingChanges()
        lines.append("链路取用后生效：载噪比 = \(String(format: "%.0f", camera.settings.carrierToNoiseDB)) → "
                     + (abs(camera.settings.carrierToNoiseDB - 16) < 0.001 ? "通过" : "不符"))
        camera.setStandard(.pal, settings: camera.settings)
        camera.applyPendingChanges()
        lines.append("制式切换：standard = \(camera.standard.rawValue) → " + (camera.standard == .pal ? "通过" : "不符"))
        for line in lines { print("PRESETCHECK " + line) }
        return lines
    }

    // MARK: - Audio self-check

    /// Feeds the microphone path the formats iOS really delivers — 16-bit
    /// interleaved stereo at 44.1 kHz, 32-bit float non-interleaved stereo at
    /// 48 kHz, float mono at 48 kHz — and reports what came out, so the parsing,
    /// mixing and resampling can be checked without a camera.
    static func audioReport() -> [String] {
        func buffer(format: (id: AudioFormatID, flags: AudioFormatFlags, bits: Int, channels: Int, rate: Double),
                    frames: Int, fill: (Int, Int) -> Float) -> CMSampleBuffer? {
            var asbd = AudioStreamBasicDescription(mSampleRate: format.rate, mFormatID: format.id,
                mFormatFlags: format.flags, mBytesPerPacket: 0, mFramesPerPacket: 1,
                mBytesPerFrame: 0, mChannelsPerFrame: UInt32(format.channels),
                mBitsPerChannel: UInt32(format.bits), mReserved: 0)
            let bytes = format.bits/8
            asbd.mBytesPerFrame = UInt32(bytes*format.channels)
            asbd.mBytesPerPacket = asbd.mBytesPerFrame
            var description: CMAudioFormatDescription?
            guard CMAudioFormatDescriptionCreate(allocator: kCFAllocatorDefault, asbd: &asbd, layoutSize: 0,
                layout: nil, magicCookieSize: 0, magicCookie: nil, extensions: nil,
                formatDescriptionOut: &description) == noErr, let description else { return nil }
            var data = [UInt8](repeating: 0, count: frames*bytes*format.channels)
            for frame in 0..<frames {
                for channel in 0..<format.channels {
                    let value = fill(frame, channel)
                    let offset = (frame*format.channels + channel)*bytes
                    if format.flags & kAudioFormatFlagIsFloat != 0 {
                        var bits32 = value.bitPattern
                        withUnsafeBytes(of: &bits32) { data.replaceSubrange(offset..<offset+4, with: $0) }
                    } else {
                        let scaled = Int16(max(-1, min(1, value))*32767)
                        data[offset] = UInt8(truncatingIfNeeded: scaled)
                        data[offset+1] = UInt8(truncatingIfNeeded: scaled >> 8)
                    }
                }
            }
            var block: CMBlockBuffer?
            guard CMBlockBufferCreateWithMemoryBlock(allocator: kCFAllocatorDefault, memoryBlock: nil,
                blockLength: data.count, blockAllocator: kCFAllocatorDefault, customBlockSource: nil,
                offsetToData: 0, dataLength: data.count, flags: 0, blockBufferOut: &block) == noErr,
                let block else { return nil }
            _ = data.withUnsafeBytes { raw in
                CMBlockBufferReplaceDataBytes(with: raw.baseAddress!, blockBuffer: block,
                                              offsetIntoDestination: 0, dataLength: data.count)
            }
            var sample: CMSampleBuffer?
            var timing = CMSampleTimingInfo(duration: CMTime(value: 1, timescale: CMTimeScale(format.rate)),
                                            presentationTimeStamp: .zero, decodeTimeStamp: .invalid)
            guard CMSampleBufferCreateReady(allocator: kCFAllocatorDefault, dataBuffer: block,
                formatDescription: description, sampleCount: frames, sampleTimingEntryCount: 1,
                sampleTimingArray: &timing, sampleSizeEntryCount: 0, sampleSizeArray: nil,
                sampleBufferOut: &sample) == noErr else { return nil }
            return sample
        }
        var lines: [String] = []
        // A constant 0.5 in every channel must come back as 0.5 mono, and a 44.1 kHz
        // buffer must come back longer by 48000/44100.
        let cases: [(String, (AudioFormatID, AudioFormatFlags, Int, Int, Double), Int, Int)] = [
            // 441 frames at 44.1 kHz become 480 at 48 kHz; the rest are 1:1.
            ("int16 交织 立体声 44.1k", (kAudioFormatLinearPCM, kAudioFormatFlagIsSignedInteger | kAudioFormatFlagIsPacked, 16, 2, 44100), 441, 480),
            ("float 非交织 立体声 48k", (kAudioFormatLinearPCM, kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked | kAudioFormatFlagIsNonInterleaved, 32, 2, 48000), 480, 480),
            ("float 交织 单声道 48k", (kAudioFormatLinearPCM, kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked, 32, 1, 48000), 512, 512)]
        for (name, format, frames, expected) in cases {
            let mailbox = AudioMailbox()
            guard let sample = buffer(format: format, frames: frames, fill: { _, _ in 0.5 }) else {
                lines.append("\(name)：无法构造样本"); continue
            }
            let produced = mailbox.ingest(sample)
            let taken = mailbox.take(min(expected, produced), at: 0)
            let mean = taken.isEmpty ? 0 : taken.reduce(0, +)/Float(taken.count)
            let ok = abs(mean-0.5) < 0.05 && abs(produced-expected) <= 2
            lines.append(String(format: "%@：产出 %d 期望 %d，均值 %.3f → %@",
                                name, produced, expected, mean, ok ? "通过" : "不符"))
            print("AUDIOCHECK " + lines[lines.count-1])
        }
        // The window must be taken at the frame's own offset: feed a ramp, ask for
        // the second frame's window, and the values must be the ramp's, not the
        // buffer's front.
        let ramped = AudioMailbox()
        var ramp: [Float] = []
        for index in 0..<6000 { ramp.append(Float(index % 1000)/1000) }
        for start in stride(from: 0, to: ramp.count, by: 1000) {
            if let sample = buffer(format: cases[2].1, frames: 1000, fill: { frame, _ in ramp[start + frame] }) {
                _ = ramped.ingest(sample)
            }
        }
        let window = ramped.take(1920, at: 1920)
        let expected = ramp[1920]
        let aligned = abs(window[0]-expected) < 0.0001
        lines.append(String(format: "按帧偏移取声：首值 %.3f 期望 %.3f → %@", window[0], expected,
                            aligned ? "通过" : "不符"))
        print("AUDIOCHECK " + lines[lines.count-1])

        // A starving mailbox must pad with silence rather than stall.
        let silent = AudioMailbox()
        let padded = silent.take(100, at: 0)
        lines.append("缺数据补零：\(padded.count) 个样本，全部为 0 → " + (padded.count == 100 && padded.allSatisfy { $0 == 0 } ? "通过" : "不符"))
        print("AUDIOCHECK " + lines[lines.count-1])
        return lines
    }
}

/// Single-slot hand-off: the newest frame always wins, and anything it replaces is
/// a dropped frame.
private final class FrameMailbox: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private var slot: CVPixelBuffer?
    private var drops = 0

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer,
                       from connection: AVCaptureConnection) {
        guard let buffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        lock.lock()
        if slot != nil { drops += 1 }
        slot = buffer
        lock.unlock()
    }

    func take() -> (CVPixelBuffer, Int)? {
        lock.lock(); defer { lock.unlock() }
        guard let buffer = slot else { return nil }
        slot = nil
        return (buffer, drops)
    }
}
