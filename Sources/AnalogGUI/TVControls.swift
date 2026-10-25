import SwiftUI
import AnalogCore

struct TVParameterGroupStyle: GroupBoxStyle {
    func makeBody(configuration: Configuration) -> some View {
        VStack(alignment: .leading,spacing: 8) {
            configuration.label.font(.system(size: 11,weight: .medium))
            configuration.content.frame(maxWidth: .infinity,alignment: .leading)
        }.padding(10).background(Rectangle().stroke(.black.opacity(0.12),lineWidth: 1))
    }
}

struct TVSignalPanel<Content: View>: View {
    let title: String
    @ViewBuilder var content: Content
    var body: some View {
        VStack(alignment: .leading,spacing: 12) {
            Text(L(title)).font(.system(size: 12,weight: .semibold))
            content
        }.padding(14).foregroundStyle(.black)
            .background(Rectangle().fill(.white).shadow(color: .black.opacity(0.35),radius: 5,y: 2))
            .environment(\.colorScheme,.light).groupBoxStyle(TVParameterGroupStyle()).tint(EditingTool.tv.logoAccentColor)
    }
}

struct TVControls: View {
    @ObservedObject var model: TVControlState
    init(model: PreviewModel) { model.tvControlState.bind(model); self.model = model.tvControlState }
    init(state: TVControlState) { self.model = state }
    var body: some View {
        HStack(spacing: 10) {
            TVCRTControls()
            TVBroadcastStandardSwitch(selection: $model.tvStandard)
            TVSimulationProfileSwitch(selection: Binding(
                get: { model.tvChannel.performance == .mobile },
                set: { model.tvChannel.performance = $0 ? .mobile : .full }))
            Button { model.owner?.exportTVVideo() } label: {
                Text(L("Render and Export…"))
                    .font(.system(size: 13, weight: .medium))
                    .lineLimit(1).minimumScaleFactor(0.7)
                    .frame(maxWidth: .infinity).frame(height: 48)
                    .background(Rectangle().fill(.white)
                        .shadow(color: .black.opacity(0.35), radius: 5, y: 2))
            }
            .buttonStyle(ToolModeButtonStyle())
            .disabled(model.tvDuration <= 0)
            .opacity(model.tvDuration > 0 ? 1 : 0.4)
        }
        .disabled(model.busy)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct TVSimulationProfileSwitch: View {
    @Binding var selection: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.isEnabled) private var isEnabled

    @State private var hovered: Bool?

    var body: some View {
        GeometryReader { geometry in
            let width = geometry.size.width / 2
            ZStack(alignment: .leading) {
                Rectangle().fill(.white)
                    .shadow(color: .black.opacity(0.35), radius: 5, y: 2)
                Rectangle().fill(EditingTool.tv.logoAccentColor)
                    .frame(width: width, height: 48)
                    .overlay {
                        TVProfileTexture(fast: selection, energized: hovered == selection && isEnabled,
                            reduceMotion: reduceMotion)
                            .clipped().allowsHitTesting(false).accessibilityHidden(true)
                    }
                    .shadow(color: .black.opacity(0.35), radius: 5, y: 2)
                    .offset(x: selection ? width : 0)
                    .animation(reduceMotion ? nil : .timingCurve(0.22, 0.75, 0.25, 1, duration: 0.38), value: selection)
                HStack(spacing: 0) {
                    ForEach([false, true], id: \.self) { standard in
                        Button {
                            if selection != standard { selection = standard }
                        } label: {
                            HStack(spacing: 4) {
                                Image(systemName: standard ? "bolt.fill" : "scope")
                                    .font(.system(size: 10, weight: .semibold))
                                    .scaleEffect(hovered == standard && !reduceMotion ? 1.12 : 1)
                                    .animation(reduceMotion ? nil : .easeOut(duration: 0.18), value: hovered)
                                Text(standard ? "Fast" : "Full")
                            }
                                .font(.system(size: 13, weight: .medium))
                                .lineLimit(1).minimumScaleFactor(0.7)
                                .frame(width: width, height: 48)
                        }
                        .buttonStyle(ToolModeButtonStyle())
                        .onHover { inside in hovered = inside ? standard : nil }
                        .help(info(for: standard))
                        .accessibilityHint(info(for: standard))
                        .accessibilityAddTraits(selection == standard ? .isSelected : [])
                    }
                }
            }
        }
        .frame(height: 48)
        .opacity(isEnabled ? 1 : 0.4)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(L("Simulation quality"))
    }

    private func info(for value: Bool) -> String {
        value ? L("Fast · accelerated simulation with validated precision trade-offs")
            : L("Full · reference precision for reproducible simulation")
    }
}

/// Static geometry with event-driven animation: no display timer during playback.
private struct TVProfileTexture: View {
    let fast: Bool
    let energized: Bool
    let reduceMotion: Bool

    var body: some View {
        Canvas { context, size in
            var path = Path()
            if fast {
                for row in 0..<5 {
                    let y = CGFloat(row)*11 + 3
                    path.move(to: CGPoint(x: size.width*0.12, y: y+5))
                    path.addLine(to: CGPoint(x: size.width*0.88, y: y-5))
                }
                context.stroke(path, with: .linearGradient(
                    Gradient(colors: [.white.opacity(0), .white.opacity(0.55)]),
                    startPoint: .zero, endPoint: CGPoint(x: size.width, y: 0)),
                    style: StrokeStyle(lineWidth: 2, lineCap: .round))
            } else {
                for x in stride(from: CGFloat(0), through: size.width, by: 8) {
                    path.move(to: CGPoint(x: x, y: 0)); path.addLine(to: CGPoint(x: x, y: size.height))
                }
                for y in stride(from: CGFloat(0), through: size.height, by: 8) {
                    path.move(to: CGPoint(x: 0, y: y)); path.addLine(to: CGPoint(x: size.width, y: y))
                }
                context.stroke(path, with: .color(.white.opacity(0.25)), lineWidth: 0.5)
            }
        }
        .offset(x: fast && energized && !reduceMotion ? 7 : 0)
        .opacity(energized ? 1 : 0.6)
        .animation(reduceMotion ? nil : .easeOut(duration: fast ? 0.14 : 0.3), value: energized)
    }
}

private struct TVBroadcastStandardSwitch: View {
    @Binding var selection: TVStandard
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        GeometryReader { geometry in
            let width = geometry.size.width / 2
            ZStack(alignment: .leading) {
                Rectangle().fill(.white)
                    .shadow(color: .black.opacity(0.35), radius: 5, y: 2)
                Rectangle().fill(EditingTool.tv.logoAccentColor)
                    .frame(width: width, height: 48)
                    .shadow(color: .black.opacity(0.35), radius: 5, y: 2)
                    .offset(x: selection == .pal ? 0 : width)
                    .animation(reduceMotion ? nil : .timingCurve(0.22, 0.75, 0.25, 1, duration: 0.38), value: selection)
                HStack(spacing: 0) {
                    ForEach(TVStandard.allCases, id: \.self) { standard in
                        Button {
                            if selection != standard { selection = standard }
                        } label: {
                            Text(standard == .pal ? "PAL-D/K" : "NTSC-M")
                                .font(.system(size: 13, weight: .medium))
                                .lineLimit(1).minimumScaleFactor(0.7)
                                .frame(width: width, height: 48)
                        }
                        .buttonStyle(ToolModeButtonStyle())
                        .help(info(for: standard))
                        .accessibilityHint(info(for: standard))
                        .accessibilityAddTraits(selection == standard ? .isSelected : [])
                    }
                }
            }
        }
        .frame(height: 48)
        .opacity(isEnabled ? 1 : 0.4)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(L("Broadcast standard"))
    }

    private func info(for standard: TVStandard) -> String {
        let timing = standard == .pal ? "625 / 50 · 8 MHz" : "525 / 59.94 · 6 MHz"
        let sound = standard == .pal ? "FM +6.5 MHz · ±50 kHz · 50 μs" : "FM +4.5 MHz · ±25 kHz · 75 μs"
        return "\(timing)\n\(L("VSB vision + mono FM sound"))\n\(sound)"
    }
}

struct TVTunerControls: View {
    @ObservedObject var model: TVControlState
    init(model: PreviewModel) { model.tvControlState.bind(model); self.model = model.tvControlState }
    init(state: TVControlState) { self.model = state }
    private var defaults: TerrestrialSettings { TerrestrialSettings(system: model.terrestrialSystem) }
    var body: some View {
        GroupBox(L("Tuner / receiver")) {
                    VStack(alignment: .leading, spacing: 12) {
                        ParameterSlider(name: L("Tuning offset · kHz"), value: $model.tvChannel.tuningOffsetKHz,
                            defaultValue: defaults.tuningOffsetKHz, range: -1500...1500)
                        ParameterSlider(name: L("IF bandwidth · MHz"), value: $model.tvChannel.rfBandwidthMHz,
                            defaultValue: defaults.rfBandwidthMHz, range: 1...10)
                        Toggle(L("Automatic fine tuning"), isOn: $model.tvChannel.automaticFineTuning)
                        Toggle(L("Automatic gain control"), isOn: $model.tvChannel.automaticGain)
                        if !model.tvChannel.automaticGain {
                            ParameterSlider(name: L("Receiver gain · dB"), value: $model.tvChannel.manualGainDB,
                                defaultValue: defaults.manualGainDB, range: -12...60)
                        }
                        Button(L("Reset reception")) {
                            var reset = defaults
                            reset.propagation = model.tvChannel.propagation
                            reset.transmitter = model.tvChannel.transmitter
                            reset.performance = model.tvChannel.performance
                            model.tvChannel = reset
                        }
                    }.padding(.top, 6)
                }
    }
}
