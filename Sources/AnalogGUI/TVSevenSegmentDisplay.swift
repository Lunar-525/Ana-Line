import SwiftUI

/// Static vector segments; no font dependency, blinking timer or animation.
struct TVSevenSegmentDisplay: View {
    let text: String
    var color = Color(red: 1,green: 0.73,blue: 0.28)
    var height: CGFloat = 12
    private static let masks: [Character: UInt8] = [
        "0": 0x3f,"1": 0x06,"2": 0x5b,"3": 0x4f,"4": 0x66,
        "5": 0x6d,"6": 0x7d,"7": 0x07,"8": 0x7f,"9": 0x6f,"-": 0x40
    ]
    private var width: CGFloat {
        text.reduce(0) { $0 + height*($1 == "." || $1 == "," ? 0.25 : 0.62) }
    }
    var body: some View {
        Canvas { context,_ in
            let w = height*0.48, t = height*0.095
            var x: CGFloat = 0
            for character in text {
                if character == "." || character == "," {
                    context.fill(Path(ellipseIn: CGRect(x: x,y: height-t*1.25,width: t*1.25,height: t*1.25)),with: .color(color))
                    x += height*0.25
                    continue
                }
                if character != " " {
                    let mask = Self.masks[character] ?? 0
                    let vertical = height/2-t*1.5
                    let rectangles = [
                        CGRect(x: x+t,y: 0,width: w-2*t,height: t),
                        CGRect(x: x+w-t,y: t,width: t,height: vertical),
                        CGRect(x: x+w-t,y: height/2+t/2,width: t,height: vertical),
                        CGRect(x: x+t,y: height-t,width: w-2*t,height: t),
                        CGRect(x: x,y: height/2+t/2,width: t,height: vertical),
                        CGRect(x: x,y: t,width: t,height: vertical),
                        CGRect(x: x+t,y: height/2-t/2,width: w-2*t,height: t)
                    ]
                    for (segment,rect) in rectangles.enumerated() {
                        context.fill(Self.segment(rect),with: .color(color.opacity(mask & (1 << segment) != 0 ? 1 : 0.09)))
                    }
                }
                x += height*0.62
            }
        }.frame(width: width,height: height).accessibilityHidden(true).allowsHitTesting(false)
    }
    private static func segment(_ r: CGRect) -> Path {
        let b = min(r.width,r.height)/2
        let points: [CGPoint] = r.width > r.height ? [
            CGPoint(x: r.minX+b,y: r.minY),CGPoint(x: r.maxX-b,y: r.minY),CGPoint(x: r.maxX,y: r.midY),
            CGPoint(x: r.maxX-b,y: r.maxY),CGPoint(x: r.minX+b,y: r.maxY),CGPoint(x: r.minX,y: r.midY)
        ] : [
            CGPoint(x: r.midX,y: r.minY),CGPoint(x: r.maxX,y: r.minY+b),CGPoint(x: r.maxX,y: r.maxY-b),
            CGPoint(x: r.midX,y: r.maxY),CGPoint(x: r.minX,y: r.maxY-b),CGPoint(x: r.minX,y: r.minY+b)
        ]
        return Path { p in p.addLines(points); p.closeSubpath() }
    }
}

/// The same field remains editable and accessible; focus exposes conventional
/// text entry, while the unfocused value appears behind the instrument glass.
struct TVSegmentValue: View {
    @Binding var value: Float
    let range: ClosedRange<Float>
    let digits: Int
    let percent: Bool
    let label: String
    @FocusState private var editing: Bool
    private var factor: Double { percent ? 100 : 1 }
    private func formatted(_ x: Float) -> String { String(format: "%.*f",digits,Double(x)*factor) }
    private var fieldWidth: CGFloat {
        CGFloat(max(formatted(range.lowerBound).count,formatted(range.upperBound).count))*7.44+8
    }
    var body: some View {
        ZStack(alignment: .trailing) {
            if editing {
                TextField("",value: Binding<Double>(get: { Double(value)*factor },set: { v in
                    guard v.isFinite else { return }
                    value = min(range.upperBound,max(range.lowerBound,Float(v/factor)))
                }),format: .number.precision(.fractionLength(digits)))
                    .textFieldStyle(.plain).multilineTextAlignment(.trailing)
                    .font(.system(size: 10).monospacedDigit()).padding(.horizontal,4)
                    .focused($editing).onSubmit { editing = false }
                    .accessibilityLabel(label)
            } else {
                Button { editing = true } label: {
                    TVSevenSegmentDisplay(text: formatted(value)).padding(.horizontal,4)
                        .frame(maxWidth: .infinity,maxHeight: .infinity,alignment: .trailing)
                        .contentShape(Rectangle())
                }.buttonStyle(.plain).accessibilityLabel(label).accessibilityValue(formatted(value))
                    .help(L("Click to enter a value"))
            }
        }.frame(width: max(34,fieldWidth),height: 18)
            .background(Color(white: 0.035))
            .overlay(Rectangle().stroke(editing ? Color.orange.opacity(0.75) : .white.opacity(0.13),lineWidth: 0.5)
                .allowsHitTesting(false))
    }
}
