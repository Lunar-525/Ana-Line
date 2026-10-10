import SwiftUI
import AnalogCore

struct TVPropagationView: View {
    @ObservedObject var model: TVControlState
    let lightning: TVLightningState
    init(model: PreviewModel) {
        model.tvControlState.bind(model)
        self.model = model.tvControlState
        lightning = model.tvLightningState
    }
    var body: some View {
        VStack(spacing: 8) {
            HStack {
                Text(L("Propagation")).font(.system(size: 12, weight: .semibold))
                Spacer()
                Button { model.setPropagationEnabled(!model.tvChannel.propagation.enabled) } label: {
                    Image(systemName: "power")
                        .foregroundStyle(model.tvChannel.propagation.enabled ? TVPropagationPalette.accent : TVPropagationPalette.muted)
                }
                .help(L("Enable scene"))
                .accessibilityLabel(L("Enable scene"))
                .accessibilityValue(model.tvChannel.propagation.enabled ? L("Normal") : L("Scene bypassed"))
                Button {
                    model.setPropagationEnabled(true)
                    var reset = TVPropagationSettings(); reset.enabled = true
                    reset.frequencyMHz = model.tvChannel.propagation.frequencyMHz
                    model.tvChannel.propagation = reset
                    model.tvChannel.echoGain = 0
                    model.tvChannel.echoDelayMicroseconds = 3
                    model.tvChannel.echoPhaseDegrees = 0
                } label: { Image(systemName: "arrow.counterclockwise") }
                .help(L("Reset propagation"))
                .accessibilityLabel(L("Reset propagation"))
            }.buttonStyle(.plain).font(.system(size: 12))
            TVPropagationDiagram(settings: $model.tvChannel.propagation,lightning: lightning,
                echoGain: Binding(get: { model.sceneEchoGain },set: { model.setSceneEchoGain($0) }), echoDelay: $model.tvChannel.echoDelayMicroseconds,
                echoPhase: $model.tvChannel.echoPhaseDegrees)
        }.padding(12).foregroundStyle(TVPropagationPalette.ink)
            .background(Rectangle().fill(TVPropagationPalette.panel).shadow(color: .black.opacity(0.4),radius: 5,y: 2))
            .overlay { Rectangle().stroke(TVPropagationPalette.ink.opacity(0.08),lineWidth: 1).allowsHitTesting(false) }
            .overlay {
                TVLightningPanelFlash(state: lightning,enabled: model.tvChannel.propagation.enabled &&
                    model.tvChannel.propagation.weather.enabled && model.tvChannel.propagation.weather.lightning > 0 &&
                    model.tvChannel.propagation.weather.lightningRatePerMinute > 0)
            }
            .environment(\.colorScheme,.dark).tint(TVPropagationPalette.accent)
            .disabled(model.busy)
    }
}

struct TVSceneGeometry {
    let size: CGSize, settings: TVPropagationSettings, report: TVPropagationReport
    let heightScale: Double, span: Double
    init(size: CGSize,settings: TVPropagationSettings,frozenScale: Double? = nil,frozenSpan: Double? = nil) {
        self.size = size; self.settings = settings; report = TVPropagationModel.evaluate(settings)
        heightScale = frozenScale ?? max(300,Double(settings.transmitterHeightM)+65,
            settings.ridgeEnabled ? Double(settings.ridgeHeightM)+100 : 0)
        span = frozenSpan ?? max(8_000,Double(settings.distanceKm)*1100)
    }
    var activeWeather: [TVWeatherElement] {
        [.rain,.snow,.fog,.lightning,.ionization,.clutter].filter {
            settings.weather.enabled && settings.weather[keyPath: $0.keyPath] > 0
        }
    }
    var left: Double { 36 }
    var right: Double { max(left+180,Double(size.width)-24) }
    var top: Double { activeWeather.count > 3 ? 168 : activeWeather.isEmpty ? 76 : 120 }
    var bottom: Double { Double(size.height)-28 }
    var distance: Double { Double(settings.distanceKm)*1000 }
    func x(_ metres: Double) -> Double { left+metres/span*(right-left) }
    func y(_ metres: Double) -> Double { bottom-metres/heightScale*(bottom-top) }
    func metresX(_ point: Double) -> Double { (point-left)/(right-left)*span }
    func metresY(_ point: Double) -> Double { (bottom-point)/(bottom-top)*heightScale }
    func ground(_ metres: Double) -> Double { metres*(distance-metres)/(2*report.refractionK*TVPropagationModel.earthRadiusM) }
    var transmitter: CGPoint { CGPoint(x: x(0),y: y(Double(settings.transmitterHeightM))) }
    var receiver: CGPoint { CGPoint(x: x(distance),y: y(Double(settings.receiverHeightM))) }
    var ridgeX: Double { distance*Double(settings.ridgePosition) }
    var ridge: CGPoint { CGPoint(x: x(ridgeX),y: y(Double(settings.ridgeHeightM)+ground(ridgeX))) }
    var groundPoint: CGPoint {
        let d = distance*Double(settings.transmitterHeightM)/Double(settings.transmitterHeightM+settings.receiverHeightM)
        return CGPoint(x: x(d),y: y(ground(d)))
    }
    var refractionPoint: CGPoint {
        CGPoint(x: (transmitter.x+receiver.x)/2,
                y: top+8+(1-Double(settings.refractionK-0.65)/3.35)*24)
    }
    var echoTravel: Double { hypot(distance,Double(settings.receiverHeightM-settings.transmitterHeightM)) }
    func echoPoint(delay: Float) -> CGPoint {
        let mid = CGPoint(x: (transmitter.x+receiver.x)/2,y: (transmitter.y+receiver.y)/2)
        let ratio = TVEchoGeometry.offset(delayUS: Double(delay),directMetres: echoTravel)
            / TVEchoGeometry.offset(delayUS: 20,directMetres: echoTravel)
        return CGPoint(x: mid.x,y: mid.y-max(24,mid.y-top-8)*ratio)
    }
    func echoDelay(at point: CGPoint) -> Float {
        let midY = (transmitter.y+receiver.y)/2
        let fraction = min(1,max(0,(midY-point.y)/max(24,midY-top-8)))
        return Float(TVEchoGeometry.delayUS(offsetMetres: fraction*TVEchoGeometry.offset(delayUS: 20,directMetres: echoTravel),
                                           directMetres: echoTravel))
    }
}

/// An equivalent reflector on the perpendicular bisector of TX–RX. Its
/// extra path is c*delay; the diagram exaggerates this offset independently
/// of the terrain elevation, keeping the antenna heights readable.
enum TVEchoGeometry {
    static let metresPerMicrosecond = 299.792458
    static func offset(delayUS: Double,directMetres: Double) -> Double {
        let extra = max(0,delayUS)*metresPerMicrosecond
        return sqrt(extra*(2*directMetres+extra))/2
    }
    static func delayUS(offsetMetres: Double,directMetres: Double) -> Double {
        let total = hypot(directMetres,2*offsetMetres)
        // Rationalized difference avoids cancellation at very short delays.
        return 4*offsetMetres*offsetMetres/(total+directMetres)/metresPerMicrosecond
    }
}

struct TVPropagationDiagram: View {
    @Binding var settings: TVPropagationSettings
    let lightning: TVLightningState
    @Binding var echoGain: Float
    @Binding var echoDelay: Float
    @Binding var echoPhase: Float
    @State private var dragScale: Double?
    @State private var dragSpan: Double?
    @State private var receiverStart: CGPoint?
    @State private var ridgeStart: CGPoint?
    @State private var towerStart: CGPoint?
    @State private var refractionStart: Float?
    @State private var editing: TVSceneObject?
    @State private var hovering: TVSceneObject?

    var body: some View {
        GeometryReader { proxy in
            let g = TVSceneGeometry(size: proxy.size,settings: settings,frozenScale: dragScale,frozenSpan: dragSpan)
            ZStack(alignment: .topLeading) {
                Canvas { context,_ in draw(context: &context,geometry: g) }
                    .contentShape(Rectangle())
                    .contextMenu { sceneMenu }
                    .help(L("Right-click the sky or ground to add weather, a ridge or a reflection"))
                TVWeatherAtmosphere(weather: settings.weather,sceneEnabled: settings.enabled)
                    .allowsHitTesting(false).accessibilityHidden(true)
                if settings.enabled && settings.weather.enabled && settings.weather.lightning > 0 && settings.weather.lightningRatePerMinute > 0 {
                    TVLightningOverlay(state: lightning)
                }
                sky(g)
                link(g)
                ground(g)
                refraction(g)
                echo(g)
                tower(g)
                ridge(g)
                receiver(g)
                antenna(g)
            }.coordinateSpace(name: "tv-propagation")
                .opacity(settings.enabled ? 1 : 0.45)
                .clipped()
                .accessibilityElement(children: .contain)
                .accessibilityLabel(L("Propagation profile"))
        }
    }
    private func freeze(_ g: TVSceneGeometry) { dragScale = g.heightScale; dragSpan = g.span }
    private func thaw() { dragScale = nil; dragSpan = nil }
    private func editor(_ object: TVSceneObject) -> Binding<Bool> {
        Binding(get: { editing == object },set: { if !$0 { editing = nil } })
    }
    private func inspector(_ object: TVSceneObject) -> some View {
        TVSceneInspector(object: object,settings: $settings,echoGain: $echoGain,echoDelay: $echoDelay,echoPhase: $echoPhase)
    }
    private func sky(_ g: TVSceneGeometry) -> some View {
        Group {
            ForEach(Array([TVWeatherElement.sunlight,.temperature,.humidity].enumerated()),id: \.element) { i,element in
                TVWeatherSkyElement(element: element,weather: $settings.weather,sceneEnabled: settings.enabled,compact: true)
                    .frame(width: 64,height: 52)
                    .position(x: (Double(i)+0.5)*Double(g.size.width)/3,y: 34)
            }
            ForEach(Array(g.activeWeather.enumerated()),id: \.element) { i,element in
                TVWeatherSkyElement(element: element,weather: $settings.weather,sceneEnabled: settings.enabled,compact: true)
                    .frame(width: 64,height: 48)
                    .position(x: (Double(i%3)+0.5)*Double(g.size.width)/3,y: 88+Double(i/3)*48)
            }
        }
    }
    private func receiver(_ g: TVSceneGeometry) -> some View {
        Canvas { context,_ in
            var mast = Path(); mast.move(to: CGPoint(x: 14,y: 0)); mast.addLine(to: CGPoint(x: 14,y: max(24,g.bottom-g.receiver.y)))
            context.stroke(mast,with: .color(TVPropagationPalette.ink),lineWidth: 2)
            var foot = Path(); foot.move(to: CGPoint(x: 7,y: max(24,g.bottom-g.receiver.y))); foot.addLine(to: CGPoint(x: 21,y: max(24,g.bottom-g.receiver.y)))
            context.stroke(foot,with: .color(TVPropagationPalette.ink),lineWidth: 2)
        }
        .frame(width: 28,height: max(24,g.bottom-g.receiver.y))
        .contentShape(Rectangle())
        .gesture(DragGesture(coordinateSpace: .named("tv-propagation"))
            .onChanged { value in
                if receiverStart == nil { receiverStart = g.receiver; freeze(g) }
                let point = receiverStart! + value.translation
                settings.distanceKm = Float(min(50,max(3,g.metresX(point.x)/1000)))
                settings.receiverHeightM = Float(min(150,max(2,g.metresY(point.y))))
            }.onEnded { _ in receiverStart = nil; thaw() })
        .onTapGesture(count: 2) { editing = .antenna }
        .contextMenu { antennaMenu }
        .onHover { hovering = $0 ? .antenna : nil }
        .overlay(alignment: .topTrailing) {
            if hovering == .antenna || receiverStart != nil {
                readout(String(format: "%.1f km · %.0f m",settings.distanceKm,settings.receiverHeightM)).offset(x: 8,y: -24)
            }
        }
        .position(x: g.receiver.x,y: g.receiver.y+max(24,g.bottom-g.receiver.y)/2)
        .help(L("Drag the antenna mast to change distance and height"))
        .accessibilityLabel(L("Receiving antenna position"))
        .accessibilityValue(String(format: "%.1f km · %.1f m",settings.distanceKm,settings.receiverHeightM))
        .accessibilityAdjustableAction { direction in settings.distanceKm = min(50,max(3,settings.distanceKm+(direction == .increment ? 0.5 : -0.5))) }
    }
    private func antenna(_ g: TVSceneGeometry) -> some View {
        TVAntennaDrawing(kind: settings.antenna)
            .frame(width: 70,height: 36).contentShape(TVAntennaHitArea())
            .overlay { TVSceneWheel(value: $settings.antennaGainDB,range: -5...25,step: 0.5,label: L("Gain")) }
            .rotationEffect(.degrees(-Double(settings.antennaElevationDegrees)),anchor: .trailing)
            .gesture(DragGesture(minimumDistance: 2,coordinateSpace: .named("tv-propagation"))
                .onChanged { value in
                    let angle = atan2(g.receiver.y-value.location.y,g.receiver.x-value.location.x)*180/Double.pi
                    settings.antennaElevationDegrees = Float(min(90,max(-90,angle)))
                    hovering = .antenna
                }.onEnded { _ in hovering = nil })
            .onTapGesture(count: 2) { editing = .antenna }
            .contextMenu { antennaMenu }
            .onHover { hovering = $0 ? .antenna : nil }
            .popover(isPresented: editor(.antenna)) { inspector(.antenna) }
            .overlay(alignment: .top) {
                if hovering == .antenna {
                    readout(String(format: "%.1f° · %.1f dBi",settings.antennaElevationDegrees,settings.antennaGainDB)).offset(y: -22)
                }
            }
            .position(x: g.receiver.x-35,y: g.receiver.y)
            .help(L("Drag to rotate · scroll for gain · right-click to change antenna"))
            .accessibilityLabel(L("Antenna elevation"))
            .accessibilityValue(String(format: "%.1f° · %.1f dBi",settings.antennaElevationDegrees,settings.antennaGainDB))
            .accessibilityAdjustableAction { direction in settings.antennaElevationDegrees = min(90,max(-90,settings.antennaElevationDegrees+(direction == .increment ? 1 : -1))) }
            .accessibilityAction(named: Text(L("Edit values"))) { editing = .antenna }
    }
    @ViewBuilder private func tower(_ g: TVSceneGeometry) -> some View {
        Circle().fill(TVPropagationPalette.ink).frame(width: 7,height: 7).frame(width: 28,height: 28).contentShape(Rectangle())
            .gesture(DragGesture(coordinateSpace: .named("tv-propagation"))
                .onChanged { value in
                    if towerStart == nil { towerStart = g.transmitter; freeze(g) }
                    settings.transmitterHeightM = Float(min(300,max(20,g.metresY(towerStart!.y+value.translation.height))))
                }.onEnded { _ in towerStart = nil; thaw() })
            .onTapGesture(count: 2) { editing = .tower }
            .contextMenu { Button(L("Edit values")) { editing = .tower } }
            .onHover { hovering = $0 ? .tower : nil }
            .popover(isPresented: editor(.tower)) { inspector(.tower) }
            .overlay(alignment: .topLeading) {
                if hovering == .tower || towerStart != nil { readout(String(format: "%.0f m",settings.transmitterHeightM)).offset(y: -22) }
            }
            .position(g.transmitter)
            .help(L("Drag tower top to change transmitter height"))
            .accessibilityLabel(L("TX height"))
            .accessibilityValue(String(format: "%.0f m",settings.transmitterHeightM))
            .accessibilityAdjustableAction { d in settings.transmitterHeightM = min(300,max(20,settings.transmitterHeightM+(d == .increment ? 5 : -5))) }
    }
    @ViewBuilder private func ridge(_ g: TVSceneGeometry) -> some View {
        if settings.ridgeEnabled {
            Circle().fill(TVPropagationPalette.ink).frame(width: 6,height: 6).frame(width: 28,height: 28).contentShape(Rectangle())
                .gesture(DragGesture(coordinateSpace: .named("tv-propagation"))
                    .onChanged { value in
                        if ridgeStart == nil { ridgeStart = g.ridge; freeze(g) }
                        let point = ridgeStart! + value.translation
                        let x = min(g.distance*0.9,max(g.distance*0.1,g.metresX(point.x)))
                        settings.ridgePosition = Float(x/g.distance)
                        settings.ridgeHeightM = Float(min(500,max(0,g.metresY(point.y)-g.ground(x))))
                    }.onEnded { _ in ridgeStart = nil; thaw() })
                .onTapGesture(count: 2) { editing = .ridge }
                .contextMenu {
                    Button(L("Edit values")) { editing = .ridge }
                    Button(L("Remove ridge")) { settings.ridgeEnabled = false }
                }
                .onHover { hovering = $0 ? .ridge : nil }
                .popover(isPresented: editor(.ridge)) { inspector(.ridge) }
                .overlay(alignment: .top) {
                    if hovering == .ridge || ridgeStart != nil { readout(String(format: "%.0f m",settings.ridgeHeightM)).offset(y: -22) }
                }
                .position(g.ridge)
                .help(L("Drag the ridge to change its height and position"))
                .accessibilityLabel(L("Ridge position and height"))
                .accessibilityAction(named: Text(L("Edit values"))) { editing = .ridge }
        }
    }
    private func refraction(_ g: TVSceneGeometry) -> some View {
        Image(systemName: "wind").font(.system(size: 15,weight: .ultraLight))
            .frame(width: 28,height: 28).contentShape(Rectangle())
            .overlay { TVSceneWheel(value: $settings.refractionK,range: 0.65...4,step: 0.05,label: L("Refraction")) }
            .gesture(DragGesture(minimumDistance: 2,coordinateSpace: .named("tv-propagation"))
                .onChanged { v in
                    if refractionStart == nil { refractionStart = settings.refractionK }
                    settings.refractionK = min(4,max(0.65,refractionStart!-Float(v.translation.height)/40))
                }.onEnded { _ in refractionStart = nil })
            .onTapGesture { editing = .refraction }
            .onHover { hovering = $0 ? .refraction : nil }
            .popover(isPresented: editor(.refraction)) { inspector(.refraction) }
            .overlay(alignment: .top) {
                if hovering == .refraction || refractionStart != nil { readout(String(format: "k %.2f → %.2f",settings.refractionK,g.report.refractionK)).offset(y: -20) }
            }
            .position(g.refractionPoint)
            .help(L("Drag the refraction curve or scroll to change k · click for exact values"))
            .accessibilityLabel(L("Refraction"))
            .accessibilityValue(String(format: "k %.2f",settings.refractionK))
            .accessibilityAdjustableAction { d in settings.refractionK = min(4,max(0.65,settings.refractionK+(d == .increment ? 0.05 : -0.05))) }
    }
    private func ground(_ g: TVSceneGeometry) -> some View {
        let p = g.groundPoint
        return Group {
            Rectangle().fill(.clear).frame(width: g.size.width,height: 22).contentShape(Rectangle())
                .onTapGesture { editing = .ground }
                .contextMenu {
                    Button(L("Edit ground reflection")) { editing = .ground }
                    Button(settings.groundReflection > 0 ? L("Remove ground reflection") : L("Add ground reflection")) {
                        settings.groundReflection = settings.groundReflection > 0 ? 0 : 0.3
                    }
                    Button(settings.ridgeEnabled ? L("Remove ridge") : L("Add ridge")) { settings.ridgeEnabled.toggle() }
                }
                .popover(isPresented: editor(.ground)) { inspector(.ground) }
                .position(x: g.size.width/2,y: g.bottom+9)
                .help(L("Click ground to edit reflection · right-click to add a ridge"))
            if settings.groundReflection > 0 {
                reflectionPath(g.transmitter,p,g.receiver,color: TVPropagationPalette.reflection.opacity(0.3+Double(settings.groundReflection)*0.7),width: 1.5)
                    .onTapGesture { editing = .ground }
                    .contextMenu {
                        Button(L("Edit ground reflection")) { editing = .ground }
                        Button(L("Remove ground reflection")) { settings.groundReflection = 0 }
                    }
                    .help(String(format: "%@ %.0f%% · %.3f μs",L("Ground reflection"),settings.groundReflection*100,g.report.groundDelaySeconds*1e6))
                Image(systemName: "arrow.triangle.branch").font(.system(size: 13)).frame(width: 28,height: 28)
                    .contentShape(Rectangle())
                    .overlay { TVSceneWheel(value: $settings.groundReflection,range: 0...0.8,step: 0.02,label: L("Ground reflection")) }
                    .onTapGesture { editing = .ground }
                    .position(p)
                    .help(L("Scroll to change reflection strength · click for exact values"))
            }
        }
    }
    @ViewBuilder private func echo(_ g: TVSceneGeometry) -> some View {
        if echoGain > 0 {
            let p = g.echoPoint(delay: echoDelay)
            reflectionPath(g.transmitter,p,g.receiver,color: TVPropagationPalette.echo.opacity(0.25+Double(echoGain)*0.7),width: 1.5)
                .onTapGesture { editing = .echo }
                .contextMenu { echoMenu }
                .help(String(format: "%@ %.0f%% · %.2f μs · %.0f°",L("Additional reflection"),echoGain*100,echoDelay,echoPhase))
            Image(systemName: "diamond").font(.system(size: 15)).frame(width: 30,height: 30).contentShape(Rectangle())
                .overlay { TVSceneWheel(value: $echoGain,range: 0...0.9,step: 0.02,label: L("Echo amplitude")) }
                .gesture(DragGesture(coordinateSpace: .named("tv-propagation"))
                    .onChanged { v in freeze(g); echoDelay = g.echoDelay(at: v.location); hovering = .echo }
                    .onEnded { _ in thaw(); hovering = nil })
                .onTapGesture(count: 2) { editing = .echo }
                .contextMenu { echoMenu }
                .onHover { hovering = $0 ? .echo : nil }
                .popover(isPresented: editor(.echo)) { inspector(.echo) }
                .overlay(alignment: .top) {
                    if hovering == .echo { readout(String(format: "%.0f%% · %.2f μs",echoGain*100,echoDelay)).offset(y: -22) }
                }
                .position(p)
                .help(L("Drag reflector vertically for delay · scroll for strength · right-click for phase"))
                .accessibilityLabel(L("Additional reflection"))
                .accessibilityValue(String(format: "%.0f%% · %.2f μs · %.0f°",echoGain*100,echoDelay,echoPhase))
                .accessibilityAdjustableAction { d in echoGain = min(0.9,max(0,echoGain+(d == .increment ? 0.02 : -0.02))) }
                .accessibilityAction(named: Text(L("Edit values"))) { editing = .echo }
        }
    }
    private func reflectionPath(_ a: CGPoint,_ b: CGPoint,_ c: CGPoint,color: Color,width: CGFloat) -> some View {
        let path = Path { p in p.move(to: a); p.addLine(to: b); p.addLine(to: c) }
        return path.stroke(color,style: StrokeStyle(lineWidth: width,dash: [4,3]))
            .contentShape(path.strokedPath(StrokeStyle(lineWidth: 12)))
    }
    private func link(_ g: TVSceneGeometry) -> some View {
        let path = Path { p in
            p.move(to: g.transmitter)
            if g.report.ridgeClearanceM < 0 { p.addLine(to: CGPoint(x: g.x(g.report.diffractionPointDistanceM),y: g.y(g.report.obstructionHeightM))) }
            p.addLine(to: g.receiver)
        }
        let r = g.report
        let info = String(format: "%@ %+.1f dB\n%@ %.2f dB\n%@ %.2f dB\n%@ %.2f dB\n%@ %.2f dB\n%@",
            L("Link relative"),r.relativeGainDB,L("Free-space loss"),r.spaceLossDB,L("Diffraction"),r.diffractionLossDB,
            L("Direction loss"),r.antennaLossDB,L("Weather loss"),r.weatherLossDB,L("2D elevation profile · height exaggerated"))
        return path.stroke(.clear,lineWidth: 12).contentShape(path.strokedPath(StrokeStyle(lineWidth: 12)))
            .help(info).accessibilityLabel(info)
    }
    private func readout(_ text: String) -> some View {
        Text(text).font(.system(size: 10).monospacedDigit()).fixedSize()
            .padding(3).foregroundStyle(TVPropagationPalette.ink).background(TVPropagationPalette.panel.opacity(0.96)).allowsHitTesting(false)
    }
    @ViewBuilder private var antennaMenu: some View {
        ForEach(TVAntennaKind.allCases,id: \.self) { kind in
            Button { settings.antenna = kind; settings.antennaGainDB = kind.nominalGainDB } label: {
                if settings.antenna == kind { Label(L(kind.rawValue),systemImage: "checkmark") }
                else { Text(L(kind.rawValue)) }
            }
        }
        Divider()
        Button(L("Edit values")) { editing = .antenna }
        Button(L("Reset antenna direction")) { settings.antennaElevationDegrees = 0 }
    }
    @ViewBuilder private var echoMenu: some View {
        Button(L("Edit reflection / phase")) { editing = .echo }
        Button(L("Remove reflection")) { echoGain = 0 }
    }
    @ViewBuilder private var sceneMenu: some View {
        Menu(L("Weather / atmosphere")) {
            Toggle(L("Enable weather"),isOn: $settings.weather.enabled)
            Divider()
            ForEach(TVWeatherElement.allCases.filter { $0 != .sunlight && $0 != .temperature && $0 != .humidity }) { element in
                Button {
                    settings.weather.enabled = true
                    let value = settings.weather[keyPath: element.keyPath]
                    settings.weather[keyPath: element.keyPath] = value > 0 ? 0 : element.range.upperBound*0.25
                    if element == .lightning && value <= 0 && settings.weather.lightningRatePerMinute <= 0 {
                        settings.weather.lightningRatePerMinute = TVWeatherSettings().lightningRatePerMinute
                    }
                } label: {
                    if settings.weather[keyPath: element.keyPath] > 0 { Label(L(element.label),systemImage: "checkmark") }
                    else { Text(L(element.label)) }
                }
            }
        }
        Button(settings.ridgeEnabled ? L("Remove ridge") : L("Add ridge")) { settings.ridgeEnabled.toggle() }
        Button(echoGain > 0 ? L("Remove reflection") : L("Add reflection")) { echoGain = echoGain > 0 ? 0 : 0.25 }
        Button(settings.groundReflection > 0 ? L("Remove ground reflection") : L("Add ground reflection")) {
            settings.groundReflection = settings.groundReflection > 0 ? 0 : 0.3
        }
    }
    private func draw(context: inout GraphicsContext,geometry g: TVSceneGeometry) {
        let s = g.settings, accent = TVPropagationPalette.accent
        for n in 0...3 {
            let metres = g.span*Double(n)/3, x = g.x(metres)
            var grid = Path(); grid.move(to: CGPoint(x: x,y: g.top)); grid.addLine(to: CGPoint(x: x,y: g.bottom))
            context.stroke(grid,with: .color(TVPropagationPalette.ink.opacity(0.07)),lineWidth: 0.5)
            context.draw(Text(String(format: "%.0f km",metres/1000)).font(.system(size: 9)).foregroundColor(TVPropagationPalette.muted),at: CGPoint(x: x,y: g.bottom+17))
        }
        let tx = g.transmitter, rx = g.receiver
        let lambda = 299_792_458/(Double(s.frequencyMHz)*1e6)
        var terrain = Path(), upper = [CGPoint](),lower = [CGPoint]()
        for n in 0...80 {
            let d = g.distance*Double(n)/80
            let width = min(5000,g.distance*0.18)
            let hill = s.ridgeEnabled ? Double(s.ridgeHeightM)*max(0,1-abs(d-g.ridgeX)/width) : 0
            let point = CGPoint(x: g.x(d),y: g.y(g.ground(d)+hill))
            if n == 0 { terrain.move(to: point) } else { terrain.addLine(to: point) }
            let line = Double(s.transmitterHeightM)+(Double(s.receiverHeightM)-Double(s.transmitterHeightM))*d/g.distance
            let fresnel = sqrt(max(0,lambda*d*(g.distance-d)/g.distance))
            upper.append(CGPoint(x: g.x(d),y: g.y(line+fresnel)))
            lower.append(CGPoint(x: g.x(d),y: g.y(line-fresnel)))
        }
        terrain.addLine(to: CGPoint(x: g.right,y: g.bottom)); terrain.addLine(to: CGPoint(x: tx.x,y: g.bottom)); terrain.closeSubpath()
        context.fill(terrain,with: .color(TVPropagationPalette.terrain))
        context.stroke(terrain,with: .color(TVPropagationPalette.muted.opacity(0.5)),lineWidth: 0.7)
        var fresnel = Path(); fresnel.addLines(upper+Array(lower.reversed())); fresnel.closeSubpath()
        context.fill(fresnel,with: .color(accent.opacity(0.1)))
        var signal = Path(); signal.move(to: tx)
        if g.report.ridgeClearanceM < 0 { signal.addLine(to: CGPoint(x: g.x(g.report.diffractionPointDistanceM),y: g.y(g.report.obstructionHeightM))) }
        signal.addLine(to: rx)
        context.stroke(signal,with: .color(accent),lineWidth: 2)
        var curve = Path(); curve.move(to: tx)
        curve.addQuadCurve(to: rx,control: CGPoint(x: g.refractionPoint.x,y: 2*g.refractionPoint.y-(tx.y+rx.y)/2))
        context.stroke(curve,with: .color(TVPropagationPalette.muted.opacity(0.4)),style: StrokeStyle(lineWidth: 0.8,dash: [2,4]))
        var tower = Path(); tower.move(to: CGPoint(x: tx.x-5,y: g.bottom)); tower.addLine(to: tx); tower.addLine(to: CGPoint(x: tx.x+5,y: g.bottom))
        context.stroke(tower,with: .color(TVPropagationPalette.ink),lineWidth: 1.5)
        context.draw(Text("TX").font(.system(size: 9)).foregroundColor(TVPropagationPalette.ink),at: CGPoint(x: tx.x-12,y: tx.y-8))
        context.draw(Text("RX").font(.system(size: 9)).foregroundColor(TVPropagationPalette.ink),at: CGPoint(x: rx.x+12,y: rx.y-8))
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
            context.stroke(p,with: .color(TVPropagationPalette.ink),lineWidth: 1.8)
        }
    }
}

private extension CGPoint {
    static func + (point: CGPoint,size: CGSize) -> CGPoint { CGPoint(x: point.x+size.width,y: point.y+size.height) }
}
