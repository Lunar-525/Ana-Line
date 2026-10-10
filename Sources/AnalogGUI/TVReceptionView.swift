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
    init(model: PreviewModel) { self.model = model }
    @State private var sound = false
    var body: some View {
        HStack(alignment: .top,spacing: 10) {
            TVReceptionReadout(model: model).frame(width: 142)
            VStack(spacing: 4) {
                HStack(spacing: 4) {
                    Text(L("RX spectrum / waterfall"))
                        .font(.system(size: 9,weight: .semibold,design: .monospaced)).lineLimit(1)
                    Spacer(minLength: 2)
                    Button("VSB") { sound = false }.buttonStyle(SpectrumTabStyle(selected: !sound))
                    Button("FM") { sound = true }.buttonStyle(SpectrumTabStyle(selected: sound))
                }.foregroundStyle(TVInstrumentPalette.ink)
                TVSpectrumPlot(history: sound ? model.tvSoundSpectrum : model.tvVisionSpectrum,
                    fallbackRate: sound ? 384_000 : model.tvStandard.sampleRate,
                    fallbackCenter: sound ? model.terrestrialSystem.soundCarrierHz : 0,
                    tuning: TVSpectrumTuning(offsetHz: Double(model.tvChannel.tuningOffsetKHz)*1000,
                        bandwidthHz: Double(model.tvChannel.rfBandwidthMHz)*1e6,
                        carrierHz: sound ? model.terrestrialSystem.soundCarrierHz : 0),
                    noAudio: sound && !model.tvHasAudio,
                    onTuningChange: { next in
                        var channel = model.tvChannel
                        channel.tuningOffsetKHz = Float(next.offsetHz/1000)
                        channel.rfBandwidthMHz = Float(next.bandwidthHz/1e6)
                        if channel != model.tvChannel { model.tvChannel = channel }
                    })
            }.frame(maxWidth: .infinity,maxHeight: .infinity)
        }.padding(.horizontal,23).padding(.vertical,10).frame(height: 174)
            .background(TVRackHousing(finish: .transmitter))
            .environment(\.colorScheme,.dark)
    }
}

private enum TVInstrumentPalette {
    static let screen = Color(red: 0.016,green: 0.028,blue: 0.03)
    static let ink = Color(red: 0.79,green: 0.88,blue: 0.84)
    static let muted = Color(red: 0.46,green: 0.57,blue: 0.54)
    static let amber = Color(red: 0.9,green: 0.77,blue: 0.4)
}

/// Only this readout observes receiver telemetry; rack controls stay static.
private struct TVReceptionReadout: View {
    @ObservedObject var model: PreviewModel
    @ObservedObject var state: TVReceptionState
    init(model: PreviewModel) { self.model = model; state = model.tvReceptionState }
    private var active: Bool { model.tvDuration > 0 && !model.tvPreparing }
    var body: some View {
        VStack(alignment: .leading,spacing: 8) {
            Text(L("Reception")).font(.system(size: 9,weight: .semibold,design: .monospaced))
                .foregroundStyle(TVInstrumentPalette.ink)
            HStack(spacing: 10) {
                syncLight("H",label: "H Sync",state: state.synchronization.horizontal)
                syncLight("V",label: "V Sync",state: state.synchronization.vertical)
                syncLight("COLOR",label: "Color Sync",state: state.synchronization.color)
            }
            VStack(spacing: 5) {
                metric(L("Receiver lock"),model.tvLockDescription)
                metric("AGC",String(format: "%+.1f dB",state.agcDB))
                metric(L("Carrier error"),String(format: "%+.0f Hz",state.carrierErrorHz))
                metric(L("Sync confidence"),String(format: "%.0f%%",state.syncConfidence*100))
                metric(L("Recovered lines"),"\(state.recoveredLines) / \(model.tvStandard.height)")
                metric(L("FM sound"),model.tvHasAudio ? String(format: "%.1f dB",state.soundCarrierDB) : L("No audio track"))
            }.padding(8).frame(maxWidth: .infinity,maxHeight: .infinity)
                .background(TVInstrumentPalette.screen)
                .overlay(Rectangle().stroke(.black,lineWidth: 2))
                .overlay(Rectangle().stroke(.white.opacity(0.06),lineWidth: 0.5).padding(1))
        }.frame(maxHeight: .infinity)
    }
    private func metric(_ label: String,_ value: String) -> some View {
        HStack(spacing: 3) {
            Text(label).foregroundStyle(TVInstrumentPalette.muted)
            Spacer(minLength: 2)
            Text(active ? value : "—").monospacedDigit().foregroundStyle(TVInstrumentPalette.ink)
        }.font(.system(size: 8,design: .monospaced)).lineLimit(1).minimumScaleFactor(0.8)
            .help("\(label) · \(active ? value : L("No signal"))")
    }
    private func syncLight(_ title: String,label: String,state: TelevisionLock) -> some View {
        let color: Color = !active ? Color(white: 0.2) : state == .locked ? .green : state == .holding ? .orange : .red
        let status = !active ? L("No signal") : state == .locked ? L("Locked") : state == .holding ? L("Sync holdover") : L("Acquiring sync")
        return HStack(spacing: 4) {
            Circle().fill(.black).frame(width: 9,height: 9)
                .overlay(Circle().fill(RadialGradient(colors: [color.opacity(0.9),color.opacity(0.45)],center: .topLeading,startRadius: 0,endRadius: 7)).padding(1))
                .overlay(Circle().stroke(.white.opacity(0.16),lineWidth: 0.5))
                .shadow(color: color.opacity(active ? 0.35 : 0),radius: 2)
            Text(title).font(.system(size: 7,weight: .medium,design: .monospaced)).foregroundStyle(TVInstrumentPalette.muted)
        }.help("\(label) · \(status)")
            .accessibilityElement(children: .ignore).accessibilityLabel(label).accessibilityValue(status)
    }
}

private struct SpectrumTabStyle: ButtonStyle {
    let selected: Bool
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.font(.system(size: 8,weight: .semibold,design: .monospaced))
            .foregroundStyle(selected ? .black : TVInstrumentPalette.muted)
            .padding(.horizontal,7).frame(height: 16)
            .background(selected ? TVInstrumentPalette.amber : Color(white: configuration.isPressed ? 0.14 : 0.045))
            .overlay(Rectangle().stroke(.white.opacity(0.12),lineWidth: 0.5))
    }
}

/// Both branches share the asymmetric VSB IF: -1.25 MHz to bandwidth-1.25 MHz
/// around the tuned vision reference. FM shows a fixed slice around its carrier.
struct TVSpectrumTuning {
    let offsetHz: Double, bandwidthHz: Double, carrierHz: Double
    var indicatorHz: Double { carrierHz + offsetHz }
    var lowerHz: Double { offsetHz - 1_250_000 }
    var upperHz: Double { lowerHz + bandwidthHz }
}

private struct TVSpectrumPlot: View {
    @ObservedObject var history: TVSpectrumHistory
    let fallbackRate: Double, fallbackCenter: Double
    let tuning: TVSpectrumTuning
    let noAudio: Bool
    let onTuningChange: (TVSpectrumTuning) -> Void
    private var rate: Double { history.spectrum?.sampleRate ?? fallbackRate }
    private var center: Double { history.spectrum?.centerHz ?? fallbackCenter }
    var body: some View {
        VStack(spacing: 3) {
            HStack {
                Text("RX · MHz")
                Spacer()
                Text(String(format: "IF %.2f MHz", tuning.bandwidthHz/1e6))
                    .foregroundStyle(TVInstrumentPalette.ink)
                Spacer()
                Text(history.spectrum.map { String(format: "RBW %.2f kHz", $0.resolutionHz/1000) } ?? "dBFS/bin")
            }.font(.system(size: 8,design: .monospaced)).foregroundStyle(TVInstrumentPalette.muted).lineLimit(1)
            GeometryReader { g in
                let traceHeight: CGFloat = 32
                let axisCenter = center, axisRate = rate
                ZStack(alignment: .topLeading) {
                    TVInstrumentPalette.screen
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
                        var trace = Path()
                        for (index, db) in history.trace.enumerated() {
                            let point = CGPoint(x: size.width*(CGFloat(index)+0.5)/CGFloat(history.trace.count),
                                y: traceHeight*(1-CGFloat(min(0,max(-100,db))+100)/100))
                            if index == 0 { trace.move(to: point) } else { trace.addLine(to: point) }
                        }
                        context.stroke(trace, with: .color(EditingTool.tv.logoAccentColor), lineWidth: 2)
                        var separator = Path(); separator.move(to: CGPoint(x: 0,y: traceHeight)); separator.addLine(to: CGPoint(x: size.width,y: traceHeight))
                        context.stroke(separator, with: .color(.white.opacity(0.3)), lineWidth: 0.5)
                    }
                    // A single LCD face covers the waveform and history. OSD
                    // labels are drawn above it so the small type stays legible.
                    TVLCDSurface()
                    Canvas { context, size in
                        func x(_ hz: Double) -> CGFloat { CGFloat((hz-axisCenter)/axisRate + 0.5)*size.width }
                        let left = x(tuning.lowerHz), right = x(tuning.upperHz)
                        let visibleLeft = max(0,left), visibleRight = min(size.width,right)
                        if visibleRight > visibleLeft {
                            context.fill(Path(CGRect(x: visibleLeft,y: 0,
                                width: visibleRight-visibleLeft,height: size.height)),
                                with: .color(TVInstrumentPalette.ink.opacity(0.045)))
                            // SDR passband bracket; caps appear only at actual
                            // edges, so a cropped FM view does not imply a narrow IF.
                            var bracket = Path()
                            bracket.move(to: CGPoint(x: visibleLeft,y: 6))
                            bracket.addLine(to: CGPoint(x: visibleRight,y: 6))
                            for edge in [left,right] where edge >= 0 && edge <= size.width {
                                bracket.move(to: CGPoint(x: edge,y: 6))
                                bracket.addLine(to: CGPoint(x: edge,y: 13))
                            }
                            context.stroke(bracket,with: .color(TVInstrumentPalette.ink.opacity(0.85)),lineWidth: 1)
                        }
                        let markerX = x(tuning.indicatorHz)
                        if markerX >= 0 && markerX <= size.width {
                            var marker = Path()
                            marker.move(to: CGPoint(x: markerX,y: 13))
                            marker.addLine(to: CGPoint(x: markerX,y: size.height))
                            context.stroke(marker,with: .color(TVInstrumentPalette.amber),
                                style: StrokeStyle(lineWidth: 1,dash: [3,3]))
                            var pointer = Path()
                            pointer.move(to: CGPoint(x: markerX-3,y: 1))
                            pointer.addLine(to: CGPoint(x: markerX+3,y: 1))
                            pointer.addLine(to: CGPoint(x: markerX,y: 6))
                            pointer.closeSubpath()
                            context.fill(pointer,with: .color(TVInstrumentPalette.amber))
                        }
                    }.allowsHitTesting(false)
                    if history.image == nil {
                        Text(noAudio ? L("No audio track") : L("Waiting for RX samples"))
                            .font(.system(size: 9,design: .monospaced)).foregroundStyle(TVInstrumentPalette.muted)
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
                    TVSpectrumDragSurface(tuning: tuning,centerHz: axisCenter,sampleRate: axisRate,
                        onChange: onTuningChange)
                }.clipped().overlay(Rectangle().stroke(.black,lineWidth: 2))
                    .overlay(Rectangle().stroke(.white.opacity(0.07),lineWidth: 0.5).padding(1))
            }
            HStack {
                ForEach(0...4, id: \.self) { tick in
                    if tick > 0 { Spacer(minLength: 0) }
                    Text(String(format: "%+.3f", (center + (Double(tick)/4-0.5)*rate)/1e6))
                }
            }.font(.system(size: 8, design: .monospaced)).foregroundStyle(TVInstrumentPalette.muted)
            HStack(spacing: 4) {
                Text("−100")
                LinearGradient(colors: [Color(red: 2/255, green: 4/255, blue: 10/255), Color(red: 15/255, green: 36/255, blue: 94/255), Color(red: 16/255, green: 150/255, blue: 181/255), Color(red: 232/255, green: 198/255, blue: 88/255), Color(red: 1, green: 1, blue: 239/255)], startPoint: .leading, endPoint: .trailing)
                    .frame(width: 54, height: 4).border(.black.opacity(0.5))
                Text("0 dBFS/bin"); Spacer()
                Text("↓ 10 s").help(L("Newest at top · 10 s history"))
            }.font(.system(size: 7,design: .monospaced)).foregroundStyle(TVInstrumentPalette.muted)
        }.accessibilityElement(children: .ignore)
            .help(L("Received RF before tuning, IF filtering and AGC. Dashed line: tuning position. Bracket: shared IF passband. Frequencies relative to the transmitted vision carrier. Fixed color scale; blank rows have no measurement."))
            .accessibilityLabel(L("RX spectrum / waterfall"))
            .accessibilityValue(history.image == nil ? L("Waiting for RX samples") : String(format: "%.2f s · RBW %.2f kHz", history.latestTime ?? 0, (history.spectrum?.resolutionHz ?? 0)/1000))
    }
}

/// A cached RGB subpixel mask is tiled by the compositor. No per-measurement
/// bitmap filtering or animation is needed; multiply keeps empty rows black.
private struct TVLCDSurface: View {
    @Environment(\.displayScale) private var displayScale
    var body: some View {
        Rectangle().fill(ImagePaint(image: Image(decorative: Self.mask,scale: 8).interpolation(.none)))
            .blendMode(.multiply)
            .overlay {
                Rectangle().strokeBorder(.black.opacity(0.22),lineWidth: 1 / max(1,displayScale))
            }
            .allowsHitTesting(false).accessibilityHidden(true)
    }
    private static let mask: CGImage = {
        let width = 24, height = 24
        let subpixels: [[UInt8]] = [[255,218,208],[208,255,218],[208,218,255]]
        var pixels = [UInt8](repeating: 255,count: width*height*4)
        for y in 0..<height {
            for x in 0..<width {
                // Keep the 3 pt cell pitch, widening the dim matrix gaps
                // from 0.5 pt to 0.625 pt without enlarging the pixels.
                let shade = (x%8 >= 3 ? 0.55 : 1) * (y >= height-5 ? 0.45 : 1)
                for channel in 0..<3 {
                    pixels[(y*width+x)*4+channel] = UInt8(Double(subpixels[x/8][channel])*shade)
                }
            }
        }
        let provider = CGDataProvider(data: Data(pixels) as CFData)!
        return CGImage(width: width,height: height,bitsPerComponent: 8,bitsPerPixel: 32,
            bytesPerRow: width*4,space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
            provider: provider,decode: nil,shouldInterpolate: false,intent: .defaultIntent)!
    }()
}
