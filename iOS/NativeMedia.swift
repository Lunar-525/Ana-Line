import AVFoundation
import UIKit

struct MobileFrame: @unchecked Sendable {
    let original: UIImage
    let simulated: UIImage
    let audio: [Float]?
    let frame: TVFrame
    let index: Int64
    let seconds: Double
    let processingMS: Double
    let locked: Bool
}

struct MobileProgress: Sendable {
    let fraction: Double
    let speed: Double
}

enum MobileMediaError: LocalizedError {
    case message(String)
    var errorDescription: String? { if case .message(let text) = self { return text }; return nil }
}

/// Native, bounded video decoding. Audio is normalized once to a disk-backed PCM
/// file; each frame reads only its own exact sound-clock sample interval.
actor MobileMedia {
    private var asset: AVURLAsset?
    private var videoTrack: AVAssetTrack?
    private var audioFile: FileHandle?
    private var pcmURL: URL?
    private var reader: AVAssetReader?
    private var videoOutput: AVAssetReaderVideoCompositionOutput?
    private var composition: AVMutableVideoComposition?
    private var currentSample: CMSampleBuffer?
    private var followingSample: CMSampleBuffer?
    private var standard = TVStandard.pal
    private var settings = TerrestrialSettings(system: .palDK)
    private var pipeline: TVFramePipeline?
    private var pending: [(Int64, TVFrame)] = []
    private var nextIndex: Int64 = 0
    private var count: Int64 = 0
    private(set) var duration: Double = 0

    static func frameTime(_ index: Int64, _ standard: TVStandard) -> CMTime {
        standard == .pal ? CMTime(value: index, timescale: 25)
            : CMTime(value: index*1001, timescale: 30000)
    }
    static func seconds(_ duration: Duration) -> Double {
        let value = duration.components
        return Double(value.seconds) + Double(value.attoseconds)/1e18
    }

    func load(_ url: URL, standard: TVStandard, settings: TerrestrialSettings,
              progress: @escaping @Sendable (Double) -> Void) async throws -> Double {
        close()
        let asset = AVURLAsset(url: url)
        let tracks = try await asset.loadTracks(withMediaType: .video)
        guard let track = tracks.first else { throw MobileMediaError.message("文件不包含视频轨道。") }
        let descriptions = try await track.load(.formatDescriptions)
        for description in descriptions where CMFormatDescriptionGetMediaSubType(description) == kCMVideoCodecType_H264 {
            if let atoms = CMFormatDescriptionGetExtension(description, extensionKey: kCMFormatDescriptionExtension_SampleDescriptionExtensionAtoms) as? [String: Any],
               let avc = atoms["avcC"] as? Data, avc.count > 1, avc[1] == 244 {
                throw MobileMediaError.message("此 H.264 4:4:4 视频不受当前原生解码路径支持，请先转为 4:2:0 MOV／MP4。")
            }
        }
        let time = try await asset.load(.duration)
        guard time.seconds.isFinite, time.seconds > 0 else { throw MobileMediaError.message("无法读取视频时长。") }
        self.asset = asset; videoTrack = track; duration = time.seconds
        let audioTracks = try await asset.loadTracks(withMediaType: .audio)
        if let audioTrack = audioTracks.first {
            let url = FileManager.default.temporaryDirectory.appendingPathComponent("AnaLine-"+UUID().uuidString+".pcm")
            pcmURL = url
            FileManager.default.createFile(atPath: url.path, contents: nil)
            let file = try FileHandle(forWritingTo: url)
            defer { try? file.close() }
            let audioReader = try AVAssetReader(asset: asset)
            let output = AVAssetReaderAudioMixOutput(audioTracks: [audioTrack], audioSettings: [
                AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: 48000,
                AVNumberOfChannelsKey: 1, AVLinearPCMBitDepthKey: 32,
                AVLinearPCMIsFloatKey: true, AVLinearPCMIsNonInterleaved: false,
                AVLinearPCMIsBigEndianKey: false])
            audioReader.add(output)
            guard audioReader.startReading() else { throw audioReader.error ?? MobileMediaError.message("音频解码失败。") }
            var written: Int64 = 0
            while let sample = output.copyNextSampleBuffer() {
                try Task.checkCancellation()
                guard let block = CMSampleBufferGetDataBuffer(sample) else { continue }
                let presentation = CMSampleBufferGetPresentationTimeStamp(sample).seconds
                let expected = max(0, CMTimeConvertScale(CMSampleBufferGetPresentationTimeStamp(sample), timescale: 48000, method: .roundHalfAwayFromZero).value)*4
                // Preserve source timestamps, including leading silence and gaps.
                if expected > written {
                    var gap = expected-written
                    let zero = Data(repeating: 0, count: 65536)
                    while gap > 0 { let n = min(gap, 65536); try file.write(contentsOf: zero.prefix(Int(n))); gap -= n }
                    written = expected
                }
                let byteCount = CMBlockBufferGetDataLength(block)
                var data = Data(count: byteCount)
                let status = data.withUnsafeMutableBytes {
                    CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: byteCount, destination: $0.baseAddress!)
                }
                guard status == noErr else { throw MobileMediaError.message("无法读取音频样本。") }
                let skip = min(data.count, Int(max(0, written-expected)))
                try file.write(contentsOf: data.dropFirst(skip)); written += Int64(data.count-skip)
                progress(min(0.95, presentation/duration))
            }
            guard audioReader.status == .completed else { throw audioReader.error ?? MobileMediaError.message("音频解码中断。") }
            audioFile = try FileHandle(forReadingFrom: url)
        }
        try await configure(standard: standard, settings: settings, at: 0)
        progress(1)
        return duration
    }

    func configure(standard: TVStandard, settings: TerrestrialSettings, at time: Double,
                   crop: MobileCrop? = nil) async throws {
        guard asset != nil, let track = videoTrack else { throw MobileMediaError.message("请先导入视频。") }
        try settings.validate(rate: standard.sampleRate)
        let size = try await track.load(.naturalSize)
        let transform = try await track.load(.preferredTransform)
        try Task.checkCancellation()
        self.standard = standard; self.settings = settings
        count = max(1, Int64((duration*standard.frameRate+1e-7).rounded(.down)))
        let width = CGFloat(standard.width), height = CGFloat(standard.height)
        // A chosen 4:3 window fills the frame; until then the whole picture is
        // fitted with bars. Both are applied by the reader's video composition, so
        // neither costs a re-encode.
        let fit = crop.map { $0.transform(naturalSize: size, preferredTransform: transform, standard: standard) }
            ?? MobileCrop.fitTransform(naturalSize: size, preferredTransform: transform, standard: standard)
        let layer = AVMutableVideoCompositionLayerInstruction(assetTrack: track)
        layer.setTransform(fit, at: .zero)
        let instruction = AVMutableVideoCompositionInstruction()
        instruction.timeRange = CMTimeRange(start: .zero, duration: CMTime(seconds: duration, preferredTimescale: 60000))
        instruction.backgroundColor = UIColor.black.cgColor; instruction.layerInstructions = [layer]
        let composition = AVMutableVideoComposition()
        composition.renderSize = CGSize(width: width, height: height)
        composition.frameDuration = Self.frameTime(1, standard)
        composition.instructions = [instruction]; self.composition = composition
        let target = min(count-1, max(0, Int64(time*standard.frameRate)))
        try startReader(at: max(0, target-2))
        // Seek acquisition advances the same physical sample clock as playback.
        while nextIndex < target { _ = try next() }
    }

    /// One frame of the whole, un-cropped picture, upright, for the crop editor.
    /// AVAssetImageGenerator applies the track's preferred transform for us, so a
    /// portrait recording arrives the right way up.
    func sourcePreview(at time: Double, maximum: CGFloat = 1440) async throws -> UIImage {
        guard let asset else { throw MobileMediaError.message("请先导入视频。") }
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: maximum, height: maximum)
        let requested = CMTime(seconds: max(0, time), preferredTimescale: 60000)
        do {
            let (image, _) = try await generator.image(at: requested)
            return UIImage(cgImage: image)
        } catch {
            throw MobileMediaError.message("无法读取预览画面。")
        }
    }

    private func startReader(at index: Int64) throws {
        guard let asset, let track = videoTrack, let composition else { throw MobileMediaError.message("视频未准备好。") }
        reader?.cancelReading(); pipeline = nil; pending = []; currentSample = nil; followingSample = nil
        let reader = try AVAssetReader(asset: asset)
        reader.timeRange = CMTimeRange(start: Self.frameTime(index, standard),
            duration: CMTime(seconds: max(0, duration-Double(index)/standard.frameRate), preferredTimescale: 60000))
        let output = AVAssetReaderVideoCompositionOutput(videoTracks: [track], videoSettings: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA])
        output.videoComposition = composition; output.alwaysCopiesSampleData = false
        reader.add(output)
        guard reader.startReading() else { throw reader.error ?? MobileMediaError.message("视频解码失败。") }
        self.reader = reader; videoOutput = output; nextIndex = index
        pipeline = TVFramePipeline(system: TerrestrialSystem(video: standard), seed: settings.seed)
    }

    private func sound(_ index: Int64) throws -> [Float]? {
        guard let audioFile else { return nil }
        let start = TVSoundClock.offset(frame: index, standard: standard)
        let n = TVSoundClock.count(frame: index, standard: standard)
        try audioFile.seek(toOffset: UInt64(start)*4)
        let data = try audioFile.read(upToCount: n*4) ?? Data()
        var result = [Float](repeating: 0, count: n)
        result.withUnsafeMutableBytes { destination in
            data.withUnsafeBytes { source in
                if source.count > 0 { destination.baseAddress!.copyMemory(from: source.baseAddress!, byteCount: min(source.count, destination.count)) }
            }
        }
        return result
    }

    private func submit() throws {
        guard let pipeline, let videoOutput else { throw MobileMediaError.message("视频未准备好。") }
        let index = nextIndex + Int64(pending.count)
        guard index < count else { return }
        // Composition normalizes geometry; the explicit clock below normalizes
        // cadence. AVAssetReader may still deliver at the source's sample rate.
        if currentSample == nil {
            currentSample = try decodedSample(videoOutput)
            followingSample = try decodedSample(videoOutput)
        }
        let target = Self.frameTime(index, standard)
        while let following = followingSample,
              CMTimeCompare(CMSampleBufferGetPresentationTimeStamp(following), target) <= 0 {
            currentSample = following
            followingSample = try decodedSample(videoOutput)
        }
        guard let sample = currentSample, let buffer = CMSampleBufferGetImageBuffer(sample) else {
            throw reader?.error ?? MobileMediaError.message("视频没有可解码的画面。")
        }
        let frame = try Self.frame(buffer, standard: standard)
        let audio = try sound(index), settings = settings
        try pipeline.submit(TVFrameRequest(frameIndex: index, settings: settings) { index in
            (try TVEngine.encode(frame, frameIndex: index, execution: settings.execution, damage: settings.transmitter.encoder), audio)
        })
        pending.append((index, frame))
    }

    private func decodedSample(_ output: AVAssetReaderVideoCompositionOutput) throws -> CMSampleBuffer? {
        while let sample = output.copyNextSampleBuffer() {
            if CMSampleBufferGetImageBuffer(sample) != nil { return sample }
        }
        if reader?.status == .failed { throw reader?.error ?? MobileMediaError.message("视频解码失败。") }
        return nil
    }

    func next() throws -> MobileFrame? {
        try Task.checkCancellation()
        guard nextIndex < count, let pipeline else { return nil }
        let start = ContinuousClock.now
        if pending.isEmpty { try submit() }
        if pipeline.allowsLookahead, nextIndex+Int64(pending.count) < count { try submit() }
        let source = pending.removeFirst()
        let result = try pipeline.receive(); nextIndex += 1
        return MobileFrame(original: try Self.image(source.1), simulated: try Self.image(result.frame),
            audio: audioFile == nil ? nil : result.audio, frame: result.frame, index: source.0,
            seconds: Double(source.0)/standard.frameRate, processingMS: Self.seconds(start.duration(to: .now))*1000,
            locked: result.lock == .locked)
    }

    func close() {
        reader?.cancelReading(); reader = nil; videoOutput = nil; pipeline = nil; pending = []; currentSample = nil; followingSample = nil
        try? audioFile?.close(); audioFile = nil
        if let pcmURL { try? FileManager.default.removeItem(at: pcmURL) }
        pcmURL = nil; asset = nil; videoTrack = nil; composition = nil; duration = 0
    }

    static func frame(_ buffer: CVPixelBuffer, standard: TVStandard) throws -> TVFrame {
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(buffer) else { throw MobileMediaError.message("无法读取画面。") }
        let stride = CVPixelBufferGetBytesPerRow(buffer)
        var rgb = [SIMD3<Float>](repeating: .zero, count: standard.width*standard.height)
        for y in 0..<standard.height {
            let row = base.advanced(by: y*stride).assumingMemoryBound(to: UInt8.self)
            for x in 0..<standard.width { rgb[y*standard.width+x] = SIMD3(Float(row[x*4+2])/255, Float(row[x*4+1])/255, Float(row[x*4])/255) }
        }
        return try TVFrame(standard: standard, rgb: rgb)
    }

    static func image(_ frame: TVFrame) throws -> UIImage {
        var data = Data(count: frame.rgb.count*4)
        data.withUnsafeMutableBytes { (bytes: UnsafeMutableRawBufferPointer) in
            for n in frame.rgb.indices {
                for c in 0..<3 { bytes[n*4+c] = UInt8((max(0,min(1,frame.rgb[n][c]))*255).rounded()) }
                bytes[n*4+3] = 255
            }
        }
        guard let provider = CGDataProvider(data: data as CFData), let image = CGImage(width: frame.standard.width,
            height: frame.standard.height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: frame.standard.width*4,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGBitmapInfo.byteOrder32Big.union(CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue)),
            provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent) else {
            throw MobileMediaError.message("画面转换失败。")
        }
        return UIImage(cgImage: image)
    }

    func export(to output: URL, progress: @escaping @Sendable (MobileProgress) -> Void) async throws -> Double {
        guard asset != nil else { throw MobileMediaError.message("请先导入视频。") }
        try startReader(at: 0)
        let writer = try AVAssetWriter(outputURL: output, fileType: .mov)
        let video = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: standard.width, AVVideoHeightKey: standard.height,
            AVVideoPixelAspectRatioKey: [AVVideoPixelAspectRatioHorizontalSpacingKey: standard == .pal ? 16 : 8,
                                       AVVideoPixelAspectRatioVerticalSpacingKey: standard == .pal ? 15 : 9],
            AVVideoCompressionPropertiesKey: [AVVideoAverageBitRateKey: 8_000_000]])
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: video, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: standard.width, kCVPixelBufferHeightKey as String: standard.height,
            kCVPixelBufferIOSurfacePropertiesKey as String: [:]])
        writer.add(video)
        // Two-track writer readiness can deadlock when a single producer waits
        // on one track while the other needs more samples. Write one video track
        // and recovered PCM independently, then remux without re-encoding.
        let videoURL = output.deletingLastPathComponent().appendingPathComponent(UUID().uuidString+".video.mov")
        let pcm = output.deletingLastPathComponent().appendingPathComponent(UUID().uuidString+".caf")
        // The initial writer was constructed for output; use that URL for its
        // video-only intermediate and move it aside before final remux.
        var audioFileOut: AVAudioFile?
        let audioFormat = AVAudioFormat(standardFormatWithSampleRate: 48000, channels: 1)!
        if audioFile != nil {
            audioFileOut = try AVAudioFile(forWriting: pcm, settings: audioFormat.settings)
        }
        defer {
            audioFileOut = nil
            try? FileManager.default.removeItem(at: videoURL)
            try? FileManager.default.removeItem(at: pcm)
        }
        guard writer.startWriting() else { throw writer.error ?? MobileMediaError.message("输出无法启动。") }
        writer.startSession(atSourceTime: .zero)
        let started = ContinuousClock.now
        do {
            while let frame = try next() {
                try Task.checkCancellation()
                let videoWait = ContinuousClock.now
                while !video.isReadyForMoreMediaData {
                    if Self.seconds(videoWait.duration(to: .now)) > 15 { throw MobileMediaError.message("视频编码等待超时。") }
                    try await Task.sleep(for: .milliseconds(2)); try Self.check(writer)
                }
                var buffer: CVPixelBuffer?
                guard let pool = adaptor.pixelBufferPool,
                      CVPixelBufferPoolCreatePixelBuffer(nil, pool, &buffer) == kCVReturnSuccess, let buffer else {
                    throw MobileMediaError.message("无法分配输出画面。")
                }
                Self.write(frame.frame, to: buffer)
                guard adaptor.append(buffer, withPresentationTime: Self.frameTime(frame.index, standard)) else {
                    throw writer.error ?? MobileMediaError.message("视频写入失败。")
                }
                if let audioFileOut, let samples = frame.audio,
                   let pcmBuffer = AVAudioPCMBuffer(pcmFormat: audioFormat, frameCapacity: AVAudioFrameCount(samples.count)) {
                    pcmBuffer.frameLength = AVAudioFrameCount(samples.count)
                    samples.withUnsafeBufferPointer { pcmBuffer.floatChannelData![0].update(from: $0.baseAddress!, count: samples.count) }
                    try audioFileOut.write(from: pcmBuffer)
                }
                let elapsed = max(1e-9, Self.seconds(started.duration(to: .now)))
                progress(MobileProgress(fraction: Double(frame.index+1)/Double(count), speed: Double(frame.index+1)/standard.frameRate/elapsed))
                await Task.yield()
            }
            video.markAsFinished()
            writer.endSession(atSourceTime: Self.frameTime(count, standard))
            await writer.finishWriting()
            try Task.checkCancellation(); try Self.check(writer)
            guard writer.status == .completed else { throw MobileMediaError.message("输出未完成。") }
            audioFileOut = nil
            if audioFile != nil {
                try FileManager.default.moveItem(at: output, to: videoURL)
                let composition = AVMutableComposition()
                let videoAsset = AVURLAsset(url: videoURL), audioAsset = AVURLAsset(url: pcm)
                let videoTracks = try await videoAsset.loadTracks(withMediaType: .video)
                let audioTracks = try await audioAsset.loadTracks(withMediaType: .audio)
                let range = CMTimeRange(start: .zero, duration: Self.frameTime(count, standard))
                guard let sourceVideo = videoTracks.first, let sourceAudio = audioTracks.first,
                      let targetVideo = composition.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid),
                      let targetAudio = composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid) else {
                    throw MobileMediaError.message("无法封装输出轨道。")
                }
                try targetVideo.insertTimeRange(range, of: sourceVideo, at: .zero)
                try targetAudio.insertTimeRange(range, of: sourceAudio, at: .zero)
                guard let mux = AVAssetExportSession(asset: composition, presetName: AVAssetExportPresetPassthrough) else {
                    throw MobileMediaError.message("无法创建输出封装。")
                }
                mux.outputURL = output; mux.outputFileType = .mov
                await withTaskCancellationHandler(operation: { await mux.export() }, onCancel: { mux.cancelExport() })
                try Task.checkCancellation()
                guard mux.status == .completed else { throw mux.error ?? MobileMediaError.message("封装失败。") }
            }
            return Double(count)/standard.frameRate/max(1e-9, Self.seconds(started.duration(to: .now)))
        } catch {
            if writer.status == .writing { writer.cancelWriting() }
            try? FileManager.default.removeItem(at: output); throw error
        }
    }

    private static func check(_ writer: AVAssetWriter) throws {
        if writer.status == .failed || writer.status == .cancelled { throw writer.error ?? MobileMediaError.message("输出中断。") }
    }
    static func write(_ frame: TVFrame, to buffer: CVPixelBuffer) {
        CVPixelBufferLockBaseAddress(buffer, []); defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        let base = CVPixelBufferGetBaseAddress(buffer)!.assumingMemoryBound(to: UInt8.self)
        let stride = CVPixelBufferGetBytesPerRow(buffer)
        for y in 0..<frame.standard.height { for x in 0..<frame.standard.width {
            let pixel = frame.rgb[y*frame.standard.width+x], offset = y*stride+x*4
            base[offset] = UInt8((max(0,min(1,pixel.z))*255).rounded())
            base[offset+1] = UInt8((max(0,min(1,pixel.y))*255).rounded())
            base[offset+2] = UInt8((max(0,min(1,pixel.x))*255).rounded()); base[offset+3] = 255
        } }
    }
    static func audioSample(_ samples: [Float], start: Int64) throws -> CMSampleBuffer {
        let format = AVAudioFormat(standardFormatWithSampleRate: 48000, channels: 1)!
        var description: CMAudioFormatDescription?
        let status = CMAudioFormatDescriptionCreate(allocator: nil, asbd: format.streamDescription,
            layoutSize: 0, layout: nil, magicCookieSize: 0, magicCookie: nil, extensions: nil, formatDescriptionOut: &description)
        guard status == noErr, let description else { throw MobileMediaError.message("无法创建音频格式。") }
        var block: CMBlockBuffer?
        guard CMBlockBufferCreateWithMemoryBlock(allocator: nil, memoryBlock: nil, blockLength: samples.count*4,
            blockAllocator: nil, customBlockSource: nil, offsetToData: 0, dataLength: samples.count*4,
            flags: 0, blockBufferOut: &block) == noErr, let block else { throw MobileMediaError.message("音频缓冲失败。") }
        let copied = samples.withUnsafeBytes { CMBlockBufferReplaceDataBytes(with: $0.baseAddress!, blockBuffer: block, offsetIntoDestination: 0, dataLength: $0.count) }
        guard copied == noErr else { throw MobileMediaError.message("音频复制失败。") }
        var timing = CMSampleTimingInfo(duration: CMTime(value: 1, timescale: 48000),
            presentationTimeStamp: CMTime(value: start, timescale: 48000), decodeTimeStamp: .invalid)
        var sample: CMSampleBuffer?
        guard CMSampleBufferCreateReady(allocator: nil, dataBuffer: block, formatDescription: description,
            sampleCount: samples.count, sampleTimingEntryCount: 1, sampleTimingArray: &timing,
            sampleSizeEntryCount: 0, sampleSizeArray: nil, sampleBufferOut: &sample) == noErr, let sample else {
            throw MobileMediaError.message("无法创建音频样本。")
        }
        return sample
    }
}

/// Original 24-second test pattern: no pre-baked crosstalk. The middle section
/// has mathematically silent source audio, so recovered buzz is model output.
enum NativeDemo {
    static func make(duration: Double = 24) async throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("AnaLine-demo-"+UUID().uuidString+".mov")
        let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: 320, AVVideoHeightKey: 240])
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: 320, kCVPixelBufferHeightKey as String: 240])
        let audio = AVAssetWriterInput(mediaType: .audio, outputSettings: [AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: 48000, AVNumberOfChannelsKey: 1, AVEncoderBitRateKey: 128000])
        writer.add(input); writer.add(audio)
        guard writer.startWriting() else { throw writer.error ?? MobileMediaError.message("演示生成失败。") }
        writer.startSession(atSourceTime: .zero)
        do {
            let frames = max(1, Int(duration*25))
            for index in 0..<frames {
                try Task.checkCancellation()
                while !input.isReadyForMoreMediaData {
                    if writer.status == .failed { throw writer.error! }
                    try await Task.sleep(for: .milliseconds(2))
                }
                var buffer: CVPixelBuffer?
                guard let pool = adaptor.pixelBufferPool,
                      CVPixelBufferPoolCreatePixelBuffer(nil, pool, &buffer) == kCVReturnSuccess, let buffer else {
                    throw MobileMediaError.message("演示缓冲失败。")
                }
                CVPixelBufferLockBaseAddress(buffer, [])
                let base = CVPixelBufferGetBaseAddress(buffer)!.assumingMemoryBound(to: UInt8.self)
                let stride = CVPixelBufferGetBytesPerRow(buffer)
                let second = index/25, stripes = second >= 8 && (second/2)%2 == 1
                for y in 0..<240 { for x in 0..<320 {
                    let value: UInt8 = stripes ? (y%4 < 2 ? 230 : 20) : 128
                    let p = y*stride+x*4
                    base[p] = value; base[p+1] = value; base[p+2] = value; base[p+3] = 255
                } }
                CVPixelBufferUnlockBaseAddress(buffer, [])
                guard adaptor.append(buffer, withPresentationTime: CMTime(value: Int64(index), timescale: 25)) else { throw writer.error! }
                while !audio.isReadyForMoreMediaData {
                    if writer.status == .failed { throw writer.error! }
                    try await Task.sleep(for: .milliseconds(2))
                }
                let sounding = (second < 8 || second >= 16) && second%2 == 0
                let samples = (0..<1920).map { n in sounding ? Float(0.25*sin(2 * Double.pi * 900 * Double(index*1920+n)/48000)) : 0 }
                guard audio.append(try MobileMedia.audioSample(samples, start: Int64(index*1920))) else { throw writer.error! }
                await Task.yield()
            }
            input.markAsFinished(); audio.markAsFinished(); await writer.finishWriting()
            guard writer.status == .completed else { throw writer.error ?? MobileMediaError.message("演示生成未完成。") }
            return url
        } catch { writer.cancelWriting(); try? FileManager.default.removeItem(at: url); throw error }
    }
}

/// Launch with --validate-initial-app for a reproducible native-media smoke test.
/// It runs only when explicitly requested, never during normal app launch.
enum MobileValidation {
    /// The 4:3 window only, for both standards, in a few seconds: what each chosen
    /// window hands to the chain, and whether the automatic fit really letterboxes
    /// where a chosen crop fills. Written to Documents/crop-validation.json and
    /// printed so it can be read from `devicectl ... process launch --console`.
    static func cropReport() async -> String {
        var checks: [String] = []
        let source = try? await NativeDemo.make(duration: 0.48)
        if let source {
            defer { try? FileManager.default.removeItem(at: source) }
            let choices: [(String, MobileCrop?)] = [("自动信箱", nil), ("4:3 取景", .full),
                                                   ("旋转90°", MobileCrop(quarterTurns: 1)),
                                                   ("放大偏移", MobileCrop(center: CGPoint(x: 0.3, y: 0.35), zoom: 0.5))]
            for standard in TVStandard.allCases {
                var settings = TerrestrialSettings(system: TerrestrialSystem(video: standard))
                settings.performance = .mobile
                for (name, crop) in choices {
                    let media = MobileMedia()
                    do {
                        _ = try await media.load(source, standard: standard, settings: settings) { _ in }
                        try await media.configure(standard: standard, settings: settings, at: 0, crop: crop)
                        guard let frame = try await media.next() else { throw MobileMediaError.message("没有画面。") }
                        let line = "\(standard.rawValue) 取景·\(name)：\(describe(frame.original))"
                        checks.append(line); print("CROPCHECK " + line)
                    } catch {
                        let line = "\(standard.rawValue) 取景·\(name)：失败 \(error.localizedDescription)"
                        checks.append(line); print("CROPCHECK " + line)
                    }
                    await media.close()
                }
            }
        } else {
            checks.append("无法生成演示视频。")
        }
        let report = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("crop-validation.json")
        let payload: [String: Any] = ["checks": checks, "passed": checks.count == TVStandard.allCases.count*4
                                      && !checks.contains { $0.contains("失败") }]
        if let data = try? JSONSerialization.data(withJSONObject: payload, options: .prettyPrinted) {
            try? data.write(to: report, options: .atomic)
        }
        print("CROPCHECK done passed=\(payload["passed"] ?? false)")
        return checks.joined(separator: "\n")
    }

    /// What the picture handed to the chain looks like: how much of each border is
    /// black (a letterboxed fit leaves bands, a 4:3 crop does not) plus a coarse
    /// nine-tile brightness signature, so a different window is visibly different.
    static func describe(_ image: UIImage) -> String {
        guard let cg = image.cgImage, let provider = cg.dataProvider, let data = provider.data as Data? else {
            return "无图像"
        }
        let width = cg.width, height = cg.height, bytes = cg.bitsPerPixel/8, row = cg.bytesPerRow
        var band = [Int](repeating: 0, count: 4), black = [Int](repeating: 0, count: 4)
        var sum = [Double](repeating: 0, count: 9), count = [Double](repeating: 0, count: 9)
        let edgeY = max(1, height/12), edgeX = max(1, width/12)
        for y in stride(from: 0, to: height, by: max(1, height/96)) {
            for x in stride(from: 0, to: width, by: max(1, width/96)) {
                let offset = y*row + x*bytes
                guard offset+2 < data.count else { continue }
                let level = Double(Int(data[offset]) + Int(data[offset+1]) + Int(data[offset+2]))/3
                let dark = level < 24
                let sides = [(y < edgeY, 0), (y >= height-edgeY, 1), (x < edgeX, 2), (x >= width-edgeX, 3)]
                for (inside, index) in sides where inside { band[index] += 1; if dark { black[index] += 1 } }
                let tile = min(2, x*3/width)*3 + min(2, y*3/height)
                sum[tile] += level; count[tile] += 1
            }
        }
        func percent(_ index: Int) -> String { String(format: "%.0f%%", Double(black[index])*100/Double(max(1, band[index]))) }
        let tiles = (0..<9).map { String(Int(sum[$0]/max(1, count[$0]))) }.joined(separator: " ")
        return "\(width)x\(height) 上/下 \(percent(0))/\(percent(1)) 左/右 \(percent(2))/\(percent(3)) 九宫格[\(tiles)]"
    }

    static func run() async -> String {
        let report = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("initial-app-validation.json")
        var checks: [String] = []
        let initial = try? JSONSerialization.data(withJSONObject: ["passed": false, "inProgress": true], options: .prettyPrinted)
        try? initial?.write(to: report, options: .atomic)
        do {
            let source = try await NativeDemo.make(duration: 0.48)
            defer { try? FileManager.default.removeItem(at: source) }
            for standard in TVStandard.allCases {
                for fast in [false, true] {
                    let media = MobileMedia()
                    var settings = TerrestrialSettings(system: TerrestrialSystem(video: standard))
                    settings.performance = fast ? .mobile : .full
                    let duration = try await media.load(source, standard: standard, settings: settings) { _ in }
                    guard let first = try await media.next(), first.index == 0,
                          first.audio?.count == TVSoundClock.count(frame: 0, standard: standard),
                          first.simulated.size.width == CGFloat(standard.width) else {
                        throw MobileMediaError.message("首帧／伴音验证失败。")
                    }
                    let sourceBytes = first.original.cgImage!.dataProvider!.data! as Data
                    let sourcePeak = stride(from: 0, to: sourceBytes.count, by: 4).map { sourceBytes[$0] }.max() ?? 0
                    let mean = first.frame.rgb.reduce(Float(0)) { $0 + $1.x } / Float(first.frame.rgb.count)
                    guard sourcePeak > 32, mean > 0.1 else {
                        throw MobileMediaError.message("画面内容验证失败：源峰值 \(sourcePeak)，模拟均值 \(mean)。")
                    }
                    // The 4:3 window: a chosen crop must fill the frame instead of
                    // leaving bars, and each different window must change the
                    // picture the chain receives.
                    for (name, crop) in [("自动信箱", MobileCrop?.none), ("4:3 取景", .full),
                                         ("旋转90°", MobileCrop(quarterTurns: 1)),
                                         ("放大偏移", MobileCrop(center: CGPoint(x: 0.3, y: 0.35), zoom: 0.5))] {
                        let probe = MobileMedia()
                        _ = try await probe.load(source, standard: standard, settings: settings) { _ in }
                        try await probe.configure(standard: standard, settings: settings, at: 0, crop: crop)
                        guard let view = try await probe.next() else { throw MobileMediaError.message("取景验证：没有画面。") }
                        checks.append("\(standard.rawValue) 取景·\(name)：\(describe(view.original))")
                        await probe.close()
                    }
                    try await media.configure(standard: standard, settings: settings, at: 3/standard.frameRate)
                    guard let seek = try await media.next(), seek.index == 3 else { throw MobileMediaError.message("Seek 验证失败。") }
                    let destination = source.deletingLastPathComponent().appendingPathComponent(UUID().uuidString+".mov")
                    _ = try await media.export(to: destination) { _ in }
                    let output = AVURLAsset(url: destination)
                    let video = try await output.loadTracks(withMediaType: .video)
                    let audio = try await output.loadTracks(withMediaType: .audio)
                    let outputDuration = try await output.load(.duration)
                    guard video.count == 1, audio.count == 1,
                          abs(outputDuration.seconds-duration) <= standard.frameDuration+0.01 else {
                        throw MobileMediaError.message("输出轨道／时长验证失败。")
                    }
                    let reader = try AVAssetReader(asset: output)
                    let decoded = AVAssetReaderTrackOutput(track: video[0], outputSettings: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA])
                    reader.add(decoded); reader.startReading()
                    var frames = 0
                    while let sample = decoded.copyNextSampleBuffer() {
                        if CMSampleBufferGetImageBuffer(sample) != nil { frames += 1 }
                    }
                    guard frames == Int((duration*standard.frameRate+1e-7).rounded(.down)) else {
                        throw MobileMediaError.message("输出帧数验证失败：\(frames)。")
                    }
                    let cancelledURL = destination.deletingLastPathComponent().appendingPathComponent(UUID().uuidString+".mov")
                    let cancelled = Task { try await media.export(to: cancelledURL) { _ in } }
                    cancelled.cancel()
                    do { _ = try await cancelled.value; throw MobileMediaError.message("取消未生效。") }
                    catch is CancellationError { }
                    guard !FileManager.default.fileExists(atPath: cancelledURL.path) else { throw MobileMediaError.message("取消后残留输出。") }
                    let session = MobileSession(mediaName: "fixture.mov", standard: standard, settings: settings, position: 0.1, muted: true)
                    let restored = try JSONDecoder().decode(MobileSession.self, from: JSONEncoder().encode(session))
                    guard restored.settings == settings, restored.standard == standard else { throw MobileMediaError.message("会话还原失败。") }
                    checks.append("\(standard.rawValue) \(fast ? "Fast" : "Full"): pixel-content/import/audio/seek/export/frame-count/cancel/session")
                    try? FileManager.default.removeItem(at: destination)
                    await media.close()
                }
            }
            if let source = Bundle.main.url(forResource: "crosstalk-source", withExtension: "mov") {
                let media = MobileMedia()
                var settings = TerrestrialSettings(system: .ntscM); settings.performance = .mobile
                let duration = try await media.load(source, standard: .ntsc, settings: settings) { _ in }
                try await media.configure(standard: .ntsc, settings: settings, at: 8.5)
                guard let visible = try await media.next() else { throw MobileMediaError.message("演示没有画面。") }
                let bytes = visible.original.cgImage!.dataProvider!.data! as Data
                guard stride(from: 0, to: bytes.count, by: 4).contains(where: { bytes[$0] > 32 }) else {
                    throw MobileMediaError.message("演示解码为黑帧。")
                }
                let destination = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString+".mov")
                _ = try await media.export(to: destination) { _ in }
                let asset = AVURLAsset(url: destination)
                let time = try await asset.load(.duration)
                guard abs(time.seconds-duration) < TVStandard.ntsc.frameDuration+0.01 else {
                    throw MobileMediaError.message("完整演示输出时长不正确。")
                }
                await media.close(); try? FileManager.default.removeItem(at: destination)
                checks.append("24-second bundled demo: complete native import/export")
            }
            let data = try JSONSerialization.data(withJSONObject: ["passed": true, "checks": checks], options: .prettyPrinted)
            try data.write(to: report, options: .atomic)
            return "原生链路验证通过：\(checks.count) 组。"
        } catch {
            let data = try? JSONSerialization.data(withJSONObject: ["passed": false, "checks": checks, "error": error.localizedDescription], options: .prettyPrinted)
            try? data?.write(to: report, options: .atomic)
            return "验证失败："+error.localizedDescription
        }
    }
}
