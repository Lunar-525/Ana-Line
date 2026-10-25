import Foundation
@preconcurrency import AVFoundation

/// Decodes an imported file to the 48 kHz mono PCM the radio scene expects.
/// Shared by the transmitter source importer; there is no offline export path.
enum RadioAudioFile {
    static let maximumSeconds = 300.0
    static func read(_ url: URL) throws -> [Float] {
        let file = try AVAudioFile(forReading: url)
        guard file.length > 0,
              file.length <= AVAudioFramePosition(file.processingFormat.sampleRate*maximumSeconds),
              let input = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length)),
              let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 48_000, channels: 1, interleaved: false),
              let converter = AVAudioConverter(from: file.processingFormat, to: format),
              let output = AVAudioPCMBuffer(pcmFormat: format,
                frameCapacity: AVAudioFrameCount(Double(file.length)*48_000/file.processingFormat.sampleRate+1024))
        else { throw RadioImportError.invalidAudio }
        try file.read(into: input)
        var supplied = false, error: NSError?
        let result = converter.convert(to: output, error: &error) { _, state in
            if supplied { state.pointee = .endOfStream; return nil }
            supplied = true; state.pointee = .haveData; return input
        }
        if let error { throw error }
        guard result != .error, output.frameLength > 0, let samples = output.floatChannelData?[0] else {
            throw RadioImportError.invalidAudio
        }
        return Array(UnsafeBufferPointer(start: samples, count: Int(output.frameLength)))
    }
}

enum RadioImportError: LocalizedError {
    case invalidAudio
    var errorDescription: String? { "请选择不超过 5 分钟的有效音频。" }
}
