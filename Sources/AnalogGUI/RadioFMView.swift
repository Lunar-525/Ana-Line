import SwiftUI
import AppKit
import AVFoundation
import AnalogCore

@MainActor
struct RadioFMView: View {
    @State private var settings = FMSettings()
    @State private var source: [Float] = []
    @State private var received: [Float] = []
    @State private var status = "导入音频或生成测试音，然后运行 FM 收发。"
    @State private var busy = false
    @State private var player: AVAudioPlayer?
    @State private var playbackURL: URL?
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("Radio · 单声道 FM").font(.title2)
            Text("48 kHz PCM → 384 kHz IQ → 信道 → 调谐 / IF → FM 鉴频 → PCM")
                .foregroundStyle(.secondary)
            HStack {
                Button("导入音频", action: load)
                Button("生成 1 kHz 测试音") {
                    source = (0..<144_000).map { Float(0.15*sin(2 * Double.pi * 1000 * Double($0)/48_000)) }
                    received = []; status = "已生成 3 秒测试音。"
                }
                Button("运行 FM 收发", action: run).disabled(source.isEmpty)
                if busy { ProgressView().controlSize(.small) }
            }.disabled(busy)
            HStack {
                Text("峰值频偏 (Hz)")
                TextField("", value: $settings.deviationHz, format: .number).frame(width: 110)
                Text("调谐偏移 (Hz)")
                TextField("", value: $settings.tuningOffsetHz, format: .number).frame(width: 110)
                Picker("预加重 / 去加重", selection: $settings.emphasisSeconds) {
                    Text("关闭").tag(0.0); Text("50 µs").tag(50e-6); Text("75 µs").tag(75e-6)
                }.frame(width: 220)
            }.disabled(busy)
            HStack {
                Text("IQ 噪声")
                Slider(value: $settings.noiseAmplitude, in: 0...1).frame(width: 250)
                Text(settings.noiseAmplitude, format: .number.precision(.fractionLength(2)))
            }.disabled(busy)
            Text(status).textSelection(.enabled)
            HStack {
                Button("试听接收音频", action: play).disabled(received.isEmpty || busy)
                Button("停止") { player?.stop() }
                Button("导出接收 WAV", action: export).disabled(received.isEmpty || busy)
            }
            Spacer()
        }.padding(24).frame(maxWidth: .infinity, minHeight: 360, alignment: .topLeading)
            .onDisappear {
                player?.stop(); player = nil
                if let playbackURL { try? FileManager.default.removeItem(at: playbackURL) }
            }
    }
    private func load() {
        let panel = NSOpenPanel(); panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let file = try AVAudioFile(forReading: url)
            guard file.length > 0, file.length <= AVAudioFramePosition(file.processingFormat.sampleRate * 300),
                  let input = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length)),
                  let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 48_000, channels: 1, interleaved: false),
                  let converter = AVAudioConverter(from: file.processingFormat, to: format),
                  let output = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(Double(file.length)*48_000/file.processingFormat.sampleRate + 1024))
            else { status = "请选择不超过 5 分钟的音频。"; return }
            try file.read(into: input)
            var supplied = false
            var error: NSError?
            let result = converter.convert(to: output, error: &error) { _, state in
                if supplied { state.pointee = .endOfStream; return nil }
                supplied = true; state.pointee = .haveData; return input
            }
            if let error { throw error }
            guard result != .error, let samples = output.floatChannelData?[0] else { status = "音频转换失败。"; return }
            source = Array(UnsafeBufferPointer(start: samples, count: Int(output.frameLength)))
            received = []; status = "已导入 \(url.lastPathComponent)，\(source.count) 个单声道样本。"
        } catch { status = error.localizedDescription }
    }
    private func run() {
        busy = true; player?.stop()
        let pcm = source, config = settings
        Task {
            do {
                let result = try await Task.detached(priority: .userInitiated) {
                    var engine = try FMEngine(settings: config)
                    var output: [Float] = [], limited = false
                    for start in stride(from: 0, to: pcm.count, by: 2048) {
                        output += try engine.process(Array(pcm[start..<min(pcm.count, start+2048)]))
                        limited = limited || engine.transmitter.limited
                    }
                    return (output, limited)
                }.value
                received = result.0
                status = "收发完成：\(received.count) 个样本。" + (result.1 ? " 发射端出现过频偏限幅。" : "")
            } catch { received = []; status = "FM 收发失败：\(error)" }
            busy = false
        }
    }
    private func write(_ url: URL) throws {
        let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 48_000, channels: 1, interleaved: false)!
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(received.count))!
        buffer.frameLength = buffer.frameCapacity
        for n in received.indices { buffer.floatChannelData![0][n] = received[n] }
        let file = try AVAudioFile(forWriting: url, settings: format.settings)
        try file.write(from: buffer)
    }
    private func play() {
        do {
            player?.stop(); player = nil
            if let playbackURL { try? FileManager.default.removeItem(at: playbackURL) }
            let url = FileManager.default.temporaryDirectory.appendingPathComponent("AnaLine-FM-\(UUID().uuidString).wav")
            playbackURL = url; try write(url)
            player = try AVAudioPlayer(contentsOf: url); player?.play()
        } catch { status = error.localizedDescription }
    }
    private func export() {
        let panel = NSSavePanel(); panel.nameFieldStringValue = "FM-received.wav"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do { try write(url); status = "已导出 \(url.lastPathComponent)。" }
        catch { status = error.localizedDescription }
    }
}
