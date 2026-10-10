import SwiftUI
import AppKit
import AnalogCore

enum TVSceneObject { case antenna, tower, ridge, refraction, ground, echo }

/// A transparent native hit region handles only wheel events. Mouse clicks,
/// drags and context menus continue to the SwiftUI object beneath it.
struct TVSceneWheel: NSViewRepresentable {
    @Binding var value: Float
    let range: ClosedRange<Float>
    let step: Float
    let label: String
    @Environment(\.isEnabled) private var enabled
    final class Region: NSView {
        var value: Float = 0
        var range: ClosedRange<Float> = 0...1
        var step: Float = 0.01
        var enabled = true
        var change: ((Float) -> Void)?
        private var remainder = 0.0
        override func hitTest(_ point: NSPoint) -> NSView? {
            guard enabled, NSApp?.currentEvent?.type == .scrollWheel else { return nil }
            return super.hitTest(point)
        }
        override func scrollWheel(with event: NSEvent) {
            guard enabled else { super.scrollWheel(with: event); return }
            guard event.momentumPhase.isEmpty else { return }
            if event.phase.contains(.began) { remainder = 0 }
            let axis = event.scrollingDeltaY != 0 ? event.scrollingDeltaY :
                (event.modifierFlags.contains(.shift) ? event.scrollingDeltaX : 0)
            remainder += Double(axis)*(event.isDirectionInvertedFromDevice ? -1 : 1)/(event.hasPreciseScrollingDeltas ? 8 : 1)
            let steps = remainder.rounded(.towardZero); remainder -= steps
            let next = min(range.upperBound,max(range.lowerBound,value+Float(steps)*step*(event.modifierFlags.contains(.shift) ? 0.1 : 1)))
            if next.isFinite, next != value { value = next; change?(next) }
        }
    }
    func makeNSView(context: Context) -> Region {
        let view = Region()
        view.setAccessibilityElement(false)
        return view
    }
    func updateNSView(_ view: Region,context: Context) {
        view.value = value; view.range = range; view.step = step; view.enabled = enabled
        view.change = { value = $0 }
        view.setAccessibilityLabel(label)
    }
}

struct TVSceneValueField: View {
    let name: String
    let unit: String
    @Binding var value: Float
    let range: ClosedRange<Float>
    var body: some View {
        HStack {
            Text(L(name))
            Spacer(minLength: 8)
            TextField("",value: Binding(get: { value },set: {
                if $0.isFinite { value = min(range.upperBound,max(range.lowerBound,$0)) }
            }),format: .number.precision(.fractionLength(0...2)))
                .textFieldStyle(.roundedBorder).multilineTextAlignment(.trailing).frame(width: 76)
                .accessibilityLabel("\(L(name)) · \(unit)")
            Text(unit).foregroundStyle(.secondary).frame(width: 30,alignment: .leading)
        }.font(.system(size: 11))
    }
}

struct TVSceneInspector: View {
    let object: TVSceneObject
    @Binding var settings: TVPropagationSettings
    @Binding var echoGain: Float
    @Binding var echoDelay: Float
    @Binding var echoPhase: Float
    var body: some View {
        VStack(alignment: .leading,spacing: 10) {
            switch object {
            case .antenna:
                Text(L(settings.antenna.rawValue)).fontWeight(.semibold)
                TVSceneValueField(name: "Gain",unit: "dBi",value: $settings.antennaGainDB,range: -5...25)
                TVSceneValueField(name: "Distance",unit: "km",value: $settings.distanceKm,range: 3...50)
                TVSceneValueField(name: "RX height",unit: "m",value: $settings.receiverHeightM,range: 2...150)
                TVSceneValueField(name: "Elevation",unit: "°",value: $settings.antennaElevationDegrees,range: -90...90)
            case .tower:
                TVSceneValueField(name: "TX height",unit: "m",value: $settings.transmitterHeightM,range: 20...300)
            case .ridge:
                TVSceneValueField(name: "Ridge height · m",unit: "m",value: $settings.ridgeHeightM,range: 0...500)
                TVSceneValueField(name: "Ridge position",unit: "",value: $settings.ridgePosition,range: 0.1...0.9)
            case .refraction:
                TVSceneValueField(name: "Refraction",unit: "k",value: $settings.refractionK,range: 0.65...4)
                let report = TVPropagationModel.evaluate(settings)
                Text(String(format: "%@ k %.2f",L("Effective refraction"),report.refractionK))
                    .font(.caption).foregroundStyle(.secondary)
            case .ground:
                TVSceneValueField(name: "Ground reflection",unit: "×",value: $settings.groundReflection,range: 0...0.8)
                Text(String(format: "%@ %.3f μs",L("Echo delay"),TVPropagationModel.evaluate(settings).groundDelaySeconds*1e6))
                    .font(.caption).foregroundStyle(.secondary)
            case .echo:
                Text(L("Additional reflection")).fontWeight(.semibold)
                TVSceneValueField(name: "Echo amplitude",unit: "×",value: $echoGain,range: 0...0.9)
                TVSceneValueField(name: "Echo delay",unit: "μs",value: $echoDelay,range: 0...20)
                TVSceneValueField(name: "Echo phase",unit: "°",value: $echoPhase,range: -180...180)
            }
        }.padding(14).frame(width: 270).foregroundStyle(TVPropagationPalette.ink).environment(\.colorScheme,.dark)
    }
}
