import SwiftUI
import AnalogCore

/// Matches the television standard selector: one continuous moving surface.
struct RadioSelectionStrip<Option: Hashable>: View {
    let options: [Option]
    @Binding var selection: Option
    let label: (Option) -> String
    var height: CGFloat = 48
    var texture = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.isEnabled) private var enabled
    @State private var hovered: Option?
    private let accent = EditingTool.radio.logoAccentColor
    var body: some View {
        GeometryReader { geometry in
            let width = geometry.size.width/CGFloat(max(1, options.count))
            ZStack(alignment: .leading) {
                Rectangle().fill(.white).shadow(color: .black.opacity(0.35), radius: 5, y: 2)
                Rectangle().fill(accent)
                    .frame(width: width, height: height)
                    .overlay {
                        if texture {
                            Canvas { context, size in
                                var grid = Path()
                                for x in stride(from: CGFloat(0), through: size.width, by: 8) {
                                    grid.move(to: CGPoint(x: x, y: 0)); grid.addLine(to: CGPoint(x: x, y: size.height))
                                }
                                for y in stride(from: CGFloat(0), through: size.height, by: 8) {
                                    grid.move(to: CGPoint(x: 0, y: y)); grid.addLine(to: CGPoint(x: size.width, y: y))
                                }
                                context.stroke(grid, with: .color(.white.opacity(0.25)), lineWidth: 0.5)
                            }
                            .opacity(hovered == selection && enabled ? 1 : 0.6)
                            .animation(reduceMotion ? nil : .easeOut(duration: 0.3), value: hovered)
                            .allowsHitTesting(false).accessibilityHidden(true)
                        }
                    }
                    .shadow(color: .black.opacity(0.35), radius: 5, y: 2)
                    .offset(x: CGFloat(options.firstIndex(of: selection) ?? 0)*width)
                    .animation(reduceMotion ? nil : .timingCurve(0.22, 0.75, 0.25, 1, duration: 0.38), value: selection)
                HStack(spacing: 0) {
                    ForEach(options, id: \.self) { option in
                        Button { if selection != option { selection = option } } label: {
                            Text(label(option)).font(.system(size: height == 48 ? 13 : 10, weight: .medium))
                                .lineLimit(1).minimumScaleFactor(0.7).frame(width: width, height: height)
                        }.buttonStyle(ToolModeButtonStyle())
                            .onHover { hovered = $0 ? option : nil }
                            .accessibilityAddTraits(selection == option ? .isSelected : [])
                    }
                }
            }
        }.frame(height: height).opacity(enabled ? 1 : 0.4)
            .accessibilityElement(children: .contain)
    }
}

struct RadioActionButton: View {
    let title: String
    let symbol: String
    let action: () -> Void
    @Environment(\.isEnabled) private var enabled
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var hovered = false
    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: symbol).font(.system(size: 10, weight: .semibold))
                    .scaleEffect(hovered && enabled && !reduceMotion ? 1.12 : 1)
                    .animation(reduceMotion ? nil : .easeOut(duration: 0.18), value: hovered)
                Text(title).font(.system(size: 13, weight: .medium))
                    .lineLimit(1).minimumScaleFactor(0.7)
            }.frame(maxWidth: .infinity).frame(height: 48)
                .background(Rectangle().fill(.white).shadow(color: .black.opacity(0.35), radius: 5, y: 2))
        }.buttonStyle(ToolModeButtonStyle()).opacity(enabled ? 1 : 0.4)
            .onHover { hovered = $0 }.accessibilityLabel(title)
    }
}

struct RadioPanelSurface: ViewModifier {
    func body(content: Content) -> some View {
        content.foregroundStyle(TVPropagationPalette.ink)
            .background(Rectangle().fill(TVPropagationPalette.panel).shadow(color: .black.opacity(0.4), radius: 5, y: 2))
            .overlay(Rectangle().stroke(TVPropagationPalette.ink.opacity(0.08), lineWidth: 1).allowsHitTesting(false))
            .environment(\.colorScheme, .dark).tint(EditingTool.radio.logoAccentColor)
    }
}

/// Uses the television's native silver dial and editable seven-segment readout.
struct RadioRotaryParameter: View {
    let name: String
    @Binding var value: Double
    let range: ClosedRange<Double>
    let initial: Double
    var scale = 1.0
    var step: Float = 0.1
    var unit = ""
    var digits = 1
    var percent = false
    var body: some View {
        TVRotaryParameter(name: name, value: Binding(
            get: { Float(value/scale) }, set: { value = Double($0)*scale }),
            range: Float(range.lowerBound/scale)...Float(range.upperBound/scale),
            initial: Float(initial/scale), step: step, unit: unit, digits: digits, percent: percent)
    }
}
