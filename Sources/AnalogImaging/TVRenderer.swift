import Foundation
import CoreGraphics
import AnalogCore

public struct TVPreparationProgress: Sendable {
    public enum Stage: Sendable { case inspecting, video, audio, caching, cached }
    public let stage: Stage
    public let fraction: Double?
}

/// Normalizes arbitrary movie inputs with the user's PATH ffmpeg, then runs
/// selected frames through CVBS, VSB RF, a terrestrial channel and receiver.
public actor TVRenderer {
    public struct Preview: @unchecked Sendable {
        public let original: CGImage
        public let image: CGImage
        public let duration: Double
        public let frameIndex: Int64
        public let encodeSeconds: Double
        public let decodeSeconds: Double
        public let sourceSeconds: Double
        public let outputSeconds: Double
        public let prerollSeconds: Double
        public let reception: TerrestrialReception
        public var totalSeconds: Double { sourceSeconds + encodeSeconds + decodeSeconds + outputSeconds + prerollSeconds }
    }

    private var ffmpeg: URL?
    private var ffprobe: URL?
    private struct PreparedVideo: Sendable {
        let url: URL
        let duration: Double
    }
    private var preparedVideos = [TVStandard: PreparedVideo]()
    private var cacheLease: TVMediaCache.Lease?
    private var normalizedURL: URL?
    private var audioURL: URL?
    private var audioPCM: Data?
    private var reader: TVFFmpegProcess?
    private var nextFrameIndex: Int64 = 0
    private var standard: TVStandard = .pal
    private var duration: Double = 0
    // A synchronous frame job stays exclusive to this actor, while Dispatch scopes
    // interactive QoS across the job and its concurrent filter/sample workers.
    // No process-wide priority or system power setting is changed.
    private let frameQueue = DispatchQueue(label: "AnaLine.TV.Frame",qos: .userInteractive)
    /// Streaming engine. Its transmit stage runs on its own thread at the same QoS
    /// as this queue, so the frame that follows the one being received is built
    /// and transmitted during the gap between render calls instead of on the
    /// call's critical path.
    private var pipeline: TVFramePipeline?
    /// The next playback frame, already handed to the pipeline and not yet
    /// received: its source pixels are cached too, so the next call neither reads
    /// the decoder pipe again nor converts them twice.
    private var prepared: PreparedFrame?
    private var simulationFrame: Int64?
    private var simulationSeed: UInt64 = 42
    private var simulationProfile = TVChainProfile.full

    /// A frame whose construction has been handed to the pipeline.
    private struct PreparedFrame {
        let frameIndex: Int64
        let frame: TVFrame
        let original: CGImage
        let audio: [Float]?
        /// Encode time measured on the transmit thread, read once the frame has
        /// been received (the hand-off semaphore orders the two).
        let timing: EncodeTiming
    }
    private final class EncodeTiming: @unchecked Sendable {
        private let lock = NSLock()
        private var value: Duration = .zero
        var duration: Duration {
            get { lock.lock(); defer { lock.unlock() }; return value }
            set { lock.lock(); value = newValue; lock.unlock() }
        }
    }
    private let executableSearchPath: String

    public init() {
        executableSearchPath = ProcessInfo.processInfo.environment["PATH", default: "/usr/bin:/bin:/usr/sbin:/sbin"]
    }

    init(executableSearchPath: String) { self.executableSearchPath = executableSearchPath }

    deinit {
        // These UUID paths are owned conversion outputs, never the user's source.
        // A renderer released after playback must not leave hundreds of MB behind.
        if cacheLease == nil {
            for video in preparedVideos.values { try? FileManager.default.removeItem(at: video.url) }
            if let audioURL { try? FileManager.default.removeItem(at: audioURL) }
        }
    }

    public func loadVideo(_ url: URL, standard: TVStandard = .pal,
                          cache: TVMediaCacheConfiguration? = nil,
                          progress: (@Sendable (TVPreparationProgress) -> Void)? = nil) throws -> Double {
        guard let ffmpeg = TVExecutableResolver.find("ffmpeg", path: executableSearchPath) else { throw TVVideoError.ffmpegNotFound }
        progress?(TVPreparationProgress(stage: .inspecting,fraction: nil))
        let identity = try url.resourceValues(forKeys: [.fileSizeKey,.contentModificationDateKey])
        cache?.trim()
        let key = (cache?.maximumBytes ?? 0) == 0 ? nil : try TVMediaCache.key(for: url)
        if let cache,let key,let lease = TVMediaCache.acquire(key: key,configuration: cache) {
            let pcm = try lease.audio.map { try Data(contentsOf: $0,options: .mappedIfSafe) }
            try Task.checkCancellation()
            clearPreparedVideo()
            self.ffmpeg = ffmpeg; cacheLease = lease
            preparedVideos = Dictionary(uniqueKeysWithValues: TVStandard.allCases.map {
                ($0,PreparedVideo(url: lease.video($0),duration: lease.manifest.durations[$0.rawValue]!))
            })
            audioURL = lease.audio; audioPCM = pcm
            progress?(TVPreparationProgress(stage: .cached,fraction: 1))
            return try selectStandard(standard)
        }
        guard let ffprobe = TVExecutableResolver.find("ffprobe", path: executableSearchPath) else { throw TVVideoError.ffprobeNotFound }
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("AnaLine-TV-\(UUID().uuidString)")
        let outputs = Dictionary(uniqueKeysWithValues: TVStandard.allCases.map {
            ($0,base.appendingPathExtension($0.rawValue).appendingPathExtension("mp4"))
        })
        let audioOutput = base.appendingPathExtension("f32le")
        // Decode the source once, then scale/rate-convert both branches directly
        // from it. NTSC is never made from a PAL conversion (or vice versa).
        let branches = TVStandard.allCases.map { s in
            "[\(s.rawValue)in]scale=\(s.squarePixelWidth):\(s.height):force_original_aspect_ratio=decrease:flags=lanczos,pad=\(s.squarePixelWidth):\(s.height):(ow-iw)/2:(oh-ih)/2:color=black,scale=\(s.width):\(s.height):flags=lanczos,setsar=\(s.pixelAspect),fps=\(s.ffmpegFrameRate)[\(s.rawValue)out]"
        }
        let filter = "[0:v:0]scale=iw*sar:ih:flags=lanczos,setsar=1,split=2[palin][ntscin];"+branches.joined(separator: ";")
        do {
            progress?(TVPreparationProgress(stage: .video,fraction: nil))
            let sourceProbe = try Self.run(ffprobe, ["-v", "error", "-show_entries", "format=duration",
                "-of", "default=noprint_wrappers=1:nokey=1", url.path])
            let sourceDuration = Double(String(decoding: sourceProbe,as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines))
            let audioProbe = try Self.run(ffprobe, ["-v", "error", "-select_streams", "a:0",
                "-show_entries", "stream=index", "-of", "csv=p=0", url.path])
            let hasAudio = !audioProbe.isEmpty
            var arguments = ["-hide_banner","-loglevel","error","-y","-i",url.path,
                             "-filter_complex_threads","2","-filter_complex",filter]
            // Bound forward decoding after a seek to one second instead of
            // x264's default ten-second GOP. This cache is for editing/playback.
            for s in TVStandard.allCases {
                arguments += ["-map","[\(s.rawValue)out]","-an","-c:v","libx264","-preset","ultrafast",
                              "-threads","2","-g",String(Int(s.frameRate.rounded())),"-crf","0","-pix_fmt","yuv444p","-movflags","+faststart",outputs[s]!.path]
            }
            try Self.runPreparing(ffmpeg,arguments,duration: sourceDuration,stage: .video,
                                  start: 0,weight: hasAudio ? 0.88 : 0.98,progress: progress)
            var prepared = [TVStandard: PreparedVideo]()
            for s in TVStandard.allCases {
                let output = outputs[s]!
                let probe = try Self.run(ffprobe,["-v","error","-show_entries","format=duration",
                    "-of","default=noprint_wrappers=1:nokey=1",output.path])
                guard let parsed = Double(String(decoding: probe,as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)),
                      parsed.isFinite, parsed > 0 else { throw TVVideoError.invalidVideo }
                prepared[s] = PreparedVideo(url: output,duration: parsed)
            }
            // Pad PCM through the longer rate-normalized endpoint. Both frame
            // clocks index the same 48 kHz recording, without resampling on switch.
            let audioDuration = prepared.values.map(\.duration).max()!
            if hasAudio {
                try Self.runPreparing(ffmpeg, ["-hide_banner", "-loglevel", "error", "-y", "-i", url.path,
                    "-map", "0:a:0", "-vn", "-c:a", "pcm_f32le", "-ar", "48000", "-ac", "1",
                    "-af", "aresample=async=1:first_pts=0,apad", "-t", String(audioDuration),
                    "-f", "f32le", audioOutput.path],duration: audioDuration,stage: .audio,
                    start: 0.88,weight: 0.1,progress: progress)
            }
            let pcm = hasAudio ? try Data(contentsOf: audioOutput,options: .mappedIfSafe) : nil
            try Task.checkCancellation()
            progress?(TVPreparationProgress(stage: .caching,fraction: 0.98))
            let unchanged = try url.resourceValues(forKeys: [.fileSizeKey,.contentModificationDateKey])
            let lease: TVMediaCache.Lease?
            if let cache,let key,unchanged.fileSize == identity.fileSize,
               unchanged.contentModificationDate == identity.contentModificationDate {
                lease = TVMediaCache.store(key: key,videos: outputs,durations: prepared.mapValues(\.duration),
                    audio: hasAudio ? audioOutput : nil,configuration: cache)
            } else { lease = nil }
            clearPreparedVideo()
            cacheLease = lease
            if let lease {
                for s in TVStandard.allCases {
                    prepared[s] = PreparedVideo(url: lease.video(s),duration: lease.manifest.durations[s.rawValue]!)
                }
                for output in outputs.values { try? FileManager.default.removeItem(at: output) }
                try? FileManager.default.removeItem(at: audioOutput)
            }
            self.ffmpeg = ffmpeg; self.ffprobe = ffprobe; preparedVideos = prepared
            audioURL = lease?.audio ?? (hasAudio ? audioOutput : nil)
            audioPCM = pcm
            let selectedDuration = try selectStandard(standard)
            progress?(TVPreparationProgress(stage: hasAudio ? .audio : .video,fraction: 1))
            return selectedDuration
        } catch {
            for output in outputs.values { try? FileManager.default.removeItem(at: output) }
            try? FileManager.default.removeItem(at: audioOutput)
            throw error
        }
    }

    public func unloadVideo() {
        clearPreparedVideo()
    }
    private func clearPreparedVideo() {
        endPlayback()
        if cacheLease == nil {
            for video in preparedVideos.values { try? FileManager.default.removeItem(at: video.url) }
            if let audioURL { try? FileManager.default.removeItem(at: audioURL) }
        }
        cacheLease = nil
        preparedVideos.removeAll()
        normalizedURL = nil; audioURL = nil; audioPCM = nil; duration = 0
    }

    /// Switches only existing import outputs. No source access or transcoding.
    @discardableResult
    public func selectStandard(_ standard: TVStandard) throws -> Double {
        guard let video = preparedVideos[standard] else { throw TVVideoError.noVideo }
        endPlayback()
        self.standard = standard; normalizedURL = video.url; duration = video.duration
        pipeline = nil; prepared = nil
        return duration
    }

    // Internal diagnostics used to verify cache reuse and lifetime cleanup.
    func normalizedVideoURL(standard: TVStandard) -> URL? { preparedVideos[standard]?.url }

    /// Scratch mono float32 little-endian PCM at 48 kHz, not a playable media container.
    public func normalizedAudioURL() -> URL? { audioURL }
    public func hasAudioTrack() -> Bool { audioPCM != nil }

    private func sourceAudio(frame: Int64) -> [Float]? {
        guard let audioPCM else { return nil }
        let start = Int(TVSoundClock.offset(frame: frame,standard: standard))
        let count = TVSoundClock.count(frame: frame,standard: standard)
        return audioPCM.withUnsafeBytes { bytes in
            (0..<count).map { n in
                let offset = (start+n)*MemoryLayout<Float>.size
                return offset+4 <= bytes.count ? Float(bitPattern: UInt32(littleEndian: bytes.loadUnaligned(fromByteOffset: offset,as: UInt32.self))) : 0
            }
        }
    }

    public func endPlayback() {
        reader?.close(); reader = nil; simulationFrame = nil
        pipeline = nil; prepared = nil
    }

    public func render(time: Double, channel settings: TerrestrialSettings? = nil,
                       settleAfterSeek: Bool = true, cable: TVCableSettings = .off) throws -> Preview {
        try Task.checkCancellation()
        let result = try frameQueue.sync { try renderFrame(time: time,channel: settings,
            settleAfterSeek: settleAfterSeek, cable: cable) }
        try Task.checkCancellation()
        return result
    }

    private func renderFrame(time: Double, channel settings: TerrestrialSettings?,
                             settleAfterSeek: Bool, cable: TVCableSettings) throws -> Preview {
        let started = ContinuousClock.now
        try Task.checkCancellation()
        let settings = settings ?? TerrestrialSettings(system: TerrestrialSystem(video: standard))
        guard let ffmpeg, let normalizedURL else { throw TVVideoError.noVideo }
        let boundedTime = min(max(0, time), max(0, duration - 1 / standard.frameRate))
        let frameIndex = Int64((boundedTime * standard.frameRate + 1e-7).rounded(.down))
        // The frame's inputs: cached when this call follows the one we prepared,
        // otherwise read and converted now.
        let discontinuity = simulationFrame != frameIndex-1 || simulationSeed != settings.seed || simulationProfile != settings.performance
            || (prepared != nil && prepared!.frameIndex != frameIndex)
        // Adjacent playback frames retain every FIR, delay line, oscillator and
        // PLL. A seek, a new seed or a frame we did not prepare starts a fresh
        // receiver acquisition.
        if discontinuity || pipeline == nil {
            // The stages must run at the same QoS as this queue: a UI-priority
            // caller blocking on userInitiated workers is a priority inversion, and
            // under load the frames then arrive late.
            let fresh = TVFramePipeline(system: TerrestrialSystem(video: standard), seed: settings.seed,
                                        qos: DispatchQoS(qosClass: .userInteractive,relativePriority: 0))
            // The caller runs the shared front end itself and waits only for the
            // transmit hand-off: one cross-thread hop per frame instead of two.
            fresh.frontEndOnCaller = true
            pipeline = fresh
            prepared = nil
        }
        guard let pipeline else { throw TVVideoError.noVideo }
        let frame: TVFrame
        let original: CGImage
        let audio: [Float]?
        let timing: EncodeTiming
        var reusedPrepared = false
        if let ready = prepared, ready.frameIndex == frameIndex {
            frame = ready.frame; original = ready.original; audio = ready.audio; timing = ready.timing
            reusedPrepared = true
            prepared = nil
        } else {
            let bytes = try readSourceFrame(frameIndex,ffmpeg: ffmpeg,normalizedURL: normalizedURL,
                                            expectedBytes: standard.width*standard.height*3)
            frame = try makeFrame(bytes)
            original = try Self.image(bytes,width: standard.width,height: standard.height)
            audio = sourceAudio(frame: frameIndex)
            timing = EncodeTiming()
        }
        let sourceDone = ContinuousClock.now
        if !reusedPrepared {
            if discontinuity {
                // Seek acquisition uses two frozen-picture pre-roll frames. This
                // settles carrier/AGC loops before a paused preview, without
                // inventing RF lock.
                for prior in settleAfterSeek ? [max(0, frameIndex-2), max(0, frameIndex-1)] : [] {
                    try Task.checkCancellation()
                    let priorAudio = sourceAudio(frame: prior)
                    try pipeline.submit(TVFrameRequest(frameIndex: prior,settings: settings) { _ in
                        (try TVEngine.encode(frame,frameIndex: prior,execution: settings.execution,damage: settings.transmitter.encoder),priorAudio)
                    })
                    _ = try pipeline.receive()
                }
            }
            try Task.checkCancellation()
            try pipeline.submit(TVFrameRequest(frameIndex: frameIndex,settings: settings) { index in
                let encodeStart = ContinuousClock.now
                let composite = try TVEngine.encode(frame,frameIndex: index,execution: settings.execution,damage: settings.transmitter.encoder)
                timing.duration = encodeStart.duration(to: .now)
                return (composite,audio)
            })
        }
        let acquiredAt = ContinuousClock.now
        let decoded = try pipeline.receive()
        simulationSeed = settings.seed
        simulationProfile = settings.performance
        simulationFrame = frameIndex
        try Task.checkCancellation()
        let decodedAt = ContinuousClock.now
        let image: CGImage
        if cable.kind == .off {
            image = try Self.image(decoded.frame)
        } else {
            let cableRGB = TVCableProcessor.apply(decoded.frame.rgb, width: standard.width,
                height: standard.height, settings: cable, frameIndex: frameIndex)
            image = try Self.image(try TVFrame(standard: standard, rgb: cableRGB))
        }
        let finished = ContinuousClock.now
        // Hand the next playback frame over now, so its construction, transmit and
        // front end run during the gap before the next call and that call is left
        // with detection and this image conversion only. A call that just went
        // through a discontinuity does not: the stream is dropping or jumping
        // frames, so the prepared frame would very likely be discarded and its
        // source read, conversion and transmit wasted, slowing a producer that is
        // already behind.
        prepared = discontinuity ? nil
            : prepareLookahead(after: frameIndex,ffmpeg: ffmpeg,normalizedURL: normalizedURL,
                               settings: settings)
        return Preview(original: original, image: image, duration: duration,
            frameIndex: frameIndex, encodeSeconds: Self.seconds(timing.duration),
            decodeSeconds: Self.seconds(acquiredAt.duration(to: decodedAt)),
            sourceSeconds: Self.seconds(started.duration(to: sourceDone)),
            outputSeconds: Self.seconds(decodedAt.duration(to: finished)),
            prerollSeconds: discontinuity && !reusedPrepared
                ? Self.seconds(sourceDone.duration(to: acquiredAt)) : 0, reception: decoded)
    }

    /// Read one frame's pixels from the decoder pipe, restarting it for large or
    /// backward jumps exactly as playback always has.
    private func readSourceFrame(_ frameIndex: Int64, ffmpeg: URL, normalizedURL: URL,
                                 expectedBytes: Int) throws -> Data {
        // Reuse a backpressured RGB pipe for nearby forward frames. Large or
        // backward seeks restart at the requested timestamp instead of decoding
        // the whole clip or spawning FFmpeg again for every playback frame.
        if reader == nil || frameIndex < nextFrameIndex || frameIndex - nextFrameIndex > 8 {
            reader?.close(); reader = nil; prepared = nil
            let timestamp = Double(frameIndex)/standard.frameRate
            reader = try TVFFmpegProcess(ffmpeg, ["-hide_banner", "-loglevel", "error", "-ss",
                String(format: "%.9f", timestamp), "-threads", "2", "-filter_threads", "1", "-i", normalizedURL.path, "-map", "0:v:0", "-an",
                "-f", "rawvideo", "-pix_fmt", "rgb24", "pipe:1"])
            nextFrameIndex = frameIndex
        }
        var bytes = Data()
        do {
            while nextFrameIndex <= frameIndex {
                try Task.checkCancellation()
                bytes = try reader!.readFrame(byteCount: expectedBytes)
                nextFrameIndex += 1
            }
        } catch { endPlayback(); throw error }
        return bytes
    }

    /// Convert raw RGB24 bytes into a frame, borrowing once so Data's per-subscript
    /// checks and bridging do not run for every colour component.
    private func makeFrame(_ bytes: Data) throws -> TVFrame {
        let pixelCount = standard.width*standard.height
        let rgb = bytes.withUnsafeBytes { raw in
            let source = raw.baseAddress!.assumingMemoryBound(to: UInt8.self)
            return [SIMD3<Float>](unsafeUninitializedCapacity: pixelCount) { buffer,initialized in
                let target = buffer.baseAddress!
                for n in 0..<pixelCount {
                    let p = n*3
                    target.advanced(by: n).initialize(to: SIMD3(Float(source[p])/255,
                        Float(source[p+1])/255,Float(source[p+2])/255))
                }
                initialized = pixelCount
            }
        }
        return try TVFrame(standard: standard, rgb: rgb)
    }

    /// Prepare and submit the frame the playback clock is expected to ask for
    /// next. Anything that fails here — the end of the clip, a cancellation, a
    /// reader error — leaves nothing in flight, so the next call simply acquires
    /// its frame the ordinary way.
    private func prepareLookahead(after frameIndex: Int64, ffmpeg: URL, normalizedURL: URL,
                                  settings: TerrestrialSettings) -> PreparedFrame? {
        guard let pipeline else { return nil }
        let next = frameIndex+1
        guard Double(next) <= duration*standard.frameRate else { return nil }
        do {
            let bytes = try readSourceFrame(next,ffmpeg: ffmpeg,normalizedURL: normalizedURL,
                                            expectedBytes: standard.width*standard.height*3)
            let frame = try makeFrame(bytes)
            let original = try Self.image(bytes,width: standard.width,height: standard.height)
            let audio = sourceAudio(frame: next)
            let timing = EncodeTiming()
            try pipeline.submit(TVFrameRequest(frameIndex: next,settings: settings) { index in
                let encodeStart = ContinuousClock.now
                let composite = try TVEngine.encode(frame,frameIndex: index,execution: settings.execution,damage: settings.transmitter.encoder)
                timing.duration = encodeStart.duration(to: .now)
                return (composite,audio)
            })
            return PreparedFrame(frameIndex: next,frame: frame,original: original,audio: audio,timing: timing)
        } catch {
            prepared = nil
            return nil
        }
    }

    private static func seconds(_ duration: Duration) -> Double {
        let c = duration.components
        return Double(c.seconds) + Double(c.attoseconds) / 1e18
    }

    private static func run(_ executable: URL, _ arguments: [String]) throws -> Data {
        let process = try TVFFmpegProcess(executable, arguments)
        defer { process.close() }
        let data = process.output.readDataToEndOfFile()
        try process.finish()
        return data
    }

    private static func runPreparing(_ executable: URL, _ arguments: [String], duration: Double?,
                                     stage: TVPreparationProgress.Stage, start: Double, weight: Double,
                                     progress: (@Sendable (TVPreparationProgress) -> Void)?) throws {
        let process = try TVFFmpegProcess(executable,["-nostats","-stats_period","0.1","-progress","pipe:1"]+arguments)
        defer { process.close() }
        let duration = duration.flatMap { $0.isFinite && $0 > 0 ? $0 : nil }
        progress?(TVPreparationProgress(stage: stage,fraction: duration == nil ? nil : start))
        var pending = Data(), last = start
        while true {
            let data = process.output.availableData
            if data.isEmpty { break }
            try Task.checkCancellation()
            pending.append(data)
            while let end = pending.firstIndex(of: 10) {
                let line = String(decoding: pending[..<end],as: UTF8.self)
                pending.removeSubrange(...end)
                if line.hasPrefix("out_time_us="), let duration,
                   let micros = Double(line.dropFirst("out_time_us=".count)), micros.isFinite {
                    last = max(last,start+weight*min(1,max(0,micros/1e6/duration)))
                    progress?(TVPreparationProgress(stage: stage,fraction: last))
                }
            }
        }
        try process.finish()
        progress?(TVPreparationProgress(stage: stage,fraction: start+weight))
    }

    private static func image(_ frame: TVFrame) throws -> CGImage {
        let count = frame.rgb.count*3
        let bytes = frame.rgb.withUnsafeBufferPointer { source in
            [UInt8](unsafeUninitializedCapacity: count) { buffer,initialized in
                let target = buffer.baseAddress!, pixels = source.baseAddress!
                for n in 0..<source.count {
                    let p = pixels[n]
                    target.advanced(by: n*3).initialize(to: UInt8(min(255,max(0,(p.x*255).rounded()))))
                    target.advanced(by: n*3+1).initialize(to: UInt8(min(255,max(0,(p.y*255).rounded()))))
                    target.advanced(by: n*3+2).initialize(to: UInt8(min(255,max(0,(p.z*255).rounded()))))
                }
                initialized = count
            }
        }
        return try image(Data(bytes), width: frame.standard.width, height: frame.standard.height)
    }

    private static func image(_ bytes: Data, width: Int, height: Int) throws -> CGImage {
        guard let provider = CGDataProvider(data: bytes as CFData),
              let image = CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 24,
                bytesPerRow: width * 3, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue), provider: provider,
                decode: nil, shouldInterpolate: false, intent: .defaultIntent) else { throw TVVideoError.invalidFrame }
        return image
    }
}

public enum TVVideoError: Error, LocalizedError {
    case ffmpegNotFound, ffprobeNotFound, noVideo, invalidVideo, invalidFrame
    case processLaunch(String, String), processFailed(String, Int32, String)
    public var errorDescription: String? {
        switch self {
        case .ffmpegNotFound: "ffmpeg was not found in PATH or the Homebrew/MacPorts installation folders"
        case .ffprobeNotFound: "ffprobe was not found in PATH or the Homebrew/MacPorts installation folders"
        case .noVideo: "Load a video before rendering a television frame"
        case .invalidVideo: "ffprobe could not read the normalized video's duration"
        case .invalidFrame: "ffmpeg returned an incomplete television frame"
        case let .processLaunch(tool, reason): "Could not start \(tool): \(reason)"
        case let .processFailed(tool, code, detail): "\(tool) exited with status \(code)\(detail.isEmpty ? "" : ": " + detail)"
        }
    }
}


public struct TVExportProgress: Sendable {
    public let fraction: Double
    /// Media seconds produced per wall-clock second, including file writes.
    public let speed: Double
}

extension TVRenderer {
    private static func runExportEncoder(_ executable: URL, _ arguments: [String], logDirectory: URL) async throws {
        let logURL = logDirectory.appendingPathComponent("encoder.log")
        FileManager.default.createFile(atPath: logURL.path, contents: nil)
        let log = try FileHandle(forWritingTo: logURL)
        let process = Process()
        process.executableURL = executable; process.arguments = arguments
        process.standardOutput = FileHandle.nullDevice; process.standardError = log
        defer {
            if process.isRunning { process.terminate() }
            try? log.close()
        }
        try process.run()
        while process.isRunning {
            try await Task.sleep(for: .milliseconds(50))
        }
        try Task.checkCancellation()
        guard process.terminationStatus == 0 else {
            let detail = String(decoding: (try? Data(contentsOf: logURL)) ?? Data(), as: UTF8.self)
            throw TVVideoError.processFailed("ffmpeg", process.terminationStatus, String(detail.suffix(4096)))
        }
    }

    /// Offline, continuous simulation with recovered audio. MOV stores PNG video
    /// and float PCM, avoiding an additional lossy codec after simulation.
    public func exportVideo(to destination: URL, channel: TerrestrialSettings,
                            cable: TVCableSettings = .off,
                            progress: @escaping @Sendable (TVExportProgress) -> Void) async throws -> TVExportProgress {
        guard let ffmpeg, normalizedURL != nil else { throw TVVideoError.noVideo }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("AnaLine-export-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let rgbURL = directory.appendingPathComponent("video.rgb")
        let pcmURL = directory.appendingPathComponent("audio.f32le")
        let movie = destination.deletingLastPathComponent().appendingPathComponent(".AnaLine-" + UUID().uuidString + ".mov")
        defer {
            try? FileManager.default.removeItem(at: directory)
            try? FileManager.default.removeItem(at: movie)
            endPlayback()
        }
        FileManager.default.createFile(atPath: rgbURL.path, contents: nil)
        FileManager.default.createFile(atPath: pcmURL.path, contents: nil)
        let video = try FileHandle(forWritingTo: rgbURL)
        let audio = try FileHandle(forWritingTo: pcmURL)
        defer { try? video.close(); try? audio.close() }
        endPlayback()
        let frameCount = max(1, Int((duration * standard.frameRate + 1e-7).rounded(.down)))
        let withAudio = audioPCM != nil
        let start = ContinuousClock.now
        var lastUpdate = start
        for index in 0..<frameCount {
            try Task.checkCancellation()
            let preview = try render(time: Double(index)/standard.frameRate, channel: channel,
                settleAfterSeek: false, cable: cable)
            let pixels = cable.kind == .off ? preview.reception.frame.rgb
                : TVCableProcessor.apply(preview.reception.frame.rgb, width: standard.width,
                    height: standard.height, settings: cable, frameIndex: preview.frameIndex)
            let bytes = pixels.withUnsafeBufferPointer { source in
                [UInt8](unsafeUninitializedCapacity: source.count*3) { target, initialized in
                    for n in source.indices {
                        for component in 0..<3 {
                            target[n*3+component] = UInt8((max(0,min(1,source[n][component]))*255).rounded())
                        }
                    }
                    initialized = source.count*3
                }
            }
            try video.write(contentsOf: Data(bytes))
            if withAudio {
                try preview.reception.audio.withUnsafeBytes { try audio.write(contentsOf: $0) }
            }
            let now = ContinuousClock.now
            if Self.seconds(lastUpdate.duration(to: now)) >= 0.25 || index == frameCount-1 {
                let elapsed = max(1e-9, Self.seconds(start.duration(to: now)))
                progress(TVExportProgress(fraction: Double(index+1)/Double(frameCount),
                    speed: (Double(index+1)/standard.frameRate)/elapsed))
                lastUpdate = now
            }
            await Task.yield()
        }
        try video.close(); try audio.close()
        try Task.checkCancellation()
        let rate = standard == .pal ? "25" : "30000/1001"
        var arguments = ["-v", "error", "-nostdin", "-f", "rawvideo", "-pixel_format", "rgb24",
                         "-video_size", "\(standard.width)x\(standard.height)", "-framerate", rate,
                         "-i", rgbURL.path]
        if withAudio { arguments += ["-f", "f32le", "-ar", "48000", "-ac", "1", "-i", pcmURL.path] }
        arguments += ["-c:v", "png", "-pix_fmt", "rgb24", "-vf", standard == .pal ? "setsar=16/15" : "setsar=8/9"]
        if withAudio { arguments += ["-c:a", "pcm_f32le"] }
        arguments += ["-frames:v", String(frameCount), "-t", String(Double(frameCount)/standard.frameRate), movie.path]
        try await Self.runExportEncoder(ffmpeg, arguments, logDirectory: directory)
        try Task.checkCancellation()
        if FileManager.default.fileExists(atPath: destination.path) {
            _ = try FileManager.default.replaceItemAt(destination, withItemAt: movie)
        } else { try FileManager.default.moveItem(at: movie, to: destination) }
        let result = TVExportProgress(fraction: 1, speed: (Double(frameCount)/standard.frameRate)
            / max(1e-9, Self.seconds(start.duration(to: .now))))
        progress(result)
        return result
    }
}
