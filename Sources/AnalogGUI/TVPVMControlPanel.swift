import SwiftUI

/// A vertical PVM-style front-panel strip. The MENU key opens the OSD; the
/// arrow and ENTER keys drive the same navigation state as the OSD rows.
struct TVPVMControlPanel: View {
    @ObservedObject var state: TVOSDState
    @AppStorage("tvCRTEnabled") private var enabled = false

    var body: some View {
        ZStack {
            panelBackground
            VStack(spacing: 7) {
                brand
                power
                Rectangle().fill(.white.opacity(0.10)).frame(width: 44, height: 1)
                key("MENU", active: state.isOpen, enabledWhen: enabled) { state.menu() }
                key("UP", enabledWhen: state.isOpen) { state.up() }
                key("DOWN", enabledWhen: state.isOpen) { state.down() }
                key("ENTER", enabledWhen: state.isOpen) { state.enter() }
                Spacer(minLength: 0)
                speaker
                status
            }
            .padding(.vertical, 11)
            .frame(maxHeight: .infinity)
            screws
        }
        .frame(width: 70, height: 480)
        .overlay(Rectangle().stroke(.black.opacity(0.65), lineWidth: 1))
        .shadow(color: .black.opacity(0.45), radius: 5, x: 3, y: 0)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("CRT control panel")
    }

    private var panelBackground: some View {
        ZStack {
            LinearGradient(colors: [Color(white: 0.30), Color(white: 0.16), Color(white: 0.10)],
                startPoint: .top, endPoint: .bottom)
            Canvas { context, size in
                var x = 0.0
                while x < size.width {
                    var line = Path()
                    line.move(to: CGPoint(x: x, y: 0))
                    line.addLine(to: CGPoint(x: x, y: size.height))
                    context.stroke(line, with: .color(.white.opacity(0.028)), lineWidth: 1)
                    x += 2
                }
            }
            LinearGradient(colors: [.white.opacity(0.12), .clear, .black.opacity(0.24)],
                startPoint: .leading, endPoint: .trailing)
        }
    }

    private var brand: some View {
        VStack(spacing: 2) {
            Text("CRT")
                .font(.system(size: 16, weight: .heavy, design: .monospaced))
                .tracking(2)
            Text("MULTI FORMAT")
                .font(.system(size: 5.5, weight: .medium, design: .monospaced))
                .tracking(0.6)
        }
        .foregroundStyle(.white.opacity(0.78))
        .padding(.bottom, 2)
    }

    private var power: some View {
        Button { state.togglePower() } label: {
            VStack(spacing: 4) {
                Circle()
                    .fill(enabled ? Color.green : Color.red.opacity(0.8))
                    .frame(width: 7, height: 7)
                    .shadow(color: enabled ? .green.opacity(0.8) : .red.opacity(0.5), radius: 4)
                Text("POWER")
                    .font(.system(size: 8, weight: .semibold, design: .monospaced))
                    .tracking(0.5)
            }
            .frame(width: 52, height: 38)
        }
        .buttonStyle(PVMKeyStyle())
        .help("CRT power")
        .accessibilityLabel(enabled ? "CRT power on. Turn off" : "CRT power off. Turn on")
    }

    private func key(_ label: String, active: Bool = false,
                     enabledWhen: Bool = true, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(label)
                .font(.system(size: label == "ENTER" ? 8 : 9, weight: .semibold, design: .monospaced))
                .tracking(0.5)
                .frame(width: 52, height: 34)
        }
        .buttonStyle(PVMKeyStyle(active: active))
        .disabled(!enabledWhen)
        .opacity(enabledWhen ? 1 : 0.38)
        .accessibilityLabel(label)
    }

    private var speaker: some View {
        VStack(spacing: 4) {
            ForEach(0..<4, id: \.self) { _ in
                Capsule()
                    .fill(.black.opacity(0.55))
                    .frame(width: 40, height: 3)
                    .overlay(Capsule().stroke(.white.opacity(0.06), lineWidth: 0.5))
            }
        }
        .padding(.bottom, 8)
        .allowsHitTesting(false)
    }

    private var status: some View {
        VStack(spacing: 3) {
            Text("OSD")
                .font(.system(size: 6, weight: .medium, design: .monospaced))
                .tracking(1)
            Circle()
                .fill(state.isOpen ? Color.orange : Color.white.opacity(0.18))
                .frame(width: 4, height: 4)
            Text("PRO")
                .font(.system(size: 6, weight: .medium, design: .monospaced))
                .tracking(0.8)
        }
        .foregroundStyle(.white.opacity(0.38))
    }

    private var screws: some View {
        VStack {
            HStack { screw; Spacer(); screw }
            Spacer()
            HStack { screw; Spacer(); screw }
        }
        .padding(6)
        .allowsHitTesting(false)
    }

    private var screw: some View {
        ZStack {
            Circle().fill(Color(white: 0.12))
                .frame(width: 6, height: 6)
                .overlay(Circle().stroke(.white.opacity(0.18), lineWidth: 0.5))
            Rectangle().fill(.white.opacity(0.28)).frame(width: 4, height: 0.5)
                .rotationEffect(.degrees(35))
        }
    }
}

private struct PVMKeyStyle: ButtonStyle {
    var active = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(.white.opacity(configuration.isPressed ? 0.55 : active ? 0.98 : 0.82))
            .background(
                RoundedRectangle(cornerRadius: 2)
                    .fill(LinearGradient(colors: configuration.isPressed
                        ? [Color(white: 0.12), Color(white: 0.22)]
                        : [Color(white: 0.34), Color(white: 0.17)],
                        startPoint: .top, endPoint: .bottom))
                    .overlay(RoundedRectangle(cornerRadius: 2)
                        .stroke(.black.opacity(0.8), lineWidth: 1))
                    .overlay(alignment: .top) {
                        Rectangle().fill(.white.opacity(configuration.isPressed ? 0.06 : 0.22))
                            .frame(height: 1).padding(.horizontal, 3).padding(.top, 1)
                    }
            )
            .scaleEffect(configuration.isPressed ? 0.985 : 1)
            .offset(y: configuration.isPressed ? 1 : 0)
            .shadow(color: .black.opacity(0.5), radius: 1, y: 1.5)
    }
}
