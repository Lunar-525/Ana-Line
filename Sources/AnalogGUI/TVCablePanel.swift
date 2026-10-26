import SwiftUI
import AnalogImaging

/// The cable stage as the third lower rack column: cabinet, condition, interference.
/// The content is kept to roughly the height of the 01/03 rack columns.
struct TVCableColumn: View {
    @ObservedObject var model: PreviewModel
    private var settings: TVCableSettings { model.cableSettings }
    private var accent: Color { Color(red: 0.82, green: 0.7, blue: 0.36) }

    var body: some View {
        ScrollView(.vertical, showsIndicators: false) {
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text(L("CABLE / SIGNAL PATH"))
                        .font(.system(size: 12, weight: .semibold))
                    Spacer()
                    Text(settings.kind == .off ? "BYPASS" : "LINKED")
                        .font(.system(size: 8, weight: .medium, design: .monospaced))
                        .foregroundStyle(settings.kind == .off ? .white.opacity(0.35) : .green)
                }
                .foregroundStyle(.white.opacity(0.7))
                cabinet
                condition
                interference
            }
            .padding(.bottom, 4)
        }
        .frame(maxWidth: .infinity, maxHeight: 370, alignment: .topLeading)
        .environment(\.colorScheme, .dark)
    }

    private var cabinet: some View {
        VStack(alignment: .leading, spacing: 4) {
            moduleHeader("A · CABLE CABINET", detail: settings.kind == .off ? "NO CABLE" : "\(settings.kind.lineCount) LINE")
            HStack(spacing: 3) {
                ForEach(TVCableSettings.Kind.allCases, id: \.self) { kind in
                    Button { select(kind) } label: {
                        Text(kind.shortTitle)
                            .font(.system(size: 7, weight: .medium, design: .monospaced))
                            .lineLimit(1).minimumScaleFactor(0.7)
                            .foregroundStyle(kind == settings.kind ? .white : .white.opacity(0.55))
                            .frame(maxWidth: .infinity).frame(height: 20)
                            .background(kind == settings.kind ? accent.opacity(0.22) : Color.white.opacity(0.035))
                            .overlay(Rectangle().stroke(kind == settings.kind ? accent : Color.white.opacity(0.1),
                                lineWidth: kind == settings.kind ? 1 : 0.5))
                    }
                    .buttonStyle(.plain)
                }
            }
            TVCableDiagram(settings: settings)
        }
        .padding(6)
        .background(TVRackHousing(finish: .filter))
    }

    private var condition: some View {
        VStack(alignment: .leading, spacing: 4) {
            moduleHeader("B · CABLE CONDITION", detail: settings.kind == .off ? "—" : "75Ω")
            if settings.kind == .off {
                Text("Cable is bypassed.")
                    .font(.system(size: 9)).foregroundStyle(.white.opacity(0.35))
                    .frame(height: 54)
            } else {
                HStack(alignment: .top, spacing: 4) {
                    cableCard
                    ForEach(0..<settings.kind.lineCount, id: \.self) { index in
                        lineCard(index)
                    }
                }
            }
        }
        .padding(6)
        .background(TVRackHousing(finish: .transmitter))
    }

    private var cableCard: some View {
        VStack(spacing: 2) {
            Text("CABLE").font(.system(size: 6.5, weight: .semibold, design: .monospaced))
                .foregroundStyle(.white.opacity(0.55))
            HStack(spacing: 2) {
                verticalFader("Z", value: binding(\.cableImpedance), range: 50...100,
                    format: { "\(Int($0.rounded()))" })
                verticalFader("H", value: binding(\.cableHealth), range: 0...1,
                    format: { "\(Int(($0 * 100).rounded()))" })
            }
        }
        .padding(3)
        .frame(maxWidth: .infinity)
        .background(Color.white.opacity(0.03))
    }

    private func lineCard(_ index: Int) -> some View {
        let name = settings.kind.lineNames[index]
        let line = settings.lines[index]
        return VStack(spacing: 2) {
            HStack(spacing: 3) {
                Circle().fill(lineColor(index, name)).frame(width: 4, height: 4)
                Text(name).font(.system(size: 6.5, weight: .semibold, design: .monospaced))
                Spacer(minLength: 0)
                Button { lineBinding(index, \.connected).wrappedValue.toggle() } label: {
                    Text(line.connected ? "CON" : "OPEN")
                        .font(.system(size: 5.5, weight: .medium, design: .monospaced))
                        .foregroundStyle(line.connected ? .white.opacity(0.55) : .orange)
                }.buttonStyle(.plain)
            }
            HStack(spacing: 2) {
                verticalFader("Z", value: lineBinding(index, \.connectorImpedance),
                    range: 50...100, format: { "\(Int($0.rounded()))" })
                verticalFader("H", value: lineBinding(index, \.connectorHealth),
                    range: 0...1, format: { "\(Int(($0 * 100).rounded()))" })
                verticalFader("T", value: lineBinding(index, \.tightness),
                    range: 0...1, format: { "\(Int(($0 * 100).rounded()))" })
            }
        }
        .padding(3)
        .frame(maxWidth: .infinity)
        .background(Color.white.opacity(0.03))
    }

    private func verticalFader(_ label: String, value: Binding<Double>,
                                range: ClosedRange<Double>,
                                format: @escaping (Double) -> String) -> some View {
        TVCableFader(label: label, value: value, range: range, accent: accent, format: format)
            .frame(width: 22, height: 64)
    }

    private var interference: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                moduleHeader("C · INTERFERENCE")
                Spacer(minLength: 0)
                Menu {
                    ForEach(TVCableSettings.Interference.Kind.allCases, id: \.self) { kind in
                        Button(kind.title) { addInterference(kind) }
                    }
                } label: {
                    Text("+ ADD")
                        .font(.system(size: 7, weight: .medium, design: .monospaced))
                        .foregroundStyle(.white.opacity(0.55))
                }
                .menuStyle(.borderlessButton).fixedSize()
            }
            if settings.interferences.isEmpty {
                Text("No interference sources.")
                    .font(.system(size: 9)).foregroundStyle(.white.opacity(0.35))
                    .frame(height: 58)
            } else {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(alignment: .top, spacing: 5) {
                        ForEach(Array(settings.interferences.enumerated()), id: \.element.id) { index, source in
                            interferenceCard(index: index, source: source)
                        }
                    }
                    .padding(.vertical, 1)
                }
                .frame(height: 88)
            }
        }
        .padding(6)
        .background(TVRackHousing(finish: .encoder))
    }

    private func interferenceCard(index: Int, source: TVCableSettings.Interference) -> some View {
        VStack(spacing: 3) {
            HStack(spacing: 3) {
                Circle().fill(source.enabled ? .orange : .white.opacity(0.2)).frame(width: 4, height: 4)
                Text(shortTitle(source.kind)).font(.system(size: 6.5, weight: .medium, design: .monospaced))
                Spacer(minLength: 0)
                Button { interferenceBinding(index, \.enabled).wrappedValue.toggle() } label: {
                    Text(source.enabled ? "ON" : "OFF")
                        .font(.system(size: 5.5, design: .monospaced))
                        .foregroundStyle(source.enabled ? .orange : .white.opacity(0.35))
                }.buttonStyle(.plain)
                Button { removeInterference(index) } label: {
                    Image(systemName: "minus.circle").font(.system(size: 7))
                }.buttonStyle(.plain).foregroundStyle(.orange)
            }
            HStack(spacing: 2) {
                TVRotaryParameter(name: "Level", value: floatInterferenceBinding(index, \.intensity),
                    range: 0...1, initial: 0.5, step: 0.01, digits: 0, percent: true, horizontal: true)
                TVRotaryParameter(name: "Dist", value: floatInterferenceBinding(index, \.distance),
                    range: 0...1, initial: 0.3, step: 0.01, digits: 0, percent: true, horizontal: true)
            }
        }
        .padding(4)
        .frame(width: 150)
        .background(Color.white.opacity(0.035))
    }

    private func shortTitle(_ kind: TVCableSettings.Interference.Kind) -> String {
        switch kind {
        case .mains: return "220V"
        case .microwave: return "MICRO"
        case .compressor: return "COMP"
        case .transformer: return "XFMR"
        case .groundPotential: return "GND"
        }
    }

    private func moduleHeader(_ title: String, detail: String? = nil) -> some View {
        HStack(spacing: 5) {
            Text(title)
                .font(.system(size: 8, weight: .semibold, design: .monospaced))
                .tracking(0.5)
                .foregroundStyle(.white.opacity(0.75))
            if let detail {
                Text(detail)
                    .font(.system(size: 6, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.35))
            }
            Spacer(minLength: 0)
        }
    }

    private func select(_ kind: TVCableSettings.Kind) {
        var value = model.cableSettings
        value.kind = kind
        value.normalize()
        model.cableSettings = value
    }

    private func binding(_ path: WritableKeyPath<TVCableSettings, Double>) -> Binding<Double> {
        Binding(get: { model.cableSettings[keyPath: path] }, set: { value in
            var settings = model.cableSettings
            settings[keyPath: path] = value
            settings.normalize()
            model.cableSettings = settings
        })
    }

    private func lineBinding(_ index: Int,
                             _ path: WritableKeyPath<TVCableSettings.Line, Bool>) -> Binding<Bool> {
        Binding(get: {
            guard model.cableSettings.lines.indices.contains(index) else { return true }
            return model.cableSettings.lines[index][keyPath: path]
        }, set: { value in
            var settings = model.cableSettings
            guard settings.lines.indices.contains(index) else { return }
            settings.lines[index][keyPath: path] = value
            model.cableSettings = settings
        })
    }

    private func lineBinding(_ index: Int,
                             _ path: WritableKeyPath<TVCableSettings.Line, Double>) -> Binding<Double> {
        Binding(get: {
            guard model.cableSettings.lines.indices.contains(index) else { return 75 }
            return model.cableSettings.lines[index][keyPath: path]
        }, set: { value in
            var settings = model.cableSettings
            guard settings.lines.indices.contains(index) else { return }
            settings.lines[index][keyPath: path] = value
            settings.normalize()
            model.cableSettings = settings
        })
    }

    private func interferenceBinding<T>(_ index: Int,
                                        _ path: WritableKeyPath<TVCableSettings.Interference, T>) -> Binding<T> {
        Binding(get: {
            guard model.cableSettings.interferences.indices.contains(index) else {
                return TVCableSettings.Interference(kind: .mains)[keyPath: path]
            }
            return model.cableSettings.interferences[index][keyPath: path]
        }, set: { value in
            var settings = model.cableSettings
            guard settings.interferences.indices.contains(index) else { return }
            settings.interferences[index][keyPath: path] = value
            settings.normalize()
            model.cableSettings = settings
        })
    }

    private func floatInterferenceBinding(_ index: Int,
                                          _ path: WritableKeyPath<TVCableSettings.Interference, Double>) -> Binding<Float> {
        Binding(get: {
            guard model.cableSettings.interferences.indices.contains(index) else { return 0 }
            return Float(model.cableSettings.interferences[index][keyPath: path])
        }, set: { value in
            var settings = model.cableSettings
            guard settings.interferences.indices.contains(index) else { return }
            settings.interferences[index][keyPath: path] = Double(value)
            settings.normalize()
            model.cableSettings = settings
        })
    }

    private func addInterference(_ kind: TVCableSettings.Interference.Kind) {
        var settings = model.cableSettings
        settings.interferences.append(.init(kind: kind))
        model.cableSettings = settings
    }

    private func removeInterference(_ index: Int) {
        var settings = model.cableSettings
        guard settings.interferences.indices.contains(index) else { return }
        settings.interferences.remove(at: index)
        model.cableSettings = settings
    }

    private func lineColor(_ index: Int, _ name: String) -> Color {
        switch name {
        case "Y": return Color(red: 0.35, green: 0.9, blue: 0.45)
        case "Pb": return Color(red: 0.35, green: 0.55, blue: 1)
        case "Pr": return Color(red: 1, green: 0.35, blue: 0.35)
        case "C": return Color(red: 0.3, green: 0.85, blue: 0.95)
        default: return Color(red: 0.95, green: 0.82, blue: 0.35)
        }
    }
}

private struct TVCableFader: View {
    let label: String
    @Binding var value: Double
    let range: ClosedRange<Double>
    let accent: Color
    let format: (Double) -> String

    var body: some View {
        VStack(spacing: 1) {
            Text(format(value))
                .font(.system(size: 5.5, design: .monospaced))
                .foregroundStyle(.white.opacity(0.7))
                .fixedSize()
            GeometryReader { geometry in
                let height = max(1, geometry.size.height)
                let fraction = min(1, max(0, (value - range.lowerBound) / (range.upperBound - range.lowerBound)))
                ZStack(alignment: .bottom) {
                    RoundedRectangle(cornerRadius: 2).fill(.black.opacity(0.55))
                    RoundedRectangle(cornerRadius: 2).fill(accent.opacity(0.55))
                        .frame(height: max(2, height * fraction))
                    Rectangle().fill(.white.opacity(0.85))
                        .frame(height: 1.5)
                        .offset(y: -max(0, height * fraction - 0.75))
                }
                .contentShape(Rectangle())
                .gesture(DragGesture(minimumDistance: 0).onChanged { drag in
                    let f = min(1, max(0, 1 - drag.location.y / height))
                    value = range.lowerBound + Double(f) * (range.upperBound - range.lowerBound)
                })
            }
            Text(label)
                .font(.system(size: 5.5, weight: .medium, design: .monospaced))
                .foregroundStyle(.white.opacity(0.45))
        }
    }
}

struct TVCableDiagram: View {
    let settings: TVCableSettings
    private var names: [String] { settings.kind.lineNames }

    var body: some View {
        HStack(spacing: 0) {
            connector("RX", sub: "OUT")
            VStack(spacing: 3) {
                if names.isEmpty {
                    Text("BYPASS")
                        .font(.system(size: 7, weight: .medium, design: .monospaced))
                        .foregroundStyle(.white.opacity(0.35))
                } else {
                    ForEach(Array(names.enumerated()), id: \.offset) { index, name in
                        HStack(spacing: 3) {
                            Circle().fill(lineColor(name)).frame(width: 3, height: 3)
                            Text(name).font(.system(size: 5.5, weight: .medium, design: .monospaced))
                                .frame(width: 16, alignment: .leading)
                            line(name: name, index: index)
                            Text(settings.lines.indices.contains(index) && settings.lines[index].connected
                                ? "75Ω" : "OPEN")
                                .font(.system(size: 5, design: .monospaced))
                                .foregroundStyle(.white.opacity(0.35))
                                .frame(width: 20, alignment: .trailing)
                        }
                    }
                }
            }
            .padding(.horizontal, 5)
            connector("CRT", sub: "IN")
        }
        .padding(4)
        .frame(height: names.isEmpty ? 38 : CGFloat(18 + names.count * 12))
        .background(RoundedRectangle(cornerRadius: 3).fill(Color(white: 0.10)))
        .overlay(alignment: .topTrailing) {
            HStack(spacing: 2) {
                ForEach(settings.interferences.filter(\.enabled)) { source in
                    Text(badge(source.kind))
                        .font(.system(size: 4.5, weight: .medium, design: .monospaced))
                        .foregroundStyle(.orange)
                        .padding(.horizontal, 1.5).padding(.vertical, 0.5)
                        .background(RoundedRectangle(cornerRadius: 1).stroke(.orange.opacity(0.45)))
                }
            }.padding(3)
        }
    }

    private func badge(_ kind: TVCableSettings.Interference.Kind) -> String {
        switch kind {
        case .mains: return "220V"
        case .microwave: return "MICRO"
        case .compressor: return "COMP"
        case .transformer: return "XFMR"
        case .groundPotential: return "GND"
        }
    }

    private func line(name: String, index: Int) -> some View {
        let connected = settings.lines.indices.contains(index) && settings.lines[index].connected
        let color = lineColor(name)
        return ZStack {
            Rectangle().fill(color.opacity(connected ? 0.7 : 0.1))
                .frame(maxWidth: .infinity).frame(height: 1.5)
            if !connected {
                Rectangle().fill(Color(white: 0.10)).frame(width: 9, height: 4)
                Text("OPEN").font(.system(size: 4.5, design: .monospaced)).foregroundStyle(.orange)
            }
        }.frame(height: 4)
    }

    private func connector(_ title: String, sub: String) -> some View {
        VStack(spacing: 0) {
            RoundedRectangle(cornerRadius: 2)
                .fill(LinearGradient(colors: [Color(white: 0.34), Color(white: 0.17)],
                    startPoint: .top, endPoint: .bottom))
                .frame(width: 22, height: 17)
                .overlay(RoundedRectangle(cornerRadius: 2).stroke(.black.opacity(0.7)))
                .overlay(Text("◉").font(.system(size: 7)).foregroundStyle(.white.opacity(0.45)))
            Text(title).font(.system(size: 4.5, weight: .medium, design: .monospaced))
            Text(sub).font(.system(size: 4, design: .monospaced)).foregroundStyle(.white.opacity(0.3))
        }
        .foregroundStyle(.white.opacity(0.55))
    }

    private func lineColor(_ name: String) -> Color {
        switch name {
        case "Y": return Color(red: 0.35, green: 0.9, blue: 0.45)
        case "Pb": return Color(red: 0.35, green: 0.55, blue: 1)
        case "Pr": return Color(red: 1, green: 0.35, blue: 0.35)
        case "C": return Color(red: 0.3, green: 0.85, blue: 0.95)
        default: return Color(red: 0.95, green: 0.82, blue: 0.35)
        }
    }
}
