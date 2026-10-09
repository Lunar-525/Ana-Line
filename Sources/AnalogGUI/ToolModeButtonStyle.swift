import SwiftUI

/// A single moving surface keeps the active button's shadow continuous.
struct ToolModeSwitch: View {
    @Binding var selection: EditingTool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        ZStack(alignment: .leading) {
            Rectangle().fill(Color.white)
            Rectangle()
                .fill(selection.logoAccentColor)
                .frame(width: 118, height: 48)
                .shadow(color: .black.opacity(0.35), radius: 5, y: 2)
                .offset(x: CGFloat(EditingTool.allCases.firstIndex(of: selection) ?? 0) * 118)
                .animation(reduceMotion ? nil : .timingCurve(0.22, 0.75, 0.25, 1, duration: 0.38),
                           value: selection)
            HStack(spacing: 0) {
                ForEach(EditingTool.allCases, id: \.self) { tool in
                    Button {
                        if selection != tool { selection = tool }
                    } label: {
                        Text(tool.rawValue)
                            .font(.system(size: 13, weight: .medium))
                            .frame(width: 118, height: 48)
                    }
                    .buttonStyle(ToolModeButtonStyle())
                    .accessibilityAddTraits(selection == tool ? .isSelected : [])
                }
            }
        }
        .frame(width: CGFloat(EditingTool.allCases.count) * 118, height: 48)
        .opacity(isEnabled ? 1 : 0.4)
        .accessibilityLabel(L("Tool"))
    }
}

struct ToolModeButtonStyle: ButtonStyle {

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(Color.black)
            .contentShape(Rectangle())
            .opacity(configuration.isPressed ? 0.65 : 1)
    }
}

struct HeaderImageButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(Color.black)
            .background {
                Rectangle().fill(
                    Color.white.shadow(.inner(color: .black.opacity(configuration.isPressed ? 0.4 : 0.25),
                                              radius: configuration.isPressed ? 6 : 4, x: 0, y: 2))
                )
            }
            .contentShape(Rectangle())
            .opacity(isEnabled ? 1 : 0.4)
    }
}
