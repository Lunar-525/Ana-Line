import SwiftUI
import AnalogCore

/// Wideband RF at one receiver's front end: every transmitter in the scene, both
/// receivers' tuning positions, and the bracket showing what the selected
/// receiver is passing. Zoom crops the raster instead of magnifying pixels.
@MainActor
struct RadioSceneEnvironmentPanel: View {
    @ObservedObject var model: RadioSceneModel
    @State private var zoomIndex = 0
    @State private var centerHz = 0.0
    static let zooms: [Double] = [1,2,4,8]
    private var zoom: Double { Self.zooms[min(zoomIndex,Self.zooms.count-1)] }
    private var span: Double { RadioSceneSettings.sampleRate/zoom }
    var body: some View {
        VStack(alignment: .leading,spacing: 8) {
            HStack(spacing: 8) {
                Text("无线电环境 · RF 全景").font(.system(size: 10,weight: .bold,design: .monospaced))
                Spacer(minLength: 4)
                if model.settings.receivers.count > 1 {
                    RadioSelectionStrip(options: model.settings.receivers.map(\.id),selection: receiverSelection,
                        label: { id in "RX \((model.settings.receivers.firstIndex { $0.id == id } ?? 0)+1)" },height: 22)
                        .frame(width: 118).accessibilityLabel("环境瀑布图对应的接收机")
                }
                RadioSelectionStrip(options: Array(Self.zooms.indices),selection: $zoomIndex,
                    label: { "×\(Int(Self.zooms[$0]))" },height: 22)
                    .frame(width: 132).accessibilityLabel("环境瀑布图缩放")
            }
            if let id = model.environmentReceiverID, let rx = model.settings.receivers.first(where: { $0.id == id }) {
                Text(info(rx)).font(.system(size: 8,design: .monospaced))
                    .foregroundStyle(TVInstrumentPalette.muted).lineLimit(1).minimumScaleFactor(0.8)
                RadioEnvironmentWaterfall(model: model,display: model.rxDisplay(id),span: span,centerHz: $centerHz)
                    .frame(height: 208)
            } else {
                Text("添加 RX 后可查看共享 RF 环境。").font(.system(size: 10))
                    .foregroundStyle(TVInstrumentPalette.muted).frame(maxWidth: .infinity,maxHeight: .infinity)
            }
            HStack(spacing: 8) {
                Text("T1–T8 载波").foregroundStyle(TVInstrumentPalette.muted)
                Text("R1 / R2 调谐与 IF").foregroundStyle(EditingTool.radio.logoAccentColor)
                Spacer(minLength: 4)
                Text("拖动平移").foregroundStyle(TVInstrumentPalette.muted)
            }.font(.system(size: 7,design: .monospaced)).lineLimit(1)
        }.padding(10).frame(maxHeight: .infinity,alignment: .top).modifier(RadioPanelSurface())
            .onChange(of: zoomIndex) { _ in clampCenter() }
    }
    private var receiverSelection: Binding<UUID> {
        Binding(get: { model.environmentReceiverID ?? model.settings.receivers.first?.id ?? UUID() },
            set: { model.environmentRX = $0 })
    }
    private func clampCenter() {
        let half = span/2
        centerHz = min(RadioSceneSettings.sampleRate/2-half,max(-RadioSceneSettings.sampleRate/2+half,centerHz))
    }
    private func info(_ rx: RadioSceneRX) -> String {
        let index = (model.settings.receivers.firstIndex { $0.id == rx.id } ?? 0)+1
        return "RX \(index) · \(rx.enabled ? "开" : "关") · 位置 \(String(format: "%.1f",rx.positionKm)) km"
            + " · 调谐 \(String(format: "%+.1f",rx.tuningHz/1000)) kHz · \(rx.mode.rawValue)"
    }
}

@MainActor
private struct RadioEnvironmentWaterfall: View {
    @ObservedObject var model: RadioSceneModel
    @ObservedObject var display: RadioSceneRXDisplay
    let span: Double
    @Binding var centerHz: Double
    @State private var dragCenter: Double?
    private let accent = EditingTool.radio.logoAccentColor
    var body: some View {
        VStack(spacing: 3) {
            GeometryReader { geometry in
                let traceHeight: CGFloat = 32, limit = RadioSceneSettings.sampleRate/2
                let center = centerHz, half = min(limit,span/2)
                let lower = max(-limit,center-half), upper = min(limit,center+half)
                ZStack(alignment: .topLeading) {
                    TVInstrumentPalette.screen
                    if let image = display.environmentHistory.croppedImage(lowerHz: lower,upperHz: upper) {
                        Image(decorative: image,scale: 1).resizable().interpolation(.none)
                            .frame(width: geometry.size.width,height: max(1,geometry.size.height-traceHeight))
                            .offset(y: traceHeight)
                    }
                    Canvas { context,size in
                        for tick in 0...4 {
                            let column = size.width*CGFloat(tick)/4
                            var grid = Path()
                            grid.move(to: CGPoint(x: column,y: 0)); grid.addLine(to: CGPoint(x: column,y: size.height))
                            context.stroke(grid,with: .color(.white.opacity(0.12)),lineWidth: 0.5)
                        }
                        let trace = display.environmentHistory.trace
                        if trace.count > 1 {
                            let range = display.environmentHistory.columnRange(lowerHz: lower,upperHz: upper)
                            let low = Int((range.lowerBound*Double(trace.count)).rounded(.down))
                            let high = Int((range.upperBound*Double(trace.count)).rounded(.up))
                            let columns = max(2,Int(size.width))
                            var path = Path()
                            for column in 0..<columns {
                                let index = min(trace.count-1,max(0,low+(high-low)*column/(columns-1)))
                                let point = CGPoint(x: size.width*CGFloat(column)/CGFloat(columns-1),
                                    y: traceHeight*(1-CGFloat(min(0,max(-100,trace[index]))+100)/100))
                                if column == 0 { path.move(to: point) } else { path.addLine(to: point) }
                            }
                            context.stroke(path,with: .color(accent),lineWidth: 2)
                        }
                        var separator = Path()
                        separator.move(to: CGPoint(x: 0,y: traceHeight)); separator.addLine(to: CGPoint(x: size.width,y: traceHeight))
                        context.stroke(separator,with: .color(.white.opacity(0.3)),lineWidth: 0.5)
                    }
                    TVLCDSurface()
                    Canvas { context,size in
                        RadioSceneMarkerOverlay.draw(&context,
                            geometry: .init(center: center,span: max(1,upper-lower),size: size,traceHeight: traceHeight),
                            transmitters: model.settings.transmitters,receivers: model.settings.receivers,
                            owner: model.environmentReceiverID)
                    }.allowsHitTesting(false)
                    if display.environmentHistory.image == nil {
                        Text("等待接收样本").font(.system(size: 9,design: .monospaced))
                            .foregroundStyle(TVInstrumentPalette.muted).frame(maxWidth: .infinity,maxHeight: .infinity)
                    }
                    VStack(alignment: .leading) { Text("0 dB"); Spacer(); Text("−100 dB") }
                        .font(.system(size: 8,design: .monospaced)).foregroundStyle(.white.opacity(0.7))
                        .padding(3).frame(height: traceHeight)
                    VStack(alignment: .trailing) { Text("现在"); Spacer(); Text("−10 s") }
                        .font(.system(size: 8,design: .monospaced)).foregroundStyle(.white.opacity(0.7))
                        .padding(3).frame(width: geometry.size.width,height: max(1,geometry.size.height-traceHeight),alignment: .trailing)
                        .offset(y: traceHeight)
                    Rectangle().fill(.clear).contentShape(Rectangle()).frame(width: geometry.size.width,height: geometry.size.height)
                        .gesture(DragGesture(minimumDistance: 0).onChanged { value in
                            guard half < limit-1 else { return }
                            if dragCenter == nil { dragCenter = center }
                            let moved = (dragCenter ?? center)+(value.translation.width/geometry.size.width)*span
                            centerHz = min(limit-half,max(-limit+half,moved))
                        }.onEnded { _ in dragCenter = nil })
                }.clipped().overlay(Rectangle().stroke(.black,lineWidth: 2))
                    .overlay(Rectangle().stroke(.white.opacity(0.07),lineWidth: 0.5).padding(1))
            }
            HStack(spacing: 0) {
                ForEach(0...4,id: \.self) { tick in
                    if tick > 0 { Spacer(minLength: 0) }
                    Text(String(format: "%+.1f",(centerHz-span/2+span*Double(tick)/4)/1000))
                }
            }.font(.system(size: 8,design: .monospaced)).foregroundStyle(TVInstrumentPalette.muted).lineLimit(1)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("无线电环境瀑布图")
        .accessibilityValue(display.environmentHistory.image == nil ? "等待接收样本"
            : String(format: "±%.0f kHz · RBW %.2f kHz",span/2000,(display.environmentHistory.spectrum?.resolutionHz ?? 0)/1000))
        .help("接收机前端在调谐前的宽带 RF：包含全部发射台载波、噪声与过载。括号为该接收机的 IF / 边带，虚线为其调谐位置。拖动平移，右上角选择缩放倍率。")
    }
}
