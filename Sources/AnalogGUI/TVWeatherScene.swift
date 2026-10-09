import SwiftUI
import AnalogCore

/// A gesture starts from the captured value, so layout/redraws during a drag
/// cannot accumulate deltas or change the RF setting behind the user's hand.
enum TVWeatherElement: String, CaseIterable, Identifiable {
    case sunlight, temperature, humidity, ionization, lightning, rain, snow, fog, clutter
    var id: Self { self }
    var keyPath: WritableKeyPath<TVWeatherSettings, Float> {
        switch self {
        case .sunlight: \.sunlight
        case .temperature: \.temperatureC
        case .humidity: \.humidityPercent
        case .ionization: \.ionization
        case .lightning: \.lightning
        case .rain: \.rainMMHour
        case .snow: \.snowMMHour
        case .fog: \.fogGramsM3
        case .clutter: \.clutter
        }
    }
    var range: ClosedRange<Float> {
        switch self {
        case .temperature: -30...50
        case .humidity: 0...100
        case .rain: 0...120
        case .snow: 0...20
        case .fog: 0...0.5
        default: 0...1
        }
    }
    var label: String {
        switch self {
        case .sunlight: "Sunlight"
        case .temperature: "Temperature"
        case .humidity: "Humidity"
        case .ionization: "Ionosphere"
        case .lightning: "Lightning"
        case .rain: "Rain"
        case .snow: "Snow"
        case .fog: "Fog"
        case .clutter: "Clutter"
        }
    }
    var detail: String {
        switch self {
        case .rain: "Rain · mm/h"
        case .snow: "Snow water equivalent · mm/h"
        case .fog: "Fog liquid water · g/m³"
        case .temperature: "Air temperature · °C"
        case .humidity: "Relative humidity · %"
        case .lightning: "Lightning activity"
        case .ionization: "Ionospheric remote interference"
        case .clutter: "Weather clutter"
        case .sunlight: "Sunlight"
        }
    }
    func strength(_ weather: TVWeatherSettings) -> Double {
        Double((weather[keyPath: keyPath]-range.lowerBound)/(range.upperBound-range.lowerBound))
    }
    func readout(_ weather: TVWeatherSettings) -> String {
        let v = weather[keyPath: keyPath]
        switch self {
        case .rain, .snow: return String(format: "%.1f mm/h",v)
        case .fog: return String(format: "%.2f g/m³",v)
        case .temperature: return String(format: "%.0f °C",v)
        case .humidity: return String(format: "%.0f%%",v)
        default: return String(format: "%.0f%%",v*100)
        }
    }
    func adjust(_ weather: inout TVWeatherSettings, from start: Float, translation: CGFloat) {
        guard start.isFinite, translation.isFinite else { return }
        let v = start-Float(translation/100)*(range.upperBound-range.lowerBound)
        weather[keyPath: keyPath] = min(range.upperBound,max(range.lowerBound,v))
        weather.enabled = true
    }
    func reset(_ weather: inout TVWeatherSettings) {
        weather[keyPath: keyPath] = TVWeatherSettings()[keyPath: keyPath]
    }
}

struct TVWeatherScene: View {
    @Binding var weather: TVWeatherSettings
    var sceneEnabled = true
    private var elements: [TVWeatherElement] { TVWeatherElement.allCases.filter { $0 != .sunlight } }
    var body: some View {
        VStack(spacing: 3) {
            HStack {
                Text(L("Weather / atmosphere")).fontWeight(.medium)
                Spacer()
                Text(L("Drag sky elements ↑↓ · double-click to reset"))
                    .foregroundStyle(.black.opacity(0.5))
            }.font(.system(size: 10)).padding(.bottom, 3)
            GeometryReader { proxy in
                ZStack(alignment: .topLeading) {
                    Rectangle().fill(LinearGradient(colors: [
                        EditingTool.tv.logoAccentColor.opacity(weather.enabled ? Double(weather.sunlight)*0.12 : 0.015),
                        Color(white: 0.98)
                    ], startPoint: .topLeading,endPoint: .bottomTrailing))
                    ForEach(Array(elements.enumerated()),id: \.element) { index, element in
                        TVWeatherSkyElement(element: element,weather: $weather,sceneEnabled: sceneEnabled)
                            .frame(width: proxy.size.width/4,height: proxy.size.height/2)
                            .position(x: (CGFloat(index%4)+0.5)*proxy.size.width/4,
                                      y: (index < 4 ? 0.25 : 0.75)*proxy.size.height)
                    }
                }
            }
        }.padding(.bottom, 6)
            .accessibilityElement(children: .contain)
            .accessibilityLabel(L("Weather / atmosphere"))
    }
}

struct TVWeatherSkyElement: View {
    let element: TVWeatherElement
    @Binding var weather: TVWeatherSettings
    var sceneEnabled = true
    @State private var dragStart: Float?
    @State private var hovering = false
    var body: some View {
        VStack(spacing: 2) {
            Group {
                if element == .rain || element == .lightning {
                    TVWeatherAnimatedGlyph(element: element,weather: weather,sceneEnabled: sceneEnabled)
                } else {
                    TVWeatherGlyph(element: element,strength: element.strength(weather))
                }
            }.frame(width: 70,height: 43)
            Text(L(element.label)).font(.system(size: 10,weight: .medium)).lineLimit(1)
            Text(element.readout(weather)).font(.system(size: 9).monospacedDigit())
                .foregroundStyle(.black.opacity(0.55))
        }.frame(maxWidth: .infinity,maxHeight: .infinity)
            .opacity(weather.enabled ? 1 : 0.4)
            .background(Rectangle().fill(.black.opacity(hovering ? 0.035 : 0)))
            .contentShape(Rectangle())
            .onHover { hovering = $0 }
            .gesture(DragGesture(minimumDistance: 2)
                .onChanged { value in
                    if dragStart == nil { dragStart = weather[keyPath: element.keyPath] }
                    element.adjust(&weather,from: dragStart!,translation: value.translation.height)
                }.onEnded { _ in dragStart = nil })
            .onTapGesture(count: 2) { element.reset(&weather) }
            .help("\(L(element.detail))\n\(L("Drag up to increase · down to decrease · double-click to reset"))")
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(L(element.detail))
            .accessibilityValue("\(element.readout(weather)) · \(weather.enabled ? L("Enable weather") : L("Weather bypassed"))")
            .accessibilityAdjustableAction { direction in
                element.adjust(&weather,from: weather[keyPath: element.keyPath],
                               translation: direction == .increment ? -5 : 5)
            }
            .accessibilityAction(named: Text(L("Reset"))) { element.reset(&weather) }
    }
}

private struct TVWeatherGlyph: View {
    let element: TVWeatherElement
    let strength: Double
    var seconds: Double? = nil
    var body: some View {
        Canvas { context,size in
            let t = min(1,max(0,strength)), ink = Color.black.opacity(0.75)
            let accent = EditingTool.tv.logoAccentColor
            func line(_ points: [CGPoint],color: Color = ink,width: Double = 1) {
                var p = Path(); p.addLines(points)
                context.stroke(p,with: .color(color),lineWidth: width)
            }
            func symbol(_ name: String,at point: CGPoint,size: Double = 29,opacity: Double = 1) {
                context.draw(Text(Image(systemName: name)).font(.system(size: size,weight: .ultraLight))
                    .foregroundColor(ink.opacity(opacity)),at: point)
            }
            switch element {
            case .sunlight:
                let centre = CGPoint(x: 35,y: 21), r = 7+t*3
                context.fill(Path(ellipseIn: CGRect(x: 35-r,y: 21-r,width: r*2,height: r*2)),
                             with: .color(accent.opacity(0.15+t*0.85)))
                context.stroke(Path(ellipseIn: CGRect(x: 35-r,y: 21-r,width: r*2,height: r*2)),with: .color(ink),lineWidth: 1)
                for n in 0..<12 {
                    let a = Double(n)*Double.pi/6, start = r+3, end = start+2+t*6
                    line([CGPoint(x: centre.x+cos(a)*start,y: centre.y+sin(a)*start),
                          CGPoint(x: centre.x+cos(a)*end,y: centre.y+sin(a)*end)],color: ink.opacity(0.2+t*0.8))
                }
            case .temperature:
                let color = Color(red: 0.25+t*0.55,green: 0.45-t*0.2,blue: 0.8-t*0.6)
                var tube = Path(roundedRect: CGRect(x: 30,y: 2,width: 10,height: 28),cornerRadius: 5)
                tube.addEllipse(in: CGRect(x: 27,y: 26,width: 16,height: 16))
                context.fill(Path(CGRect(x: 33,y: 29-t*24,width: 4,height: t*24)),with: .color(color))
                context.fill(Path(ellipseIn: CGRect(x: 30,y: 29,width: 10,height: 10)),with: .color(color))
                context.stroke(tube,with: .color(ink),lineWidth: 1)
                for y in stride(from: 7,through: 25,by: 6) {
                    line([CGPoint(x: 44,y: y),CGPoint(x: 49,y: y)])
                }
            case .humidity:
                var drop = Path(); drop.move(to: CGPoint(x: 35,y: 1))
                drop.addCurve(to: CGPoint(x: 22,y: 29),control1: CGPoint(x: 33,y: 12),control2: CGPoint(x: 22,y: 18))
                drop.addCurve(to: CGPoint(x: 48,y: 29),control1: CGPoint(x: 22,y: 45),control2: CGPoint(x: 48,y: 45))
                drop.addCurve(to: CGPoint(x: 35,y: 1),control1: CGPoint(x: 48,y: 18),control2: CGPoint(x: 37,y: 12))
                var fill = context; fill.clip(to: drop)
                fill.fill(Path(CGRect(x: 20,y: 41-t*40,width: 30,height: t*40)),with: .color(Color.blue.opacity(0.22)))
                context.stroke(drop,with: .color(ink),lineWidth: 1)
            case .rain, .snow:
                symbol("cloud",at: CGPoint(x: 35,y: 14),size: 31)
                for n in 0..<10 {
                    let x = 15+Double(n%5)*10
                    let y = seconds.map { 26+TVWeatherMotion.wrap(Double(n/5)*10+$0*(18+t*20),period: 16) }
                        ?? (28+Double(n/5)*10)
                    let active = Double(n) < ceil(t*10)
                    let color = ink.opacity(active ? 0.9 : 0.08)
                    if element == .rain {
                        line([CGPoint(x: x+2,y: y),CGPoint(x: x-1,y: y+4+t*3)],color: color)
                    } else {
                        for angle in [0.0,Double.pi/3,Double.pi*2/3] {
                            line([CGPoint(x: x-cos(angle)*2.5,y: y-sin(angle)*2.5),
                                  CGPoint(x: x+cos(angle)*2.5,y: y+sin(angle)*2.5)],color: color)
                        }
                    }
                }
            case .fog:
                for n in 0..<5 {
                    let inset = n%2 == 0 ? 10.0 : 18.0, y = 7+Double(n)*7
                    line([CGPoint(x: inset,y: y),CGPoint(x: 70-inset,y: y)],
                         color: ink.opacity(0.1+t*0.65),width: 1+t*3)
                }
            case .lightning:
                symbol("cloud",at: CGPoint(x: 35,y: 13),size: 31)
                let flash = seconds.map { TVWeatherMotion.lightning(seconds: $0,activity: t).opacity } ?? t
                for n in 0..<3 {
                    let x = 19+Double(n)*15
                    line([CGPoint(x: x+3,y: 25),CGPoint(x: x-2,y: 32),CGPoint(x: x+3,y: 32),CGPoint(x: x-1,y: 41)],
                         color: n == 1 ? accent.opacity(0.15+flash*0.85) : ink.opacity(flash*0.7),width: 1+t)
                }
            case .ionization, .clutter:
                for n in 0..<3 {
                    let y = 8+Double(n)*10
                    var p = Path(); p.move(to: CGPoint(x: 8,y: y+5))
                    p.addQuadCurve(to: CGPoint(x: 62,y: y+5),control: CGPoint(x: 35,y: y-6))
                    context.stroke(p,with: .color(ink.opacity(0.12+t*0.7)),
                                   style: StrokeStyle(lineWidth: 1,dash: element == .clutter ? [2,4] : []))
                }
                for n in 0..<Int(t*14) {
                    let x = 12+Double((n*17)%48), y = 8+Double((n*11)%30)
                    context.fill(Path(ellipseIn: CGRect(x: x,y: y,width: 2,height: 2)),with: .color(accent))
                }
                if element == .clutter { symbol("antenna.radiowaves.left.and.right",at: CGPoint(x: 35,y: 28),size: 16) }
            }
        }.accessibilityHidden(true)
    }
}

private struct TVWeatherAnimatedGlyph: View {
    let element: TVWeatherElement
    let weather: TVWeatherSettings
    let sceneEnabled: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var visible = false
    var body: some View {
        let active = sceneEnabled && weather.enabled && element.strength(weather) > 0
        TimelineView(.animation(minimumInterval: 1/12,paused: !active || !visible || reduceMotion)) { tick in
            TVWeatherGlyph(element: element,strength: element.strength(weather),
                seconds: active && !reduceMotion ? tick.date.timeIntervalSinceReferenceDate : nil)
        }.onAppear { visible = true }.onDisappear { visible = false }
    }
}

/// Analytic motion needs no particle state, timer tasks, random allocations or
/// configuration writes. The RF engine keeps its own physical impulse timeline.
enum TVWeatherMotion {
    static func wrap(_ value: Double,period: Double) -> Double {
        value-floor(value/period)*period
    }
    static func rainPosition(index: Int,seconds: Double,size: CGSize,strength: Double) -> CGPoint {
        let span = max(1,Double(size.height)-64)
        let y = wrap(Double((index*47)%541)/541*span+seconds*(65+strength*85),period: span)
        let x = wrap(Double((index*71+31)%997)/997*Double(size.width)-y*0.16,period: max(1,Double(size.width)))
        return CGPoint(x: x,y: 24+y)
    }
    static func lightning(seconds: Double,activity: Double) -> (event: Int,opacity: Double) {
        let t = min(1,max(0,activity))
        guard t > 0 else { return (0,0) }
        let period = 7-4.5*t, event = Int(floor(seconds/period))
        let age = wrap(seconds,period: period)
        // Short strokes brighten the bolt itself rather than flashing the panel.
        let attack = min(1,age/0.04)
        return (event,age < 0.32 ? attack*exp(-age*9)*(0.5+t*0.5) : 0)
    }
}

/// Only this small canvas ticks at 24 Hz; terrain, controls and the RF pipeline
/// observe configuration as before. Zero/disabled weather has no active clock.
struct TVWeatherAtmosphere: View {
    let weather: TVWeatherSettings
    var sceneEnabled = true
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var visible = false
    var body: some View {
        let moving = sceneEnabled && weather.enabled && (weather.rainMMHour > 0 || weather.lightning > 0)
        TimelineView(.animation(minimumInterval: 1/24,paused: !moving || !visible || reduceMotion)) { tick in
            drawing(seconds: moving && !reduceMotion ? tick.date.timeIntervalSinceReferenceDate : nil)
        }.onAppear { visible = true }.onDisappear { visible = false }
    }
    private func drawing(seconds: Double?) -> some View {
        Canvas { context,size in
            guard sceneEnabled && weather.enabled else { return }
            let w = Double(size.width), h = Double(size.height)-26
            let fog = Double(weather.fogGramsM3)*2, humid = Double(weather.humidityPercent)/100
            context.fill(Path(CGRect(x: 0,y: 22,width: w,height: h-22)),
                         with: .linearGradient(Gradient(colors: [.clear,Color(white: 0.72).opacity(fog*0.35+humid*0.04)]),
                                               startPoint: CGPoint(x: 0,y: 22),endPoint: CGPoint(x: 0,y: h)))
            for n in 0..<Int(ceil(Double(weather.rainMMHour)/120*90)) {
                let point = TVWeatherMotion.rainPosition(index: n,seconds: seconds ?? 0,size: size,
                                                        strength: Double(weather.rainMMHour)/120)
                var p = Path(); p.move(to: point); p.addLine(to: CGPoint(x: point.x-2,y: point.y+9))
                context.stroke(p,with: .color(.black.opacity(0.16)),lineWidth: 0.7)
            }
            for n in 0..<Int(weather.snowMMHour/20*65) {
                let x = Double((n*79+17)%997)/997*w, y = 24+Double((n*53)%541)/541*max(1,h-38)
                context.fill(Path(ellipseIn: CGRect(x: x,y: y,width: 2.5,height: 2.5)),with: .color(.gray.opacity(0.45)))
            }
            let flash = seconds.map { TVWeatherMotion.lightning(seconds: $0,activity: Double(weather.lightning)) }
                ?? (event: 0,opacity: Double(weather.lightning)*0.45)
            if flash.opacity > 0 {
                let x = w*(0.3+Double((flash.event*37)%43)/100)
                var bolt = Path(); bolt.addLines([
                    CGPoint(x: x,y: 26),CGPoint(x: x-13,y: h*0.3),
                    CGPoint(x: x+3,y: h*0.3-3),CGPoint(x: x-18,y: h*0.61),
                    CGPoint(x: x-6,y: h*0.59),CGPoint(x: x-27,y: h-5)
                ])
                context.stroke(bolt,with: .color(EditingTool.tv.logoAccentColor.opacity(flash.opacity*0.3)),lineWidth: 6)
                context.stroke(bolt,with: .color(.black.opacity(flash.opacity*0.65)),lineWidth: 1.3)
                var branch = Path(); branch.addLines([CGPoint(x: x-18,y: h*0.61),
                    CGPoint(x: x-33,y: h*0.65),CGPoint(x: x-44,y: h*0.85)])
                context.stroke(branch,with: .color(.black.opacity(flash.opacity*0.35)),lineWidth: 0.7)
            }
        }
    }
}
