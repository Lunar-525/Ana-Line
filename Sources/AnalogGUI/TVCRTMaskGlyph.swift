import SwiftUI

/// Small phosphor-arrangement diagram for the CRT panel selector.
struct TVCRTMaskGlyph: View {
    let type: TVCRTMaskType

    var body: some View {
        Canvas { context, size in
            context.fill(Path(CGRect(origin: .zero, size: size)), with: .color(.black))
            switch type {
            case .apertureGrille:
                drawGrille(&context, size: size, wires: true)
            case .shadowMask:
                drawLattice(&context, size: size, hexagonal: false)
            case .slotMask:
                drawSlots(&context, size: size, staggered: true)
            case .inlineShadowMask:
                drawSlots(&context, size: size, staggered: false)
            case .hexagonalMask:
                drawLattice(&context, size: size, hexagonal: true)
            case .horizontalStripes:
                drawHorizontal(&context, size: size)
            case .beamIndex:
                drawGrille(&context, size: size, wires: false)
            }
        }
        .overlay(RoundedRectangle(cornerRadius: 3)
            .stroke(.white.opacity(0.22), lineWidth: 0.6))
        .clipShape(RoundedRectangle(cornerRadius: 3))
        .accessibilityHidden(true)
    }

    private func phosphor(_ index: Int) -> Color {
        switch index {
        case 0: return Color(red: 1.0, green: 0.22, blue: 0.18)
        case 1: return Color(red: 0.25, green: 1.0, blue: 0.35)
        default: return Color(red: 0.30, green: 0.52, blue: 1.0)
        }
    }

    private func fill(_ context: inout GraphicsContext, _ rect: CGRect, _ index: Int) {
        let radius = min(rect.width, rect.height) * 0.35
        context.fill(Path(roundedRect: rect, cornerRadius: radius),
            with: .color(phosphor(index)))
    }

    private func drawGrille(_ context: inout GraphicsContext, size: CGSize, wires: Bool) {
        let triads = 3
        let stripe = size.width / CGFloat(triads * 3)
        for triad in 0..<triads {
            for primary in 0..<3 {
                let x = CGFloat(triad * 3 + primary) * stripe
                fill(&context, CGRect(x: x + 0.35, y: 0.8,
                    width: max(1, stripe - 0.7), height: size.height - 1.6), primary)
            }
        }
        // The two horizontal damping wires are the Trinitron signature.
        for y in wires ? [size.height / 3, size.height * 2 / 3] : [] {
            context.fill(Path(CGRect(x: 0, y: y - 0.6, width: size.width, height: 1.2)),
                with: .color(.black.opacity(0.9)))
        }
    }

    private func drawLattice(_ context: inout GraphicsContext, size: CGSize, hexagonal: Bool) {
        let spacing = size.width / 6
        let dy = spacing * sqrt(3) / 2
        for row in 0..<4 {
            for column in 0..<6 {
                let x = (CGFloat(column) + 0.4 + (row % 2 == 1 ? 0.5 : 0)) * spacing
                let y = (CGFloat(row) + 0.5) * dy
                let primary = (column + 2 * row) % 3
                let radius = spacing * 0.37
                if hexagonal {
                    // Pointy hexagon, matching the shader's Voronoi aperture.
                    var path = Path()
                    for vertex in 0..<6 {
                        let angle = CGFloat(vertex) * .pi / 3 + .pi / 6
                        let point = CGPoint(x: x + radius / (sqrt(3) / 2) * cos(angle),
                            y: y + radius / (sqrt(3) / 2) * sin(angle))
                        if vertex == 0 { path.move(to: point) } else { path.addLine(to: point) }
                    }
                    path.closeSubpath()
                    context.fill(path, with: .color(phosphor(primary)))
                } else {
                    context.fill(Path(ellipseIn: CGRect(x: x - radius, y: y - radius,
                        width: radius * 2, height: radius * 2)), with: .color(phosphor(primary)))
                }
            }
        }
    }

    private func drawHorizontal(_ context: inout GraphicsContext, size: CGSize) {
        let stripe = size.height / 6
        for row in 0..<6 {
            fill(&context, CGRect(x: 0.8, y: CGFloat(row) * stripe + 0.4,
                width: size.width - 1.6, height: max(1, stripe - 0.8)), row % 3)
        }
    }

    private func drawSlots(_ context: inout GraphicsContext, size: CGSize,
                           staggered: Bool) {
        let columns = 3, rows = 2
        let cellW = size.width / CGFloat(columns)
        let cellH = size.height / CGFloat(rows)
        for row in 0..<rows {
            let offset = staggered && row % 2 == 1 ? cellW / 6 : 0
            for column in 0..<columns {
                let x = offset + (CGFloat(column) + 0.5) * cellW
                let rect = CGRect(x: x - cellW * 0.16, y: CGFloat(row) * cellH + 2,
                    width: cellW * 0.32, height: cellH - 4)
                if staggered {
                    fill(&context, rect, column)
                } else {
                    context.fill(Path(ellipseIn: rect), with: .color(phosphor(column)))
                }
            }
        }
    }
}

/// Each arrangement has the same schematic, title and detail row.
struct TVCRTMaskChooser: View {
    @Binding var selection: Int

    var body: some View {
        VStack(spacing: 4) {
            ForEach(TVCRTMaskType.allCases) { type in
                let active = selection == type.rawValue
                Button { selection = type.rawValue } label: {
                    HStack(spacing: 8) {
                        TVCRTMaskGlyph(type: type)
                            .frame(width: 46, height: 26)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(L(type.title))
                                .font(.system(size: 10, weight: .medium))
                                .lineLimit(1).minimumScaleFactor(0.8)
                            Text(L(type.detail))
                                .font(.system(size: 8))
                                .foregroundStyle(.white.opacity(0.55))
                                .lineLimit(2)
                        }
                        Spacer(minLength: 2)
                        Image(systemName: active ? "checkmark.circle.fill" : "circle")
                            .font(.system(size: 11))
                            .foregroundStyle(active ? EditingTool.tv.logoAccentColor : .white.opacity(0.2))
                    }
                    .padding(.horizontal, 6)
                    .padding(.vertical, 3)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(RoundedRectangle(cornerRadius: 5)
                        .fill(active ? .white.opacity(0.12) : .white.opacity(0.035)))
                    .overlay(RoundedRectangle(cornerRadius: 5)
                        .stroke(active ? EditingTool.tv.logoAccentColor.opacity(0.75)
                                : .white.opacity(0.08), lineWidth: 0.7))
                }
                .buttonStyle(.plain)
                .help(L(type.detail))
            }
        }
    }
}
