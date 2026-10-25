import SwiftUI
import AnalogCore

/// The dark panel, direct scene handles and local inspectors follow the TV propagation scene.
struct FilmLabSceneView: View {
    @ObservedObject var lab: FilmLabController
    let probe: FilmLabState
    private var stage: FilmLabStage { lab.session.stage }
    private var tint: Color { stage == .exposure ? TVPropagationPalette.accent : stage == .drying ? TVPropagationPalette.rain : .orange }
    var body: some View {
        VStack(spacing: 6) {
            HStack {
                Text("\(stage.title)场景").font(.system(size: 12,weight: .semibold))
                Spacer()
                Text("上下拖动设备调节 · 点击查看").font(.caption2).foregroundStyle(TVPropagationPalette.muted)
            }
            HStack(spacing: 12) {
                ForEach(elements,id: \.name) { element in
                    FilmLabSceneHandle(recipe: $lab.session.recipe,element: element,tint: tint)
                }
            }
            GeometryReader { geometry in
                Canvas { context,size in draw(&context,size) }
                    .accessibilityLabel("\(stage.title)设备与乳剂截面；中灰探针金属银 \(probe.silverMean)，卤化银 \(probe.halideMean)，水膜 \(probe.water)")
                    .overlay(alignment: .topTrailing) {
                        Text(stage == .development ? lab.session.recipe.developer.rawValue : "中灰探针 · 表层／深层")
                            .font(.system(size: 9,design: .monospaced)).foregroundStyle(TVPropagationPalette.muted)
                    }
            }
            HStack(spacing: 10) {
                readout("银",probe.silverMean); readout("卤化银",probe.halideMean)
                readout("残留",probe.residueMean); readout("水膜",probe.water)
            }.font(.system(size: 10,design: .monospaced))
        }.padding(12).foregroundStyle(TVPropagationPalette.ink)
            .background(TVPropagationPalette.panel)
            .overlay { Rectangle().stroke(TVPropagationPalette.ink.opacity(0.1),lineWidth: 1).allowsHitTesting(false) }
            .environment(\.colorScheme,.dark)
    }
    private func readout(_ name: String,_ value: Float) -> some View {
        HStack(spacing: 3) { Text(name).foregroundStyle(TVPropagationPalette.muted); Text(String(format: "%.3f",value)) }.frame(maxWidth: .infinity)
    }
    private var elements: [FilmLabSceneElement] {
        switch stage {
        case .exposure: [.init("光源", "sun.max", \.kelvin,2000...12000,"K"), .init("曝光", "camera.aperture", \.exposureEV,-6...6,"EV"), .init("漏光", "flashlight.on.fill", \.lightLeak,0...1,"")]
        case .development, .stop, .fixation: [.init("温控", "thermometer.medium", \.temperature,10...45,"°C"), .init("药液", "flask", \.strength,0...2,"") , .init("搅动", "arrow.triangle.2.circlepath", \.agitation,0...1,"")]
        case .wash: [.init("水温", "thermometer.medium", \.temperature,10...45,"°C"), .init("进水阀", "spigot", \.flow,0...1,"")]
        case .drying: [.init("温控", "thermometer.medium", \.temperature,10...45,"°C"), .init("湿度", "humidity", \.humidity,0...0.99,""), .init("风机", "fanblades", \.airflow,0...1,"") , .init("灰尘", "aqi.medium", \.dust,0...1,"")]
        case .scan: []
        }
    }
    private func draw(_ context: inout GraphicsContext,_ size: CGSize) {
        let w = size.width,h = size.height,elapsed = Double(lab.session.elapsed)
        // A subdued grid and equipment silhouettes share the propagation diagram's visual language.
        for i in 1..<8 {
            var line = Path(); line.move(to: CGPoint(x: w*CGFloat(i)/8,y: 8)); line.addLine(to: CGPoint(x: w*CGFloat(i)/8,y: h-3))
            context.stroke(line,with: .color(TVPropagationPalette.ink.opacity(0.04)),lineWidth: 1)
        }
        let film = CGRect(x: w*0.3,y: h*0.36,width: w*0.4,height: h*0.5)
        if stage == .exposure {
            let weights = FilmLabPhysics.spectralWeights(kelvin: lab.session.recipe.kelvin)
            for i in 0..<3 {
                let x = film.minX+film.width*(CGFloat(i)+0.5)/3
                var ray = Path(); ray.move(to: CGPoint(x: w*0.5,y: 4)); ray.addLine(to: CGPoint(x: x,y: film.minY-3))
                context.stroke(ray,with: .color([Color.red,.green,.blue][i].opacity(Double(weights[i])/3+0.2)),style: StrokeStyle(lineWidth: 2,dash: [5,4],dashPhase: -elapsed*6))
            }
        } else if stage == .drying {
            var rail = Path(); rail.move(to: CGPoint(x: w*0.22,y: film.minY-7)); rail.addLine(to: CGPoint(x: w*0.78,y: film.minY-7))
            context.stroke(rail,with: .color(TVPropagationPalette.muted),lineWidth: 2)
            for i in 0..<4 {
                let y = film.minY+CGFloat(i)*film.height/4
                var air = Path(); air.move(to: CGPoint(x: 12,y: y)); air.addQuadCurve(to: CGPoint(x: film.minX-8,y: y),control: CGPoint(x: film.minX*0.6,y: y-8))
                context.stroke(air,with: .color(tint.opacity(Double(lab.session.recipe.airflow)*0.7+0.1)),style: StrokeStyle(lineWidth: 1,dash: [8,6],dashPhase: -elapsed*0.5))
            }
        } else if stage != .scan {
            let tray = CGRect(x: 18,y: h*0.23,width: w-36,height: h*0.73)
            context.fill(Path(roundedRect: tray,cornerRadius: 7),with: .color(tint.opacity(0.09)))
            context.stroke(Path(roundedRect: tray,cornerRadius: 7),with: .color(TVPropagationPalette.muted.opacity(0.5)),lineWidth: 1)
            var surface = Path()
            for i in 0...60 {
                let x = tray.minX+tray.width*CGFloat(i)/60
                let amplitude = stage == .wash ? lab.session.recipe.flow : lab.session.recipe.agitation
                let y = tray.minY+4+sin(CGFloat(i)*0.4+elapsed*0.3)*CGFloat(amplitude)*3
                if i == 0 { surface.move(to: CGPoint(x: x,y: y)) } else { surface.addLine(to: CGPoint(x: x,y: y)) }
            }
            context.stroke(surface,with: .color(tint.opacity(0.6)),lineWidth: 1)
            if stage == .wash {
                var stream = Path(); stream.move(to: CGPoint(x: w*0.15,y: 2)); stream.addLine(to: CGPoint(x: w*0.15,y: tray.minY+8))
                context.stroke(stream,with: .color(TVPropagationPalette.rain.opacity(Double(lab.session.recipe.flow))),style: StrokeStyle(lineWidth: 3,dash: [4,3],dashPhase: -elapsed*0.8))
            }
        }
        for layer in 0..<2 {
            let rect = CGRect(x: film.minX,y: film.minY+CGFloat(layer)*film.height/2,width: film.width,height: film.height/2-2)
            context.fill(Path(rect),with: .color(Color(white: 0.85-Double(probe.silver[layer])*0.72).opacity(0.25+Double(probe.halide[layer])*0.5)))
            context.stroke(Path(rect),with: .color(TVPropagationPalette.muted.opacity(0.5)),lineWidth: 1)
            let concentration: Float = switch stage {
            case .exposure: probe.latent
            case .stop: probe.acid[layer]
            case .fixation: probe.fixer[layer]
            case .wash: probe.residue[layer]
            case .drying: probe.water
            default: probe.developer[layer]
            }
            for i in 0..<Int(min(1,max(0,concentration))*36) {
                let x = rect.minX+5+CGFloat(FilmLabPhysics.hash(Float(i),Float(layer),lab.session.seed))*(rect.width-10)
                let phase = FilmLabPhysics.hash(Float(i),3,lab.session.seed)
                let y = rect.minY+3+CGFloat((Double(phase)+elapsed*0.013).truncatingRemainder(dividingBy: 1))*(rect.height-6)
                context.fill(Path(ellipseIn: CGRect(x: x,y: y,width: 3,height: 3)),with: .color(tint.opacity(0.8)))
            }
        }
        if stage == .drying {
            context.stroke(Path(roundedRect: film,cornerRadius: 2),with: .color(tint.opacity(Double(probe.water))),lineWidth: 3)
        }
        if stage == .scan {
            let scanner = film.insetBy(dx: -15,dy: -7)
            context.stroke(Path(roundedRect: scanner,cornerRadius: 5),with: .color(TVPropagationPalette.muted),lineWidth: 2)
            var beam = Path(); beam.move(to: CGPoint(x: film.minX,y: film.midY)); beam.addLine(to: CGPoint(x: film.maxX,y: film.midY))
            context.stroke(beam,with: .color(TVPropagationPalette.accent),lineWidth: 2)
        }
    }
}

private struct FilmLabSceneElement {
    let name: String, symbol: String
    let key: WritableKeyPath<FilmLabRecipe,Float>
    let range: ClosedRange<Float>
    let unit: String
    init(_ name: String,_ symbol: String,_ key: WritableKeyPath<FilmLabRecipe,Float>,_ range: ClosedRange<Float>,_ unit: String) {
        self.name = name; self.symbol = symbol; self.key = key; self.range = range; self.unit = unit
    }
}

private struct FilmLabSceneHandle: View {
    @Binding var recipe: FilmLabRecipe
    let element: FilmLabSceneElement
    let tint: Color
    @State private var start: Float?
    @State private var editing = false
    private var value: Binding<Float> { Binding(get: { recipe[keyPath: element.key] },set: { recipe[keyPath: element.key] = $0 }) }
    var body: some View {
        VStack(spacing: 2) {
            HStack(spacing: 4) { Image(systemName: element.symbol).foregroundStyle(tint); Text(element.name) }
            Text(String(format: element.unit == "K" ? "%.0f %@" : "%.2f %@",value.wrappedValue,element.unit))
                .monospacedDigit().foregroundStyle(TVPropagationPalette.muted)
        }.font(.system(size: 10)).frame(maxWidth: .infinity).padding(3)
            .background(tint.opacity(0.05),in: RoundedRectangle(cornerRadius: 4))
            .contentShape(Rectangle())
            .onTapGesture { editing = true }
            .gesture(DragGesture(minimumDistance: 4).onChanged { drag in
                if start == nil { start = value.wrappedValue }
                let delta = Float(drag.translation.height/100)*(element.range.upperBound-element.range.lowerBound)
                value.wrappedValue = min(element.range.upperBound,max(element.range.lowerBound,start!-delta))
            }.onEnded { _ in start = nil })
            .accessibilityElement(children: .ignore).accessibilityLabel(element.name)
            .accessibilityValue(String(format: "%.2f %@",value.wrappedValue,element.unit))
            .accessibilityAddTraits(.isButton)
            .accessibilityAction { editing = true }
            .accessibilityAdjustableAction { direction in
                let step = (element.range.upperBound-element.range.lowerBound)/100
                value.wrappedValue = min(element.range.upperBound,max(element.range.lowerBound,value.wrappedValue+(direction == .increment ? step : -step)))
            }
            .popover(isPresented: $editing) {
                ParameterSlider(name: element.name+" · "+element.unit,value: value,defaultValue: FilmLabRecipe()[keyPath: element.key],range: element.range)
                    .padding(16).frame(width: 240)
            }
    }
}
