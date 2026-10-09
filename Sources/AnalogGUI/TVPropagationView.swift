import SwiftUI
import AnalogCore

struct TVPropagationView: View {
    @ObservedObject var model: TVControlState
    init(model: PreviewModel) {
        model.tvControlState.bind(model)
        self.model = model.tvControlState
    }
    private var scene: TVPropagationSettings { model.tvChannel.propagation }
    private var report: TVPropagationReport { TVPropagationModel.evaluate(scene) }
    var body: some View {
        VStack(spacing: 10) {
            HStack {
                Text("02 · \(L("Propagation"))").font(.system(size: 12,weight: .semibold))
                Toggle(L("Enable scene"),isOn: $model.tvChannel.propagation.enabled)
                Spacer()
                Text(L("2D elevation profile · height exaggerated")).foregroundStyle(.black.opacity(0.5))
                Toggle(L("Ridge"),isOn: $model.tvChannel.propagation.ridgeEnabled)
                Toggle(L("Enable weather"),isOn: $model.tvChannel.propagation.weather.enabled)
            }.font(.system(size: 11)).toggleStyle(.checkbox)
            HStack(alignment: .top,spacing: 20) {
                VStack(spacing: 7) {
                    Picker(L("Antenna"),selection: Binding(get: { scene.antenna },set: {
                        model.tvChannel.propagation.antenna = $0
                        model.tvChannel.propagation.antennaGainDB = $0.nominalGainDB
                    })) {
                        ForEach(TVAntennaKind.allCases,id: \.self) { Text(L($0.rawValue)).tag($0) }
                    }.pickerStyle(.menu).tint(.black)
                    HStack {
                        Text(L("Gain")); Slider(value: $model.tvChannel.propagation.antennaGainDB,in: -5...25)
                        Text(String(format: "%.1f dBi",scene.antennaGainDB)).monospacedDigit().fixedSize()
                    }
                    HStack {
                        field("Distance",unit: "km",value: $model.tvChannel.propagation.distanceKm,range: 3...50)
                        field("Elevation",unit: "°",value: $model.tvChannel.propagation.antennaElevationDegrees,range: -90...90)
                    }
                    HStack {
                        field("TX height",unit: "m",value: $model.tvChannel.propagation.transmitterHeightM,range: 20...300)
                        field("RX height",unit: "m",value: $model.tvChannel.propagation.receiverHeightM,range: 2...150)
                    }
                    HStack {
                        field("Carrier",unit: "MHz",value: $model.tvChannel.propagation.frequencyMHz,range: 50...860)
                        field("Refraction",unit: "k",value: $model.tvChannel.propagation.refractionK,range: 0.65...4)
                    }
                    Text(L("Sub-GHz rain and fog absorption is small. Weather also changes surface loss, clutter and the assumed refractivity gradient; lightning adds RF impulses."))
                        .font(.system(size: 10)).foregroundStyle(.black.opacity(0.5))
                        .fixedSize(horizontal: false,vertical: true).padding(.top,12)
                }.font(.system(size: 11)).controlSize(.small).frame(width: 260)
                VStack(spacing: 0) {
                    TVWeatherScene(weather: $model.tvChannel.propagation.weather,sceneEnabled: scene.enabled)
                        .frame(height: 196)
                    TVPropagationDiagram(settings: $model.tvChannel.propagation).frame(height: 230)
                }
            }
            HStack(alignment: .top,spacing: 16) {
                TVPathControls(state: model).frame(maxWidth: .infinity)
                TVRFControls(state: model).frame(maxWidth: .infinity)
            }
            HStack(spacing: 18) {
                metric("Free-space loss",report.spaceLossDB)
                metric("Diffraction",report.diffractionLossDB)
                metric("Direction loss",report.antennaLossDB)
                metric("Weather loss",report.weatherLossDB)
                Spacer(minLength: 0)
                Text(scene.enabled ? String(format: "%@ %+.1f dB",L("Link relative"),report.relativeGainDB) : L("Scene bypassed"))
                    .monospacedDigit()
            }.font(.system(size: 10)).foregroundStyle(.black.opacity(0.55))
        }.padding(14).foregroundStyle(.black)
            .background(Rectangle().fill(.white).shadow(color: .black.opacity(0.35),radius: 5,y: 2))
            .environment(\.colorScheme,.light).groupBoxStyle(TVParameterGroupStyle()).tint(EditingTool.tv.logoAccentColor)
            .disabled(model.busy)
    }
    private func metric(_ label: String, _ value: Double) -> some View {
        HStack(spacing: 5) {
            Text(L(label)); Text(String(format: "%.2f dB",value)).foregroundStyle(.black).monospacedDigit()
        }.fixedSize()
    }
    private func field(_ name: String,unit: String,value: Binding<Float>,range: ClosedRange<Float>) -> some View {
        HStack(spacing: 3) {
            Text(L(name)).lineLimit(1)
            TextField("",value: Binding(get: {value.wrappedValue},set: {
                if $0.isFinite { value.wrappedValue = min(range.upperBound,max(range.lowerBound,$0)) }
            }),format: .number.precision(.fractionLength(0...2)))
                .textFieldStyle(.plain).multilineTextAlignment(.trailing)
                .padding(.vertical,3).frame(minWidth: 28)
                .background(.black.opacity(0.04))
                .accessibilityLabel("\(L(name)) · \(unit)")
            Text(unit).foregroundStyle(.black.opacity(0.5))
        }.frame(maxWidth: .infinity)
    }
}

private struct TVSceneGeometry {
    let size: CGSize, settings: TVPropagationSettings, report: TVPropagationReport
    let heightScale: Double
    init(size: CGSize,settings: TVPropagationSettings,frozenScale: Double? = nil) {
        self.size = size; self.settings = settings; report = TVPropagationModel.evaluate(settings)
        heightScale = frozenScale ?? max(260,Double(settings.transmitterHeightM)+50,
            settings.ridgeEnabled ? Double(settings.ridgeHeightM)+80 : 0)
    }
    var left: Double { 90 }
    var right: Double { Double(size.width)-28 }
    var top: Double { 94 }
    var bottom: Double { Double(size.height)-26 }
    var distance: Double { Double(settings.distanceKm)*1000 }
    func x(_ metres: Double) -> Double { left+metres/50_000*(right-left) }
    func y(_ metres: Double) -> Double { bottom-metres/heightScale*(bottom-top) }
    func metresX(_ point: Double) -> Double { (point-left)/(right-left)*50_000 }
    func metresY(_ point: Double) -> Double { (bottom-point)/(bottom-top)*heightScale }
    func ground(_ metres: Double) -> Double { metres*(distance-metres)/(2*report.refractionK*TVPropagationModel.earthRadiusM) }
    var receiver: CGPoint { CGPoint(x: x(distance),y: y(Double(settings.receiverHeightM))) }
    var ridgeX: Double { distance*Double(settings.ridgePosition) }
    var ridge: CGPoint { CGPoint(x: x(ridgeX),y: y(Double(settings.ridgeHeightM)+ground(ridgeX))) }
}

struct TVPropagationDiagram: View {
    @Binding var settings: TVPropagationSettings
    @State private var dragScale: Double?
    @State private var receiverStart: CGPoint?
    @State private var ridgeStart: CGPoint?
    var body: some View {
        GeometryReader { proxy in
            let g = TVSceneGeometry(size: proxy.size,settings: settings,frozenScale: dragScale)
            ZStack(alignment: .topLeading) {
                Canvas { context,size in draw(context: &context,geometry: g) }
                TVWeatherAtmosphere(weather: settings.weather,sceneEnabled: settings.enabled)
                    .allowsHitTesting(false).accessibilityHidden(true)
                TVWeatherSkyElement(element: .sunlight,weather: $settings.weather,sceneEnabled: settings.enabled)
                    .frame(width: 80,height: 74).position(x: g.right-16,y: 54)
                // The mast moves the receiving antenna itself, not a separate knob.
                Canvas { context,size in
                    let groundY = g.bottom-g.receiver.y
                    var mast = Path(); mast.move(to: CGPoint(x: 14,y: 0)); mast.addLine(to: CGPoint(x: 14,y: groundY))
                    context.stroke(mast,with: .color(.black),lineWidth: 2)
                    var foot = Path(); foot.move(to: CGPoint(x: 7,y: groundY)); foot.addLine(to: CGPoint(x: 21,y: groundY))
                    context.stroke(foot,with: .color(.black),lineWidth: 2)
                }
                .frame(width: 28,height: max(24,g.bottom-g.receiver.y))
                .contentShape(Rectangle()).position(x: g.receiver.x,y: g.receiver.y+max(24,g.bottom-g.receiver.y)/2)
                .gesture(DragGesture(coordinateSpace: .named("tv-propagation"))
                    .onChanged { value in
                        if receiverStart == nil { receiverStart = g.receiver; dragScale = g.heightScale }
                        let point = receiverStart! + value.translation
                        settings.distanceKm = Float(min(50,max(3,g.metresX(point.x)/1000)))
                        settings.receiverHeightM = Float(min(150,max(2,g.metresY(point.y))))
                    }.onEnded { _ in receiverStart = nil; dragScale = nil })
                .help(L("Drag the antenna mast to change distance and height"))
                .accessibilityLabel(L("Receiving antenna position"))
                .accessibilityValue(String(format: "%.1f km · %.1f m",settings.distanceKm,settings.receiverHeightM))
                .accessibilityAdjustableAction { direction in
                    settings.distanceKm = min(50,max(3,settings.distanceKm+(direction == .increment ? 0.5 : -0.5)))
                }
                TVAntennaDrawing(kind: settings.antenna)
                    .frame(width: 78,height: 40).contentShape(TVAntennaHitArea())
                    .rotationEffect(.degrees(-Double(settings.antennaElevationDegrees)),anchor: .trailing)
                    .position(x: g.receiver.x-39,y: g.receiver.y)
                    .gesture(DragGesture(minimumDistance: 2,coordinateSpace: .named("tv-propagation"))
                        .onChanged { value in
                            let angle = atan2(g.receiver.y-value.location.y,g.receiver.x-value.location.x)*180/Double.pi
                            settings.antennaElevationDegrees = Float(min(90,max(-90,angle)))
                        })
                    .help(L("Drag the antenna elements to rotate its elevation"))
                    .accessibilityLabel(L("Antenna elevation"))
                    .accessibilityValue(String(format: "%.1f°",settings.antennaElevationDegrees))
                    .accessibilityAdjustableAction { direction in
                        settings.antennaElevationDegrees = min(90,max(-90,settings.antennaElevationDegrees+(direction == .increment ? 1 : -1)))
                    }
                if settings.ridgeEnabled {
                    Circle().fill(.black).frame(width: 6,height: 6)
                        .frame(width: 28,height: 28).contentShape(Rectangle())
                        .position(g.ridge)
                        .gesture(DragGesture(coordinateSpace: .named("tv-propagation"))
                            .onChanged { value in
                                if ridgeStart == nil { ridgeStart = g.ridge; dragScale = g.heightScale }
                                let point = ridgeStart! + value.translation
                                let x = min(g.distance*0.9,max(g.distance*0.1,g.metresX(point.x)))
                                settings.ridgePosition = Float(x/g.distance)
                                settings.ridgeHeightM = Float(min(500,max(0,g.metresY(point.y)-g.ground(x))))
                            }.onEnded { _ in ridgeStart = nil; dragScale = nil })
                        .help(L("Drag the ridge to change its height and position"))
                        .accessibilityLabel(L("Ridge position and height"))
                }
            }.coordinateSpace(name: "tv-propagation").clipped()
                .accessibilityElement(children: .contain)
                .accessibilityLabel(L("Propagation profile"))
        }
    }
    private func draw(context: inout GraphicsContext,geometry g: TVSceneGeometry) {
        let s = g.settings, accent = EditingTool.tv.logoAccentColor
        for tick in [0,10,20,30,40,50] {
            let x = g.x(Double(tick)*1000)
            var grid = Path(); grid.move(to: CGPoint(x: x,y: g.top)); grid.addLine(to: CGPoint(x: x,y: g.bottom))
            context.stroke(grid,with: .color(.black.opacity(0.07)),lineWidth: 0.5)
            context.draw(Text("\(tick) km").font(.system(size: 9)).foregroundColor(.gray),at: CGPoint(x: x,y: g.bottom+16))
        }
        let tx = CGPoint(x: g.x(0),y: g.y(Double(s.transmitterHeightM))), rx = g.receiver
        let lambda = 299_792_458/(Double(s.frequencyMHz)*1e6)
        var terrain = Path(), upper = [CGPoint](),lower = [CGPoint]()
        for n in 0...100 {
            let d = g.distance*Double(n)/100
            let width = min(5000,g.distance*0.18)
            let hill = s.ridgeEnabled ? Double(s.ridgeHeightM)*max(0,1-abs(d-g.ridgeX)/width) : 0
            let point = CGPoint(x: g.x(d),y: g.y(g.ground(d)+hill))
            if n == 0 { terrain.move(to: point) } else { terrain.addLine(to: point) }
            let line = Double(s.transmitterHeightM)+(Double(s.receiverHeightM)-Double(s.transmitterHeightM))*d/g.distance
            let fresnel = sqrt(max(0,lambda*d*(g.distance-d)/g.distance))
            upper.append(CGPoint(x: g.x(d),y: g.y(line+fresnel)))
            lower.append(CGPoint(x: g.x(d),y: g.y(line-fresnel)))
        }
        terrain.addLine(to: CGPoint(x: rx.x,y: g.bottom)); terrain.addLine(to: CGPoint(x: tx.x,y: g.bottom)); terrain.closeSubpath()
        context.fill(terrain,with: .color(Color(white: 0.91)))
        context.stroke(terrain,with: .color(.black.opacity(0.35)),lineWidth: 0.7)
        var fresnel = Path(); fresnel.addLines(upper+Array(lower.reversed())); fresnel.closeSubpath()
        context.fill(fresnel,with: .color(accent.opacity(0.17)))
        var direct = Path(); direct.move(to: tx); direct.addLine(to: rx)
        context.stroke(direct,with: .color(.black.opacity(0.35)),style: StrokeStyle(lineWidth: 0.7,dash: [3,3]))
        var signal = Path(); signal.move(to: tx)
        if g.report.ridgeClearanceM < 0 {
            signal.addLine(to: CGPoint(x: g.x(g.report.diffractionPointDistanceM),y: g.y(g.report.obstructionHeightM)))
        }
        signal.addLine(to: rx)
        context.stroke(signal,with: .color(accent),lineWidth: 2)
        var tower = Path(); tower.move(to: CGPoint(x: tx.x-5,y: g.bottom)); tower.addLine(to: tx); tower.addLine(to: CGPoint(x: tx.x+5,y: g.bottom))
        context.stroke(tower,with: .color(.black),lineWidth: 1.5)
        context.draw(Text("TX").font(.system(size: 10)),at: CGPoint(x: tx.x+12,y: tx.y-8))
        context.draw(Text("RX").font(.system(size: 10)),at: CGPoint(x: rx.x+13,y: rx.y-8))
        if s.ridgeEnabled {
            context.draw(Text(String(format: "%@ %.0f m",L("Ridge"),s.ridgeHeightM)).font(.system(size: 10)),
                at: CGPoint(x: min(g.right-35,max(g.left+35,g.ridge.x)),y: max(8,g.ridge.y-14)))
        }
        context.draw(Text(String(format: "k %.2f · %@",g.report.refractionK,L("Fresnel zone"))).font(.system(size: 9)).foregroundColor(.gray),
            at: CGPoint(x: g.right,y: 6),anchor: .topTrailing)
        context.draw(Text(L("Drag mast: move · elements: rotate")).font(.system(size: 9)).foregroundColor(.gray),
            at: CGPoint(x: 0,y: 6),anchor: .topLeading)
    }
}

/// Leave the antenna's mast end available to the translation gesture even
/// when the drawn mast is shorter than the elements' surrounding hit region.
private struct TVAntennaHitArea: Shape {
    func path(in rect: CGRect) -> Path {
        Path(CGRect(x: rect.minX,y: rect.minY,width: max(0,rect.width-12),height: rect.height))
    }
}

private struct TVAntennaDrawing: View {
    let kind: TVAntennaKind
    var body: some View {
        Canvas { context,size in
            var p = Path()
            let mid = size.height/2, end = size.width
            p.move(to: CGPoint(x: 8,y: mid)); p.addLine(to: CGPoint(x: end,y: mid))
            switch kind {
            case .dipole:
                p.move(to: CGPoint(x: end-12,y: 3)); p.addLine(to: CGPoint(x: end-12,y: size.height-3))
            case .yagi,.logPeriodic:
                for n in 0..<5 {
                    let x = CGFloat(n)*13+12
                    let half = kind == .yagi ? CGFloat(8+n*2) : CGFloat(4+n*3)
                    p.move(to: CGPoint(x: x,y: mid-half)); p.addLine(to: CGPoint(x: x,y: mid+half))
                }
            case .bowTie:
                for cy: CGFloat in [11,29] {
                    p.move(to: CGPoint(x: 24,y: cy-7)); p.addLine(to: CGPoint(x: 55,y: cy+7)); p.addLine(to: CGPoint(x: 55,y: cy-7)); p.addLine(to: CGPoint(x: 24,y: cy+7)); p.closeSubpath()
                }
                p.move(to: CGPoint(x: end-8,y: 2)); p.addLine(to: CGPoint(x: end-8,y: size.height-2))
            }
            context.stroke(p,with: .color(.black),lineWidth: 1.8)
        }
    }
}

private extension CGPoint {
    static func + (point: CGPoint,size: CGSize) -> CGPoint { CGPoint(x: point.x+size.width,y: point.y+size.height) }
}
