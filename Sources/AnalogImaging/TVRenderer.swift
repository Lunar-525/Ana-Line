import Foundation
import CoreGraphics
import AnalogCore

public struct TVPreparationProgress: Sendable {
    public enum Stage: Sendable { case video, audio }
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
    private var terrestrial = TerrestrialEngine(system: .palDK)
    private var simulationFrame: Int64?
    private var simulationSeed: UInt64 = 42
    private let executableSearchPath: String

    public init() {
        executableSearchPath = ProcessInfo.processInfo.environment["PATH", default: "/usr/bin:/bin:/usr/sbin:/sbin"]
    }

    init(executableSearchPath: String) { self.executableSearchPath = executableSearchPath }

    deinit {
        // These UUID paths are owned conversion outputs, never the user's source.
        // A renderer released after playback must not leave hundreds of MB behind.
        if let normalizedURL { try? FileManager.default.removeItem(at: normalizedURL) }
        if let audioURL { try? FileManager.default.removeItem(at: audioURL) }
    }

    public func loadVideo(_ url: URL, standard: TVStandard = .pal,
                          progress: (@Sendable (TVPreparationProgress) -> Void)? = nil) throws -> Double {
        guard let ffmpeg = TVExecutableResolver.find("ffmpeg", path: executableSearchPath) else { throw TVVideoError.ffmpegNotFound }
        guard let ffprobe = TVExecutableResolver.find("ffprobe", path: executableSearchPath) else { throw TVVideoError.ffprobeNotFound }
        let output = FileManager.default.temporaryDirectory
            .appendingPathComponent("AnaLine-TV-\(UUID().uuidString).mp4")
        let audioOutput = output.deletingPathExtension().appendingPathExtension("f32le")
        let filter = "scale=iw*sar:ih:flags=lanczos,setsar=1,scale=\(standard.squarePixelWidth):\(standard.height):force_original_aspect_ratio=decrease:flags=lanczos,pad=\(standard.squarePixelWidth):\(standard.height):(ow-iw)/2:(oh-ih)/2:color=black,scale=\(standard.width):\(standard.height):flags=lanczos,setsar=\(standard.pixelAspect),fps=\(standard.ffmpegFrameRate)"
        do {
            progress?(TVPreparationProgress(stage: .video,fraction: nil))
            let sourceProbe = try Self.run(ffprobe, ["-v", "error", "-show_entries", "format=duration",
                "-of", "default=noprint_wrappers=1:nokey=1", url.path])
            let sourceDuration = Double(String(decoding: sourceProbe,as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines))
            let audioProbe = try Self.run(ffprobe, ["-v", "error", "-select_streams", "a:0",
                "-show_entries", "stream=index", "-of", "csv=p=0", url.path])
            let hasAudio = !audioProbe.isEmpty
            try Self.runPreparing(ffmpeg, ["-hide_banner", "-loglevel", "error", "-y", "-i", url.path,
                "-map", "0:v:0", "-vf", filter, "-an", "-c:v", "libx264", "-preset", "ultrafast",
                "-crf", "0", "-pix_fmt", "yuv444p", "-movflags", "+faststart", output.path],
                duration: sourceDuration,stage: .video,start: 0,weight: hasAudio ? 0.9 : 1,progress: progress)
            let probe = try Self.run(ffprobe, ["-v", "error", "-show_entries", "format=duration",
                "-of", "default=noprint_wrappers=1:nokey=1", output.path])
            guard let parsedDuration = Double(String(decoding: probe, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)),
                  parsedDuration.isFinite, parsedDuration > 0 else { throw TVVideoError.invalidVideo }
            if hasAudio {
                try Self.runPreparing(ffmpeg, ["-hide_banner", "-loglevel", "error", "-y", "-i", url.path,
                    "-map", "0:a:0", "-vn", "-c:a", "pcm_f32le", "-ar", "48000", "-ac", "1",
                    "-af", "aresample=async=1:first_pts=0,apad", "-t", String(parsedDuration),
                    "-f", "f32le", audioOutput.path],duration: parsedDuration,stage: .audio,
                    start: 0.9,weight: 0.1,progress: progress)
            }
            let pcm = hasAudio ? try Data(contentsOf: audioOutput,options: .mappedIfSafe) : nil
            try Task.checkCancellation()
            endPlayback()
            if let normalizedURL { try? FileManager.default.removeItem(at: normalizedURL) }
            if let audioURL { try? FileManager.default.removeItem(at: audioURL) }
            self.ffmpeg = ffmpeg; self.ffprobe = ffprobe; normalizedURL = output
            audioURL = hasAudio ? audioOutput : nil
            audioPCM = pcm
            self.standard = standard; duration = parsedDuration
            terrestrial = TerrestrialEngine(system: TerrestrialSystem(video: standard))
            simulationFrame = nil
            progress?(TVPreparationProgress(stage: hasAudio ? .audio : .video,fraction: 1))
            return parsedDuration
        } catch {
            try? FileManager.default.removeItem(at: output)
            try? FileManager.default.removeItem(at: audioOutput)
            throw error
        }
    }

    public func unloadVideo() {
        endPlayback()
        if let normalizedURL { try? FileManager.default.removeItem(at: normalizedURL) }
        if let audioURL { try? FileManager.default.removeItem(at: audioURL) }
        normalizedURL = nil; audioURL = nil; audioPCM = nil; duration = 0
    }

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

    public func endPlayback() { reader?.close(); reader = nil; simulationFrame = nil }

    public func render(time: Double, channel settings: TerrestrialSettings? = nil) throws -> Preview {
        try Task.checkCancellation()
        let result = try frameQueue.sync { try renderFrame(time: time,channel: settings) }
        try Task.checkCancellation()
        return result
    }

    private func renderFrame(time: Double,channel settings: TerrestrialSettings?) throws -> Preview {
        let started = ContinuousClock.now
        try Task.checkCancellation()
        let settings = settings ?? TerrestrialSettings(system: TerrestrialSystem(video: standard))
        guard let ffmpeg, let normalizedURL else { throw TVVideoError.noVideo }
        let boundedTime = min(max(0, time), max(0, duration - 1 / standard.frameRate))
        let frameIndex = Int64((boundedTime * standard.frameRate + 1e-7).rounded(.down))
        let expectedBytes = standard.width * standard.height * 3
        // Reuse a backpressured RGB pipe for nearby forward frames. Large or
        // backward seeks restart at the requested timestamp instead of decoding
        // the whole clip or spawning FFmpeg again for every playback frame.
        if reader == nil || frameIndex < nextFrameIndex || frameIndex - nextFrameIndex > 8 {
            endPlayback()
            let timestamp = Double(frameIndex) / standard.frameRate
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
        try Task.checkCancellation()
        // The pipe has supplied exactly width*height*3 bytes. Borrow once,
        // avoiding Data's per-subscript checks/bridging for every color component.
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
        let frame = try TVFrame(standard: standard, rgb: rgb)
        let original = try Self.image(bytes, width: standard.width, height: standard.height)
        let encodeStart = ContinuousClock.now
        let composite = try TVEngine.encode(frame, frameIndex: frameIndex, execution: settings.execution, damage: settings.transmitter.encoder)
        try Task.checkCancellation()
        let encodedAt = ContinuousClock.now
        let reacquiring = simulationFrame != frameIndex-1 || simulationSeed != settings.seed
        // Adjacent playback frames retain every FIR, delay line, oscillator and PLL.
        // A seek or paused re-render starts a fresh receiver acquisition.
        if reacquiring {
            terrestrial = TerrestrialEngine(system: TerrestrialSystem(video: standard), seed: settings.seed)
            // Seek acquisition uses two frozen-picture pre-roll frames. This settles
            // carrier/AGC loops before a paused preview, without inventing RF lock.
            for prior in [max(0, frameIndex-2), max(0, frameIndex-1)] {
                try Task.checkCancellation()
                let signal = try TVEngine.encode(frame,frameIndex: prior,execution: settings.execution,damage: settings.transmitter.encoder)
                let pcm = sourceAudio(frame: prior)
                _ = try terrestrial.process(signal,settings: settings,audio: pcm)
            }
        }
        simulationSeed = settings.seed
        let acquiredAt = ContinuousClock.now
        let pcm = sourceAudio(frame: frameIndex)
        let decoded = try terrestrial.process(composite,settings: settings,audio: pcm)
        simulationFrame = frameIndex
        try Task.checkCancellation()
        let decodedAt = ContinuousClock.now
        let image = try Self.image(decoded.frame)
        let finished = ContinuousClock.now
        return Preview(original: original, image: image, duration: duration,
            frameIndex: frameIndex, encodeSeconds: Self.seconds(encodeStart.duration(to: encodedAt)),
            decodeSeconds: Self.seconds(acquiredAt.duration(to: decodedAt)),
            sourceSeconds: Self.seconds(started.duration(to: encodeStart)),
            outputSeconds: Self.seconds(decodedAt.duration(to: finished)),
            prerollSeconds: reacquiring ? Self.seconds(encodedAt.duration(to: acquiredAt)) : 0, reception: decoded)
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
        let process = try TVFFmpegProcess(executable,["-nostats","-progress","pipe:1"]+arguments)
        defer { process.close() }
        let duration = duration.flatMap { $0.isFinite && $0 > 0 ? $0 : nil }
        progress?(TVPreparationProgress(stage: stage,fraction: duration == nil ? nil : start))
        var pending = Data(), last = start
        while let data = try process.output.read(upToCount: 4096), !data.isEmpty {
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
