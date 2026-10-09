import SwiftUI

extension EditingTool {
    var logoAccentColor: Color {
        switch self {
        case .film: Color(red: 239/255, green: 170/255, blue: 113/255)
        case .tv: Color(red: 234/255, green: 212/255, blue: 119/255)
        case .sstv: Color(red: 141/255, green: 220/255, blue: 219/255)
        }
    }
}

/// Native vector rendering of Design/Logo/ana-line-{master,film,sstv,tv}.svg.
/// Ligatures move as units; the separator keeps the approved first-version artwork.
struct AnaLineLogo: View {
    var tool: EditingTool? = nil
    var width: CGFloat = 174
    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .topLeading) {
                ForEach(0..<6, id: \.self) { index in
                    LogoStroke(path: paths[index],
                               size: geometry.size, bounds: artworkBounds, index: index)
                        .foregroundStyle(index == 5 ? separatorColor : Color.primary)
                }
            }.id(tool)
        }
        .frame(width: width, height: width * artworkBounds.height / artworkBounds.width)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(tool.map { L("Ana-Line") + ", \($0.rawValue)" } ?? L("Ana-Line"))
    }

    private var artworkBounds: CGRect {
        paths.reduce(CGRect.null) { $0.union($1.boundingRect) }
    }

    private var paths: [Path] {
        switch tool {
        case .film: LogoPaths.film
        case .sstv: LogoPaths.sstv
        case .tv: LogoPaths.tv
        case nil: LogoPaths.master
        }
    }

    private var separatorColor: Color {
        switch tool {
        case .some(let tool): tool.logoAccentColor
        case nil: Color(red: 213/255, green: 237/255, blue: 121/255)
        }
    }
}

private struct LogoStroke: View {
    let path: Path
    let size: CGSize
    let bounds: CGRect
    let index: Int
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var settled = false

    var body: some View {
        path.applying(CGAffineTransform(translationX: -bounds.minX, y: -bounds.minY)
            .concatenating(CGAffineTransform(scaleX: size.width / bounds.width,
                                           y: size.height / bounds.height)))
            // Nonzero winding keeps overlapping ligatures solid and the A counters open.
            .fill(style: FillStyle(eoFill: false))
            .offset(x: settled || reduceMotion ? 0 : -5,
                    y: settled || reduceMotion ? 0 : 1.5)
            .opacity(settled || reduceMotion ? 1 : 0.45)
            .onAppear {
                if reduceMotion { settled = true }
                else {
                    withAnimation(.easeOut(duration: 0.45).delay(Double(index) * 0.035)) {
                        settled = true
                    }
                }
            }
    }
}

private enum LogoPaths {
    private static let slant = CGAffineTransform(a: 1, b: 0, c: -0.2308681911, d: 1, tx: 27, ty: 24)
    static let master: [Path] = [
        Path { p in
            p.move(to: CGPoint(x: 25, y: 80))
            p.addLine(to: CGPoint(x: 48, y: 0))
            p.addLine(to: CGPoint(x: 72, y: 0))
            p.addLine(to: CGPoint(x: 90, y: 62))
            p.addLine(to: CGPoint(x: 124, y: 62))
            p.addLine(to: CGPoint(x: 124, y: 80))
            p.addLine(to: CGPoint(x: 75, y: 80))
            p.addLine(to: CGPoint(x: 71, y: 62))
            p.addLine(to: CGPoint(x: 48, y: 62))
            p.addLine(to: CGPoint(x: 44, y: 80))
            p.closeSubpath()
            p.move(to: CGPoint(x: 52, y: 46))
            p.addLine(to: CGPoint(x: 67, y: 46))
            p.addLine(to: CGPoint(x: 60, y: 18))
            p.closeSubpath()
            p.move(to: CGPoint(x: 104, y: 80))
            p.addLine(to: CGPoint(x: 104, y: 0))
            p.addLine(to: CGPoint(x: 124, y: 0))
            p.addLine(to: CGPoint(x: 152, y: 48))
            p.addLine(to: CGPoint(x: 152, y: 0))
            p.addLine(to: CGPoint(x: 170, y: 0))
            p.addLine(to: CGPoint(x: 170, y: 80))
            p.addLine(to: CGPoint(x: 150, y: 80))
            p.addLine(to: CGPoint(x: 122, y: 32))
            p.addLine(to: CGPoint(x: 122, y: 80))
            p.closeSubpath()
        }.applying(slant),
        Path { p in
            p.move(to: CGPoint(x: 179, y: 80))
            p.addLine(to: CGPoint(x: 202, y: 0))
            p.addLine(to: CGPoint(x: 226, y: 0))
            p.addLine(to: CGPoint(x: 249, y: 80))
            p.addLine(to: CGPoint(x: 229, y: 80))
            p.addLine(to: CGPoint(x: 225, y: 62))
            p.addLine(to: CGPoint(x: 202, y: 62))
            p.addLine(to: CGPoint(x: 198, y: 80))
            p.closeSubpath()
            p.move(to: CGPoint(x: 206, y: 46))
            p.addLine(to: CGPoint(x: 221, y: 46))
            p.addLine(to: CGPoint(x: 214, y: 18))
            p.closeSubpath()
        }.applying(slant),
        Path { p in
            p.move(to: CGPoint(x: 323, y: 0))
            p.addLine(to: CGPoint(x: 343, y: 0))
            p.addLine(to: CGPoint(x: 343, y: 62))
            p.addLine(to: CGPoint(x: 414, y: 62))
            p.addLine(to: CGPoint(x: 414, y: 80))
            p.addLine(to: CGPoint(x: 323, y: 80))
            p.closeSubpath()
            p.move(to: CGPoint(x: 394, y: 0))
            p.addLine(to: CGPoint(x: 414, y: 0))
            p.addLine(to: CGPoint(x: 414, y: 80))
            p.addLine(to: CGPoint(x: 394, y: 80))
            p.closeSubpath()
        }.applying(slant),
        Path { p in
            p.move(to: CGPoint(x: 423, y: 80))
            p.addLine(to: CGPoint(x: 423, y: 0))
            p.addLine(to: CGPoint(x: 443, y: 0))
            p.addLine(to: CGPoint(x: 471, y: 48))
            p.addLine(to: CGPoint(x: 471, y: 0))
            p.addLine(to: CGPoint(x: 489, y: 0))
            p.addLine(to: CGPoint(x: 489, y: 80))
            p.addLine(to: CGPoint(x: 469, y: 80))
            p.addLine(to: CGPoint(x: 441, y: 32))
            p.addLine(to: CGPoint(x: 441, y: 80))
            p.closeSubpath()
        }.applying(slant),
        Path { p in
            p.move(to: CGPoint(x: 498, y: 0))
            p.addLine(to: CGPoint(x: 558, y: 0))
            p.addLine(to: CGPoint(x: 558, y: 17))
            p.addLine(to: CGPoint(x: 518, y: 17))
            p.addLine(to: CGPoint(x: 518, y: 31))
            p.addLine(to: CGPoint(x: 552, y: 31))
            p.addLine(to: CGPoint(x: 552, y: 48))
            p.addLine(to: CGPoint(x: 518, y: 48))
            p.addLine(to: CGPoint(x: 518, y: 63))
            p.addLine(to: CGPoint(x: 558, y: 63))
            p.addLine(to: CGPoint(x: 558, y: 80))
            p.addLine(to: CGPoint(x: 498, y: 80))
            p.closeSubpath()
        }.applying(slant),
        Path { p in
            p.move(to: CGPoint(x: 258, y: 35))
            p.addLine(to: CGPoint(x: 307, y: 35))
            p.addLine(to: CGPoint(x: 307, y: 46))
            p.addLine(to: CGPoint(x: 258, y: 46))
            p.closeSubpath()
        }.applying(slant),
    ]
    static let film: [Path] = [
        Path { p in
            p.move(to: CGPoint(x: 25, y: 80))
            p.addLine(to: CGPoint(x: 46, y: 8))
            p.addQuadCurve(to: CGPoint(x: 56, y: 0), control: CGPoint(x: 48, y: 0))
            p.addLine(to: CGPoint(x: 64, y: 0))
            p.addQuadCurve(to: CGPoint(x: 74, y: 8), control: CGPoint(x: 72, y: 0))
            p.addLine(to: CGPoint(x: 86, y: 50))
            p.addQuadCurve(to: CGPoint(x: 101, y: 62), control: CGPoint(x: 89, y: 62))
            p.addLine(to: CGPoint(x: 124, y: 62))
            p.addLine(to: CGPoint(x: 124, y: 80))
            p.addLine(to: CGPoint(x: 83, y: 80))
            p.addQuadCurve(to: CGPoint(x: 73, y: 72), control: CGPoint(x: 75, y: 80))
            p.addLine(to: CGPoint(x: 71, y: 62))
            p.addLine(to: CGPoint(x: 48, y: 62))
            p.addLine(to: CGPoint(x: 44, y: 80))
            p.closeSubpath()
            p.move(to: CGPoint(x: 52, y: 46))
            p.addLine(to: CGPoint(x: 67, y: 46))
            p.addLine(to: CGPoint(x: 60, y: 18))
            p.closeSubpath()
            p.move(to: CGPoint(x: 104, y: 80))
            p.addLine(to: CGPoint(x: 104, y: 0))
            p.addLine(to: CGPoint(x: 118, y: 0))
            p.addQuadCurve(to: CGPoint(x: 128, y: 7), control: CGPoint(x: 124, y: 0))
            p.addLine(to: CGPoint(x: 152, y: 48))
            p.addLine(to: CGPoint(x: 152, y: 0))
            p.addLine(to: CGPoint(x: 170, y: 0))
            p.addLine(to: CGPoint(x: 170, y: 80))
            p.addLine(to: CGPoint(x: 156, y: 80))
            p.addQuadCurve(to: CGPoint(x: 146, y: 73), control: CGPoint(x: 150, y: 80))
            p.addLine(to: CGPoint(x: 122, y: 32))
            p.addLine(to: CGPoint(x: 122, y: 80))
            p.closeSubpath()
        }.applying(slant),
        Path { p in
            p.move(to: CGPoint(x: 179, y: 80))
            p.addLine(to: CGPoint(x: 200, y: 8))
            p.addQuadCurve(to: CGPoint(x: 210, y: 0), control: CGPoint(x: 202, y: 0))
            p.addLine(to: CGPoint(x: 218, y: 0))
            p.addQuadCurve(to: CGPoint(x: 228, y: 8), control: CGPoint(x: 226, y: 0))
            p.addLine(to: CGPoint(x: 249, y: 80))
            p.addLine(to: CGPoint(x: 229, y: 80))
            p.addLine(to: CGPoint(x: 225, y: 62))
            p.addLine(to: CGPoint(x: 202, y: 62))
            p.addLine(to: CGPoint(x: 198, y: 80))
            p.closeSubpath()
            p.move(to: CGPoint(x: 206, y: 46))
            p.addLine(to: CGPoint(x: 221, y: 46))
            p.addLine(to: CGPoint(x: 214, y: 18))
            p.closeSubpath()
        }.applying(slant),
        Path { p in
            p.move(to: CGPoint(x: 323, y: 0))
            p.addLine(to: CGPoint(x: 343, y: 0))
            p.addLine(to: CGPoint(x: 343, y: 50))
            p.addQuadCurve(to: CGPoint(x: 355, y: 62), control: CGPoint(x: 343, y: 62))
            p.addLine(to: CGPoint(x: 414, y: 62))
            p.addLine(to: CGPoint(x: 414, y: 80))
            p.addLine(to: CGPoint(x: 351, y: 80))
            p.addQuadCurve(to: CGPoint(x: 323, y: 52), control: CGPoint(x: 323, y: 80))
            p.closeSubpath()
            p.move(to: CGPoint(x: 329, y: 12))
            p.addLine(to: CGPoint(x: 329, y: 22))
            p.addLine(to: CGPoint(x: 337, y: 22))
            p.addLine(to: CGPoint(x: 337, y: 12))
            p.closeSubpath()
            p.move(to: CGPoint(x: 329, y: 32))
            p.addLine(to: CGPoint(x: 329, y: 42))
            p.addLine(to: CGPoint(x: 337, y: 42))
            p.addLine(to: CGPoint(x: 337, y: 32))
            p.closeSubpath()
            p.move(to: CGPoint(x: 394, y: 0))
            p.addLine(to: CGPoint(x: 414, y: 0))
            p.addLine(to: CGPoint(x: 414, y: 80))
            p.addLine(to: CGPoint(x: 394, y: 80))
            p.closeSubpath()
        }.applying(slant),
        Path { p in
            p.move(to: CGPoint(x: 423, y: 80))
            p.addLine(to: CGPoint(x: 423, y: 0))
            p.addLine(to: CGPoint(x: 437, y: 0))
            p.addQuadCurve(to: CGPoint(x: 447, y: 7), control: CGPoint(x: 443, y: 0))
            p.addLine(to: CGPoint(x: 471, y: 48))
            p.addLine(to: CGPoint(x: 471, y: 0))
            p.addLine(to: CGPoint(x: 489, y: 0))
            p.addLine(to: CGPoint(x: 489, y: 80))
            p.addLine(to: CGPoint(x: 475, y: 80))
            p.addQuadCurve(to: CGPoint(x: 465, y: 73), control: CGPoint(x: 469, y: 80))
            p.addLine(to: CGPoint(x: 441, y: 32))
            p.addLine(to: CGPoint(x: 441, y: 80))
            p.closeSubpath()
        }.applying(slant),
        Path { p in
            p.move(to: CGPoint(x: 508, y: 0))
            p.addLine(to: CGPoint(x: 558, y: 0))
            p.addLine(to: CGPoint(x: 558, y: 17))
            p.addLine(to: CGPoint(x: 522, y: 17))
            p.addQuadCurve(to: CGPoint(x: 518, y: 21), control: CGPoint(x: 518, y: 17))
            p.addLine(to: CGPoint(x: 518, y: 31))
            p.addLine(to: CGPoint(x: 552, y: 31))
            p.addLine(to: CGPoint(x: 552, y: 48))
            p.addLine(to: CGPoint(x: 518, y: 48))
            p.addLine(to: CGPoint(x: 518, y: 59))
            p.addQuadCurve(to: CGPoint(x: 522, y: 63), control: CGPoint(x: 518, y: 63))
            p.addLine(to: CGPoint(x: 558, y: 63))
            p.addLine(to: CGPoint(x: 558, y: 80))
            p.addLine(to: CGPoint(x: 508, y: 80))
            p.addQuadCurve(to: CGPoint(x: 498, y: 70), control: CGPoint(x: 498, y: 80))
            p.addLine(to: CGPoint(x: 498, y: 10))
            p.addQuadCurve(to: CGPoint(x: 508, y: 0), control: CGPoint(x: 498, y: 0))
            p.closeSubpath()
        }.applying(slant),
        Path { p in
            p.move(to: CGPoint(x: 258, y: 24))
            p.addLine(to: CGPoint(x: 307, y: 24))
            p.addLine(to: CGPoint(x: 307, y: 31))
            p.addLine(to: CGPoint(x: 258, y: 31))
            p.closeSubpath()
            p.move(to: CGPoint(x: 258, y: 37))
            p.addLine(to: CGPoint(x: 307, y: 37))
            p.addLine(to: CGPoint(x: 307, y: 44))
            p.addLine(to: CGPoint(x: 258, y: 44))
            p.closeSubpath()
            p.move(to: CGPoint(x: 258, y: 50))
            p.addLine(to: CGPoint(x: 307, y: 50))
            p.addLine(to: CGPoint(x: 307, y: 57))
            p.addLine(to: CGPoint(x: 258, y: 57))
            p.closeSubpath()
        }.applying(slant),
    ]
    static let sstv: [Path] = [
        Path { p in
            p.move(to: CGPoint(x: 25, y: 80))
            p.addLine(to: CGPoint(x: 48, y: 0))
            p.addLine(to: CGPoint(x: 72, y: 0))
            p.addLine(to: CGPoint(x: 90, y: 62))
            p.addLine(to: CGPoint(x: 124, y: 62))
            p.addLine(to: CGPoint(x: 124, y: 80))
            p.addLine(to: CGPoint(x: 75, y: 80))
            p.addLine(to: CGPoint(x: 71, y: 62))
            p.addLine(to: CGPoint(x: 48, y: 62))
            p.addLine(to: CGPoint(x: 44, y: 80))
            p.closeSubpath()
            p.move(to: CGPoint(x: 52, y: 46))
            p.addLine(to: CGPoint(x: 67, y: 46))
            p.addLine(to: CGPoint(x: 60, y: 18))
            p.closeSubpath()
            p.move(to: CGPoint(x: 104, y: 80))
            p.addLine(to: CGPoint(x: 104, y: 0))
            p.addLine(to: CGPoint(x: 124, y: 0))
            p.addLine(to: CGPoint(x: 139, y: 26))
            p.addLine(to: CGPoint(x: 145, y: 26))
            p.addLine(to: CGPoint(x: 145, y: 36))
            p.addLine(to: CGPoint(x: 152, y: 48))
            p.addLine(to: CGPoint(x: 152, y: 0))
            p.addLine(to: CGPoint(x: 170, y: 0))
            p.addLine(to: CGPoint(x: 170, y: 80))
            p.addLine(to: CGPoint(x: 150, y: 80))
            p.addLine(to: CGPoint(x: 135, y: 54))
            p.addLine(to: CGPoint(x: 129, y: 54))
            p.addLine(to: CGPoint(x: 129, y: 44))
            p.addLine(to: CGPoint(x: 122, y: 32))
            p.addLine(to: CGPoint(x: 122, y: 80))
            p.closeSubpath()
        }.applying(slant),
        Path { p in
            p.move(to: CGPoint(x: 179, y: 80))
            p.addLine(to: CGPoint(x: 202, y: 0))
            p.addLine(to: CGPoint(x: 226, y: 0))
            p.addLine(to: CGPoint(x: 249, y: 80))
            p.addLine(to: CGPoint(x: 229, y: 80))
            p.addLine(to: CGPoint(x: 225, y: 62))
            p.addLine(to: CGPoint(x: 202, y: 62))
            p.addLine(to: CGPoint(x: 198, y: 80))
            p.closeSubpath()
            p.move(to: CGPoint(x: 206, y: 46))
            p.addLine(to: CGPoint(x: 221, y: 46))
            p.addLine(to: CGPoint(x: 214, y: 18))
            p.closeSubpath()
        }.applying(slant),
        Path { p in
            p.move(to: CGPoint(x: 323, y: 0))
            p.addLine(to: CGPoint(x: 343, y: 0))
            p.addLine(to: CGPoint(x: 343, y: 62))
            p.addLine(to: CGPoint(x: 414, y: 62))
            p.addLine(to: CGPoint(x: 414, y: 80))
            p.addLine(to: CGPoint(x: 323, y: 80))
            p.closeSubpath()
            p.move(to: CGPoint(x: 394, y: 0))
            p.addLine(to: CGPoint(x: 414, y: 0))
            p.addLine(to: CGPoint(x: 414, y: 80))
            p.addLine(to: CGPoint(x: 394, y: 80))
            p.closeSubpath()
        }.applying(slant),
        Path { p in
            p.move(to: CGPoint(x: 423, y: 80))
            p.addLine(to: CGPoint(x: 423, y: 0))
            p.addLine(to: CGPoint(x: 443, y: 0))
            p.addLine(to: CGPoint(x: 458, y: 26))
            p.addLine(to: CGPoint(x: 464, y: 26))
            p.addLine(to: CGPoint(x: 464, y: 36))
            p.addLine(to: CGPoint(x: 471, y: 48))
            p.addLine(to: CGPoint(x: 471, y: 0))
            p.addLine(to: CGPoint(x: 489, y: 0))
            p.addLine(to: CGPoint(x: 489, y: 80))
            p.addLine(to: CGPoint(x: 469, y: 80))
            p.addLine(to: CGPoint(x: 454, y: 54))
            p.addLine(to: CGPoint(x: 448, y: 54))
            p.addLine(to: CGPoint(x: 448, y: 44))
            p.addLine(to: CGPoint(x: 441, y: 32))
            p.addLine(to: CGPoint(x: 441, y: 80))
            p.closeSubpath()
        }.applying(slant),
        Path { p in
            p.move(to: CGPoint(x: 498, y: 0))
            p.addLine(to: CGPoint(x: 558, y: 0))
            p.addLine(to: CGPoint(x: 558, y: 17))
            p.addLine(to: CGPoint(x: 518, y: 17))
            p.addLine(to: CGPoint(x: 518, y: 30))
            p.addLine(to: CGPoint(x: 547, y: 30))
            p.addLine(to: CGPoint(x: 555, y: 38))
            p.addLine(to: CGPoint(x: 555, y: 48))
            p.addLine(to: CGPoint(x: 518, y: 48))
            p.addLine(to: CGPoint(x: 518, y: 63))
            p.addLine(to: CGPoint(x: 558, y: 63))
            p.addLine(to: CGPoint(x: 558, y: 80))
            p.addLine(to: CGPoint(x: 498, y: 80))
            p.closeSubpath()
        }.applying(slant),
        Path { p in
            p.move(to: CGPoint(x: 258, y: 37))
            p.addLine(to: CGPoint(x: 268, y: 37))
            p.addLine(to: CGPoint(x: 268, y: 25))
            p.addLine(to: CGPoint(x: 278, y: 25))
            p.addLine(to: CGPoint(x: 278, y: 49))
            p.addLine(to: CGPoint(x: 288, y: 49))
            p.addLine(to: CGPoint(x: 288, y: 32))
            p.addLine(to: CGPoint(x: 298, y: 32))
            p.addLine(to: CGPoint(x: 298, y: 37))
            p.addLine(to: CGPoint(x: 307, y: 37))
            p.addLine(to: CGPoint(x: 307, y: 45))
            p.addLine(to: CGPoint(x: 292, y: 45))
            p.addLine(to: CGPoint(x: 292, y: 57))
            p.addLine(to: CGPoint(x: 282, y: 57))
            p.addLine(to: CGPoint(x: 282, y: 33))
            p.addLine(to: CGPoint(x: 276, y: 33))
            p.addLine(to: CGPoint(x: 276, y: 45))
            p.addLine(to: CGPoint(x: 258, y: 45))
            p.closeSubpath()
        }.applying(slant),
    ]
    static let tv: [Path] = [
        Path { p in
            p.move(to: CGPoint(x: 25, y: 80))
            p.addLine(to: CGPoint(x: 48, y: 0))
            p.addLine(to: CGPoint(x: 72, y: 0))
            p.addLine(to: CGPoint(x: 90, y: 62))
            p.addLine(to: CGPoint(x: 124, y: 62))
            p.addLine(to: CGPoint(x: 124, y: 80))
            p.addLine(to: CGPoint(x: 75, y: 80))
            p.addLine(to: CGPoint(x: 71, y: 62))
            p.addLine(to: CGPoint(x: 48, y: 62))
            p.addLine(to: CGPoint(x: 44, y: 80))
            p.closeSubpath()
            p.move(to: CGPoint(x: 52, y: 46))
            p.addQuadCurve(to: CGPoint(x: 67, y: 46), control: CGPoint(x: 60, y: 48))
            p.addLine(to: CGPoint(x: 64, y: 30))
            p.addQuadCurve(to: CGPoint(x: 56, y: 30), control: CGPoint(x: 60, y: 21))
            p.closeSubpath()
            p.move(to: CGPoint(x: 104, y: 34))
            p.addLine(to: CGPoint(x: 104, y: 0))
            p.addLine(to: CGPoint(x: 124, y: 0))
            p.addLine(to: CGPoint(x: 144, y: 34))
            p.addLine(to: CGPoint(x: 123, y: 34))
            p.addLine(to: CGPoint(x: 122, y: 32))
            p.addLine(to: CGPoint(x: 122, y: 34))
            p.closeSubpath()
            p.move(to: CGPoint(x: 152, y: 0))
            p.addLine(to: CGPoint(x: 170, y: 0))
            p.addLine(to: CGPoint(x: 170, y: 34))
            p.addLine(to: CGPoint(x: 152, y: 34))
            p.closeSubpath()
            p.move(to: CGPoint(x: 107, y: 42))
            p.addLine(to: CGPoint(x: 125, y: 42))
            p.addLine(to: CGPoint(x: 125, y: 80))
            p.addLine(to: CGPoint(x: 107, y: 80))
            p.closeSubpath()
            p.move(to: CGPoint(x: 131, y: 42))
            p.addLine(to: CGPoint(x: 151, y: 42))
            p.addLine(to: CGPoint(x: 155, y: 48))
            p.addLine(to: CGPoint(x: 155, y: 42))
            p.addLine(to: CGPoint(x: 173, y: 42))
            p.addLine(to: CGPoint(x: 173, y: 80))
            p.addLine(to: CGPoint(x: 153, y: 80))
            p.closeSubpath()
        }.applying(slant),
        Path { p in
            p.move(to: CGPoint(x: 179, y: 80))
            p.addLine(to: CGPoint(x: 202, y: 0))
            p.addLine(to: CGPoint(x: 226, y: 0))
            p.addLine(to: CGPoint(x: 249, y: 80))
            p.addLine(to: CGPoint(x: 229, y: 80))
            p.addLine(to: CGPoint(x: 225, y: 62))
            p.addLine(to: CGPoint(x: 202, y: 62))
            p.addLine(to: CGPoint(x: 198, y: 80))
            p.closeSubpath()
            p.move(to: CGPoint(x: 206, y: 46))
            p.addQuadCurve(to: CGPoint(x: 221, y: 46), control: CGPoint(x: 214, y: 48))
            p.addLine(to: CGPoint(x: 218, y: 30))
            p.addQuadCurve(to: CGPoint(x: 210, y: 30), control: CGPoint(x: 214, y: 21))
            p.closeSubpath()
        }.applying(slant),
        Path { p in
            p.move(to: CGPoint(x: 323, y: 0))
            p.addLine(to: CGPoint(x: 343, y: 0))
            p.addLine(to: CGPoint(x: 343, y: 62))
            p.addLine(to: CGPoint(x: 414, y: 62))
            p.addLine(to: CGPoint(x: 414, y: 80))
            p.addLine(to: CGPoint(x: 323, y: 80))
            p.closeSubpath()
            p.move(to: CGPoint(x: 394, y: 0))
            p.addLine(to: CGPoint(x: 414, y: 0))
            p.addLine(to: CGPoint(x: 414, y: 80))
            p.addLine(to: CGPoint(x: 394, y: 80))
            p.closeSubpath()
        }.applying(slant),
        Path { p in
            p.move(to: CGPoint(x: 423, y: 34))
            p.addLine(to: CGPoint(x: 423, y: 0))
            p.addLine(to: CGPoint(x: 443, y: 0))
            p.addLine(to: CGPoint(x: 463, y: 34))
            p.addLine(to: CGPoint(x: 442, y: 34))
            p.addLine(to: CGPoint(x: 441, y: 32))
            p.addLine(to: CGPoint(x: 441, y: 34))
            p.closeSubpath()
            p.move(to: CGPoint(x: 471, y: 0))
            p.addLine(to: CGPoint(x: 489, y: 0))
            p.addLine(to: CGPoint(x: 489, y: 34))
            p.addLine(to: CGPoint(x: 471, y: 34))
            p.closeSubpath()
            p.move(to: CGPoint(x: 426, y: 42))
            p.addLine(to: CGPoint(x: 444, y: 42))
            p.addLine(to: CGPoint(x: 444, y: 80))
            p.addLine(to: CGPoint(x: 426, y: 80))
            p.closeSubpath()
            p.move(to: CGPoint(x: 450, y: 42))
            p.addLine(to: CGPoint(x: 470, y: 42))
            p.addLine(to: CGPoint(x: 474, y: 48))
            p.addLine(to: CGPoint(x: 474, y: 42))
            p.addLine(to: CGPoint(x: 492, y: 42))
            p.addLine(to: CGPoint(x: 492, y: 80))
            p.addLine(to: CGPoint(x: 472, y: 80))
            p.closeSubpath()
        }.applying(slant),
        Path { p in
            p.move(to: CGPoint(x: 498, y: 0))
            p.addLine(to: CGPoint(x: 550, y: 0))
            p.addQuadCurve(to: CGPoint(x: 558, y: 8), control: CGPoint(x: 558, y: 0))
            p.addLine(to: CGPoint(x: 558, y: 17))
            p.addLine(to: CGPoint(x: 518, y: 17))
            p.addLine(to: CGPoint(x: 518, y: 31))
            p.addLine(to: CGPoint(x: 562, y: 31))
            p.addLine(to: CGPoint(x: 562, y: 48))
            p.addLine(to: CGPoint(x: 518, y: 48))
            p.addLine(to: CGPoint(x: 518, y: 63))
            p.addLine(to: CGPoint(x: 558, y: 63))
            p.addLine(to: CGPoint(x: 558, y: 72))
            p.addQuadCurve(to: CGPoint(x: 550, y: 80), control: CGPoint(x: 558, y: 80))
            p.addLine(to: CGPoint(x: 498, y: 80))
            p.closeSubpath()
        }.applying(slant),
        Path { p in
            p.move(to: CGPoint(x: 258, y: 37))
            p.addLine(to: CGPoint(x: 265, y: 37))
            p.addLine(to: CGPoint(x: 265, y: 16))
            p.addLine(to: CGPoint(x: 272, y: 16))
            p.addLine(to: CGPoint(x: 272, y: 37))
            p.addLine(to: CGPoint(x: 281, y: 37))
            p.addLine(to: CGPoint(x: 281, y: 22))
            p.addLine(to: CGPoint(x: 288, y: 22))
            p.addLine(to: CGPoint(x: 288, y: 37))
            p.addLine(to: CGPoint(x: 297, y: 37))
            p.addLine(to: CGPoint(x: 297, y: 28))
            p.addLine(to: CGPoint(x: 304, y: 28))
            p.addLine(to: CGPoint(x: 304, y: 37))
            p.addLine(to: CGPoint(x: 307, y: 37))
            p.addLine(to: CGPoint(x: 307, y: 44))
            p.addLine(to: CGPoint(x: 304, y: 44))
            p.addLine(to: CGPoint(x: 304, y: 53))
            p.addLine(to: CGPoint(x: 297, y: 53))
            p.addLine(to: CGPoint(x: 297, y: 44))
            p.addLine(to: CGPoint(x: 288, y: 44))
            p.addLine(to: CGPoint(x: 288, y: 59))
            p.addLine(to: CGPoint(x: 281, y: 59))
            p.addLine(to: CGPoint(x: 281, y: 44))
            p.addLine(to: CGPoint(x: 272, y: 44))
            p.addLine(to: CGPoint(x: 272, y: 65))
            p.addLine(to: CGPoint(x: 265, y: 65))
            p.addLine(to: CGPoint(x: 265, y: 44))
            p.addLine(to: CGPoint(x: 258, y: 44))
            p.closeSubpath()
        }.applying(slant),
    ]
}
