import SwiftUI
import AnalogCore
import CoreGraphics

/// Fixed 100 ms time buckets, newest at the top. Missing measurements remain
/// black; pause replaces the current row instead of inventing elapsed time.
@MainActor
final class TVSpectrumHistory: ObservableObject {
    static let width = 512, height = 100
    private var pixels = [UInt8](repeating: 0, count: width * height * 4)
    private(set) var image: CGImage?
    private(set) var spectrum: TVSpectrum?
    private(set) var trace = [Float]()
    private(set) var latestTime: Double?
    private var bucket: Int?
    private static let palette: [[UInt8]] = (0...255).map { index in
        let stops: [(Float, SIMD3<Float>)] = [
            (0, SIMD3(2,4,10)), (0.25, SIMD3(15,36,94)),
            (0.5, SIMD3(16,150,181)), (0.75, SIMD3(232,198,88)), (1, SIMD3(255,255,239))]
        let x = Float(index)/255
        let j = min(3, Int(x*4)), a = stops[j], b = stops[j+1]
        let rgb = a.1 + (b.1-a.1)*((x-a.0)/(b.0-a.0))
        return [UInt8(rgb.x), UInt8(rgb.y), UInt8(rgb.z), 255]
    }
    func reset() {
        objectWillChange.send()
        pixels = .init(repeating: 0, count: Self.width * Self.height * 4)
        image = nil; spectrum = nil; trace = []; latestTime = nil; bucket = nil
    }
    func update(_ measurement: TVSpectrum?, time: Double) {
        guard let measurement, !measurement.powerDB.isEmpty else { return }
        if let previous = spectrum,
           previous.sampleRate != measurement.sampleRate || previous.centerHz != measurement.centerHz {
            reset()
        }
        let current = Int(floor(time*10 + 1e-7))
        if let previous = bucket, current < previous || current-previous >= Self.height {
            reset()
        }
        objectWillChange.send()
        let shift = min(Self.height, max(0, current-(bucket ?? current)))
        let stride = Self.width*4
        if shift > 0 {
            // Copy backwards to move history down without overlapping writes.
            let amount = shift*stride
            if amount < pixels.count {
                for n in (amount..<pixels.count).reversed() { pixels[n] = pixels[n-amount] }
            }
            for n in 0..<amount { pixels[n] = 0 }
        }
        trace = (0..<Self.width).map { x in
            let lo = x*measurement.powerDB.count/Self.width
            let hi = max(lo+1, (x+1)*measurement.powerDB.count/Self.width)
            return measurement.powerDB[lo..<min(hi,measurement.powerDB.count)].max() ?? -120
        }
        for x in trace.indices {
            let color = Self.palette[Int(min(255, max(0, (trace[x]+100)*2.55)))]
            for c in 0..<4 { pixels[x*4+c] = color[c] }
        }
        let data = Data(pixels) as CFData
        if let provider = CGDataProvider(data: data) {
            image = CGImage(width: Self.width, height: Self.height, bitsPerComponent: 8,
                bitsPerPixel: 32, bytesPerRow: stride, space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)
        }
        spectrum = measurement; latestTime = time; bucket = current
    }
}

struct TVReceptionView: View {
    @ObservedObject var model: PreviewModel
    @ObservedObject var state: TVReceptionState
    init(model: PreviewModel) { self.model = model; state = model.tvReceptionState }
    @State private var sound = false
    private var active: Bool { model.tvDuration > 0 && !model.tvPreparing }
    var body: some View {
        HStack(alignment: .top, spacing: 20) {
            VStack(alignment: .leading, spacing: 10) {
                Text(L("Reception")).font(.system(size: 12, weight: .semibold))
                HStack(spacing: 14) {
                    syncLight("H Sync", state: model.tvSynchronization.horizontal)
                    syncLight("V Sync", state: model.tvSynchronization.vertical)
                    syncLight("Color Sync", state: model.tvSynchronization.color)
                }.padding(.bottom, 2)
                metric(L("Receiver lock"), model.tvLockDescription)
                metric("AGC", String(format: "%+.1f dB", model.tvAGCDB))
                metric(L("Carrier error"), String(format: "%+.0f Hz", model.tvCarrierErrorHz))
                metric(L("Sync confidence"), String(format: "%.0f%%", model.tvSyncConfidence*100))
                metric(L("Recovered lines"), "\(model.tvRecoveredLines) / \(model.tvStandard.height)")
                metric(L("FM sound"), model.tvHasAudio ? String(format: "%.1f dB", model.tvSoundCarrierDB) : L("No audio track"))
            }.frame(width: 260)
            Rectangle().fill(.black.opacity(0.12)).frame(width: 1)
            VStack(spacing: 5) {
                HStack {
                    Text(L("RX spectrum / waterfall")).font(.system(size: 12, weight: .semibold))
                    Spacer()
                    Button("VSB") { sound = false }.buttonStyle(SpectrumTabStyle(selected: !sound))
                    Button("FM") { sound = true }.buttonStyle(SpectrumTabStyle(selected: sound))
                }
                TVSpectrumPlot(history: sound ? model.tvSoundSpectrum : model.tvVisionSpectrum,
                    fallbackRate: sound ? 384_000 : model.tvStandard.sampleRate,
                    fallbackCenter: sound ? model.terrestrialSystem.soundCarrierHz-Double(model.tvChannel.tuningOffsetKHz)*1000 : 0,
                    carrierHz: sound ? model.terrestrialSystem.soundCarrierHz-Double(model.tvChannel.tuningOffsetKHz)*1000 : -Double(model.tvChannel.tuningOffsetKHz)*1000,
                    noAudio: sound && !model.tvHasAudio)
            }.frame(maxWidth: .infinity)
        }
        .foregroundStyle(.black).padding(14).frame(height: 218)
        .background(Rectangle().fill(.white).shadow(color: .black.opacity(0.35), radius: 5, y: 2))
    }
    private func metric(_ label: String, _ value: String) -> some View {
        HStack { Text(label).foregroundStyle(.black.opacity(0.55)); Spacer(); Text(active ? value : "—").monospacedDigit() }
            .font(.system(size: 11))
    }
    private func syncLight(_ label: String, state: TelevisionLock) -> some View {
        let color: Color = !active ? .gray : state == .locked ? .green : state == .holding ? .orange : .red
        let status = !active ? L("No signal") : state == .locked ? L("Locked") : state == .holding ? L("Sync holdover") : L("Acquiring sync")
        return HStack(spacing: 5) {
            Circle().fill(color).frame(width: 8, height: 8)
                .shadow(color: color.opacity(active ? 0.4 : 0), radius: 3)
            Text(label).font(.system(size: 10)).fixedSize()
        }.help("\(label) · \(status)")
            .accessibilityElement(children: .ignore).accessibilityLabel(label).accessibilityValue(status)
    }
}

private struct SpectrumTabStyle: ButtonStyle {
    let selected: Bool
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.font(.system(size: 10, weight: .semibold))
            .padding(.horizontal, 10).padding(.vertical, 3)
            .background(selected ? EditingTool.tv.logoAccentColor : .black.opacity(configuration.isPressed ? 0.15 : 0.06))
    }
}

private struct TVSpectrumPlot: View {
    @ObservedObject var history: TVSpectrumHistory
    let fallbackRate: Double, fallbackCenter: Double, carrierHz: Double
    let noAudio: Bool
    private var rate: Double { history.spectrum?.sampleRate ?? fallbackRate }
    private var center: Double { history.spectrum?.centerHz ?? fallbackCenter }
    var body: some View {
        VStack(spacing: 3) {
            HStack {
                Text(L("Pre-AGC · relative to tuner · MHz"))
                Spacer()
                Text(history.spectrum.map { String(format: "RBW %.2f kHz · dBFS/bin", $0.resolutionHz/1000) } ?? "dBFS/bin")
            }.font(.system(size: 9)).foregroundStyle(.black.opacity(0.55)).lineLimit(1)
            GeometryReader { g in
                let traceHeight: CGFloat = 42
                ZStack(alignment: .topLeading) {
                    Color(red: 0.008, green: 0.016, blue: 0.04)
                    if let image = history.image {
                        Image(decorative: image, scale: 1).resizable().interpolation(.none)
                            .frame(width: g.size.width, height: g.size.height-traceHeight)
                            .offset(y: traceHeight)
                    }
                    Canvas { context, size in
                        for tick in 0...4 {
                            let x = size.width*CGFloat(tick)/4
                            var grid = Path(); grid.move(to: CGPoint(x: x, y: 0)); grid.addLine(to: CGPoint(x: x, y: size.height))
                            context.stroke(grid, with: .color(.white.opacity(0.12)), lineWidth: 0.5)
                        }
                        let carrierX = CGFloat((carrierHz-center)/rate + 0.5)*size.width
                        if carrierX >= 0 && carrierX <= size.width {
                            var marker = Path(); marker.move(to: CGPoint(x: carrierX, y: 0)); marker.addLine(to: CGPoint(x: carrierX, y: size.height))
                            context.stroke(marker, with: .color(.white.opacity(0.45)), style: StrokeStyle(lineWidth: 0.7, dash: [3,3]))
                        }
                        var trace = Path()
                        for (index, db) in history.trace.enumerated() {
                            let point = CGPoint(x: size.width*(CGFloat(index)+0.5)/CGFloat(history.trace.count),
                                y: traceHeight*(1-CGFloat(min(0,max(-100,db))+100)/100))
                            if index == 0 { trace.move(to: point) } else { trace.addLine(to: point) }
                        }
                        context.stroke(trace, with: .color(EditingTool.tv.logoAccentColor), lineWidth: 1)
                        var separator = Path(); separator.move(to: CGPoint(x: 0,y: traceHeight)); separator.addLine(to: CGPoint(x: size.width,y: traceHeight))
                        context.stroke(separator, with: .color(.white.opacity(0.3)), lineWidth: 0.5)
                    }
                    if history.image == nil {
                        Text(noAudio ? L("No audio track") : L("Waiting for RX samples"))
                            .font(.caption).foregroundStyle(.white.opacity(0.55))
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                    VStack(alignment: .leading) {
                        Text("0 dB"); Spacer(); Text("−100 dB")
                    }.font(.system(size: 8, design: .monospaced)).foregroundStyle(.white.opacity(0.7))
                        .padding(3).frame(height: traceHeight)
                    VStack(alignment: .trailing) {
                        Text(L("Now")); Spacer(); Text("−10 s")
                    }.font(.system(size: 8, design: .monospaced)).foregroundStyle(.white.opacity(0.7))
                        .padding(3).frame(width: g.size.width, height: g.size.height-traceHeight, alignment: .trailing).offset(y: traceHeight)
                }.clipped()
            }
            HStack {
                ForEach(0...4, id: \.self) { tick in
                    if tick > 0 { Spacer(minLength: 0) }
                    Text(String(format: "%+.3f", (center + (Double(tick)/4-0.5)*rate)/1e6))
                }
            }.font(.system(size: 9, design: .monospaced)).foregroundStyle(.black.opacity(0.65))
            HStack(spacing: 8) {
                Text("−100")
                LinearGradient(colors: [Color(red: 2/255, green: 4/255, blue: 10/255), Color(red: 15/255, green: 36/255, blue: 94/255), Color(red: 16/255, green: 150/255, blue: 181/255), Color(red: 232/255, green: 198/255, blue: 88/255), Color(red: 1, green: 1, blue: 239/255)], startPoint: .leading, endPoint: .trailing)
                    .frame(width: 92, height: 5).border(.black.opacity(0.1))
                Text("0 dBFS/bin"); Spacer()
                Text(L("Newest at top · 10 s history"))
            }.font(.system(size: 8)).foregroundStyle(.black.opacity(0.55))
        }.accessibilityElement(children: .ignore)
            .help(L("Measured after tuning / RF front-end filtering, before AGC and demodulation. Dashed line: nominal carrier. Fixed color scale; blank rows have no measurement."))
            .accessibilityLabel(L("RX spectrum / waterfall"))
            .accessibilityValue(history.image == nil ? L("Waiting for RX samples") : String(format: "%.2f s · RBW %.2f kHz", history.latestTime ?? 0, (history.spectrum?.resolutionHz ?? 0)/1000))
    }
}
