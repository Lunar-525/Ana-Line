import Foundation
import CoreGraphics
import AnalogCore

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
        public let reception: TerrestrialReception
    }

    private var ffmpeg: URL?
    private var ffprobe: URL?
    private var normalizedURL: URL?
    private var audioURL: URL?
    private var reader: TVFFmpegProcess?
    private var nextFrameIndex: Int64 = 0
    private var standard: TVStandard = .pal
    private var duration: Double = 0
    private var terrestrial = TerrestrialEngine(system: .palDK)
    private var simulationFrame: Int64?
    private var simulationSeed: UInt64 = 42
    private let executableSearchPath: String

    public init() {
        executableSearchPath = ProcessInfo.processInfo.environment["PATH", default: "/usr/bin:/bin:/usr/sbin:/sbin"]
    }

    init(executableSearchPath: String) { self.executableSearchPath = executableSearchPath }

    public func loadVideo(_ url: URL, standard: TVStandard = .pal) throws -> Double {
        guard let ffmpeg = TVExecutableResolver.find("ffmpeg", path: executableSearchPath) else { throw TVVideoError.ffmpegNotFound }
        guard let ffprobe = TVExecutableResolver.find("ffprobe", path: executableSearchPath) else { throw TVVideoError.ffprobeNotFound }
        let output = FileManager.default.temporaryDirectory
            .appendingPathComponent("AnaLine-TV-\(UUID().uuidString).mp4")
        let audioOutput = output.deletingPathExtension().appendingPathExtension("m4a")
        let filter = "scale=\(standard.width):\(standard.height):force_original_aspect_ratio=decrease:flags=lanczos,pad=\(standard.width):\(standard.height):(ow-iw)/2:(oh-ih)/2:color=black,setsar=1,fps=\(standard.ffmpegFrameRate)"
        do {
            _ = try Self.run(ffmpeg, ["-hide_banner", "-loglevel", "error", "-y", "-i", url.path,
                "-map", "0:v:0", "-vf", filter, "-an", "-c:v", "libx264", "-preset", "ultrafast",
                "-crf", "0", "-pix_fmt", "yuv444p", "-movflags", "+faststart", output.path])
            let probe = try Self.run(ffprobe, ["-v", "error", "-show_entries", "format=duration",
                "-of", "default=noprint_wrappers=1:nokey=1", output.path])
            guard let parsedDuration = Double(String(decoding: probe, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)),
                  parsedDuration.isFinite, parsedDuration > 0 else { throw TVVideoError.invalidVideo }
            // Keep preview audio separate from the lossless H.264 4:4:4 picture
            // intermediate, which AVPlayer need not support as a video format.
            let audioProbe = try Self.run(ffprobe, ["-v", "error", "-select_streams", "a:0",
                "-show_entries", "stream=index", "-of", "csv=p=0", url.path])
            let hasAudio = !audioProbe.isEmpty
            if hasAudio {
                _ = try Self.run(ffmpeg, ["-hide_banner", "-loglevel", "error", "-y", "-i", url.path,
                    "-map", "0:a:0", "-vn", "-c:a", "aac", "-b:a", "192k", "-ac", "2",
                    "-af", "aresample=async=1:first_pts=0", "-t", String(parsedDuration), audioOutput.path])
            }
            endPlayback()
            if let normalizedURL { try? FileManager.default.removeItem(at: normalizedURL) }
            if let audioURL { try? FileManager.default.removeItem(at: audioURL) }
            self.ffmpeg = ffmpeg; self.ffprobe = ffprobe; normalizedURL = output
            audioURL = hasAudio ? audioOutput : nil
            self.standard = standard; duration = parsedDuration
            terrestrial = TerrestrialEngine(system: TerrestrialSystem(video: standard))
            simulationFrame = nil
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
        normalizedURL = nil; audioURL = nil; duration = 0
    }

    public func playbackAudioURL() -> URL? { audioURL }

    public func endPlayback() { reader?.close(); reader = nil; simulationFrame = nil }

    public func render(time: Double, channel settings: TerrestrialSettings? = nil) throws -> Preview {
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
                String(format: "%.9f", timestamp), "-i", normalizedURL.path, "-map", "0:v:0", "-an",
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
        var rgb = [SIMD3<Float>](); rgb.reserveCapacity(standard.width * standard.height)
        for i in stride(from: 0, to: bytes.count, by: 3) {
            rgb.append(SIMD3(Float(bytes[i]) / 255, Float(bytes[i + 1]) / 255, Float(bytes[i + 2]) / 255))
        }
        let frame = try TVFrame(standard: standard, rgb: rgb)
        let original = try Self.image(bytes, width: standard.width, height: standard.height)
        let encodeStart = ContinuousClock.now
        let composite = try TVEngine.encode(frame, frameIndex: frameIndex)
        try Task.checkCancellation()
        let encodedAt = ContinuousClock.now
        // Adjacent playback frames retain every FIR, delay line, oscillator and PLL.
        // A seek or paused re-render starts a fresh receiver acquisition.
        if simulationFrame != frameIndex-1 || simulationSeed != settings.seed {
            terrestrial = TerrestrialEngine(system: TerrestrialSystem(video: standard), seed: settings.seed)
            // Seek acquisition uses two frozen-picture pre-roll frames. This settles
            // carrier/AGC loops before a paused preview, without inventing RF lock.
            for prior in [max(0, frameIndex-2), max(0, frameIndex-1)] {
                try Task.checkCancellation()
                _ = try terrestrial.process(TVEngine.encode(frame, frameIndex: prior), settings: settings)
            }
        }
        simulationSeed = settings.seed
        let decoded = try terrestrial.process(composite, settings: settings)
        simulationFrame = frameIndex
        try Task.checkCancellation()
        let decodedAt = ContinuousClock.now
        return Preview(original: original, image: try Self.image(decoded.frame), duration: duration,
            frameIndex: frameIndex, encodeSeconds: Self.seconds(encodeStart.duration(to: encodedAt)),
            decodeSeconds: Self.seconds(encodedAt.duration(to: decodedAt)), reception: decoded)
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

    private static func image(_ frame: TVFrame) throws -> CGImage {
        var bytes = [UInt8](); bytes.reserveCapacity(frame.rgb.count * 3)
        for p in frame.rgb {
            bytes.append(UInt8(min(255, max(0, (p.x * 255).rounded()))))
            bytes.append(UInt8(min(255, max(0, (p.y * 255).rounded()))))
            bytes.append(UInt8(min(255, max(0, (p.z * 255).rounded()))))
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
