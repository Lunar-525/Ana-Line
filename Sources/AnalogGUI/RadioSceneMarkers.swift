import SwiftUI
import AnalogCore

/// Eight fixed station colours, shared by the transmitter cards and every
/// waterfall indicator so a channel reads the same everywhere.
func stationColor(_ index: Int) -> Color {
    let colors: [Color] = [EditingTool.radio.logoAccentColor,.cyan,.orange,.mint,.pink,.yellow,Color(red: 0.5,green: 0.7,blue: 1),Color(red: 0.8,green: 0.9,blue: 0.5)]
    return colors[index % colors.count]
}

/// Everything a radio waterfall needs in order to explain the scene: the eight
/// transmitter channel indicators, each receiver's tuning position, and the
/// bracket showing the IF / sideband each receiver is actually passing. Shared
/// by the per-receiver narrowband waterfall and the wideband environment panel.
@MainActor
enum RadioSceneMarkerOverlay {
    struct Geometry {
        let center: Double, span: Double
        let size: CGSize, traceHeight: CGFloat
        func x(_ hz: Double) -> CGFloat { CGFloat((hz-center)/span+0.5)*size.width }
        func isVisible(_ hz: Double,margin: CGFloat = 8) -> Bool {
            span > 0 && x(hz) >= -margin && x(hz) <= size.width+margin
        }
    }
    /// IF / sideband window of a receiver, in absolute scene frequencies.
    static func band(_ rx: RadioSceneRX) -> ClosedRange<Double> {
        switch rx.mode {
        case .usb:
            return (rx.tuningHz+200)...(rx.tuningHz+max(400,rx.parameters.ssb.audioBandwidthHz))
        case .lsb:
            return (rx.tuningHz-max(400,rx.parameters.ssb.audioBandwidthHz))...(rx.tuningHz-200)
        default:
            let half = rx.parameters.bandwidth(rx.mode)/2
            return (rx.tuningHz-half)...(rx.tuningHz+half)
        }
    }
    /// `owner` is the receiver feeding this waterfall; its bracket and tuning
    /// marker are highlighted while the other receiver stays legible but dim.
    static func draw(_ context: inout GraphicsContext,geometry: Geometry,
                     transmitters: [RadioSceneTX],receivers: [RadioSceneRX],owner: UUID?,
                     shadeOwnerBand: Bool = false) {
        guard geometry.span > 0, geometry.size.width > 0 else { return }
        if shadeOwnerBand, let owner, let rx = receivers.first(where: { $0.id == owner }) {
            let band = band(rx)
            let left = max(0,geometry.x(band.lowerBound)), right = min(geometry.size.width,geometry.x(band.upperBound))
            if right > left {
                context.fill(Path(CGRect(x: left,y: 0,width: right-left,height: geometry.size.height)),
                    with: .color(TVInstrumentPalette.ink.opacity(0.05)))
            }
        }
        // Receivers: a bracket per IF window plus a dashed tuning line.
        for (index, rx) in receivers.enumerated() {
            let active = rx.id == owner
            let color = active ? EditingTool.radio.logoAccentColor : TVInstrumentPalette.ink.opacity(0.5)
            let band = band(rx)
            let row = 6+CGFloat(index)*8
            let left = geometry.x(band.lowerBound), right = geometry.x(band.upperBound)
            if right > left, right > 0, left < geometry.size.width {
                let visibleLeft = max(0,left), visibleRight = min(geometry.size.width,right)
                var bracket = Path()
                bracket.move(to: CGPoint(x: visibleLeft,y: row))
                bracket.addLine(to: CGPoint(x: visibleRight,y: row))
                // Caps only at real edges, so a cropped window never fakes a band.
                for edge in [left,right] where edge >= 0 && edge <= geometry.size.width {
                    bracket.move(to: CGPoint(x: edge,y: row))
                    bracket.addLine(to: CGPoint(x: edge,y: row+5))
                }
                context.stroke(bracket,with: .color(color),lineWidth: active ? 1.5 : 1)
            }
            if geometry.isVisible(rx.tuningHz,margin: 0) {
                var line = Path()
                line.move(to: CGPoint(x: geometry.x(rx.tuningHz),y: row+5))
                line.addLine(to: CGPoint(x: geometry.x(rx.tuningHz),y: geometry.size.height))
                context.stroke(line,with: .color(color),
                    style: StrokeStyle(lineWidth: active ? 1 : 0.5,dash: [3,3]))
            }
        }
        // Transmitters: a channel indicator per carrier, labelled and colour coded.
        var labels: [(position: CGFloat,text: String,color: Color)] = []
        for (index, tx) in transmitters.enumerated() {
            let position = geometry.x(tx.carrierHz)
            let color = stationColor(index)
            if position >= -8, position <= geometry.size.width+8 {
                var line = Path()
                line.move(to: CGPoint(x: position,y: geometry.traceHeight))
                line.addLine(to: CGPoint(x: position,y: geometry.size.height))
                context.stroke(line,with: .color(color.opacity(tx.enabled ? 0.5 : 0.18)),
                    style: StrokeStyle(lineWidth: 1,dash: tx.enabled ? [] : [2,3]))
                var flag = Path()
                flag.move(to: CGPoint(x: position-3,y: geometry.traceHeight+1))
                flag.addLine(to: CGPoint(x: position+3,y: geometry.traceHeight+1))
                flag.addLine(to: CGPoint(x: position,y: geometry.traceHeight+6))
                flag.closeSubpath()
                context.fill(flag,with: .color(color.opacity(tx.enabled ? 1 : 0.35)))
            }
            labels.append((position,"T\(index+1)",color.opacity(tx.enabled ? 1 : 0.4)))
        }
        drawLabels(labels,into: &context,geometry: geometry)
    }
    /// Stacks colliding labels into up to four rows so eight co-channel stations
    /// stay readable instead of printing on top of each other.
    private static func drawLabels(_ labels: [(position: CGFloat,text: String,color: Color)],
                                   into context: inout GraphicsContext,geometry: Geometry) {
        var rows = [[ClosedRange<CGFloat>]](repeating: [],count: 4)
        for label in labels {
            let width = CGFloat(label.text.count)*5+4
            let x = min(geometry.size.width-2-width/2,max(2+width/2,label.position))
            let range = (x-width/2)...(x+width/2)
            let row = (0..<rows.count).first { rows[$0].allSatisfy { !$0.overlaps(range) } } ?? rows.count-1
            rows[row].append(range)
            context.draw(Text(label.text).font(.system(size: 7,weight: .bold,design: .monospaced))
                .foregroundColor(label.color),
                at: CGPoint(x: x,y: geometry.traceHeight+14+CGFloat(row)*9),anchor: .center)
        }
    }
}
