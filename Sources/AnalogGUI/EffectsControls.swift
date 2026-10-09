import SwiftUI
import AppKit
import AnalogCore

struct ParameterSlider: View {
    let name: String
    @Binding var value: Float
    let defaultValue: Float
    let range: ClosedRange<Float>
    var percent = false
    var body: some View {
        VStack(spacing: 3) {
            HStack {
                Text(name); Spacer()
                Text(percent ? String(format: "%.0f%%",value*100) : String(format: "%.2f",value))
                    .monospacedDigit().foregroundStyle(.secondary)
            }.font(.caption)
            ResettableSlider(value: $value,defaultValue: defaultValue,range: range,label: name)
                .frame(height: 20)
                .help(L("Double-click to restore the default value"))
        }
    }
}

/// Handle double-clicks in the native control so normal drag/keyboard handling
/// remains NSSlider's responsibility, without a competing SwiftUI tap gesture.
private struct ResettableSlider: NSViewRepresentable {
    @Binding var value: Float
    let defaultValue: Float
    let range: ClosedRange<Float>
    let label: String

    final class Control: NSSlider {
        var resetValue: Double = 0
        override func mouseDown(with event: NSEvent) {
            if event.clickCount == 2 {
                doubleValue = min(maxValue,max(minValue,resetValue))
                sendAction(action,to: target)
            } else { super.mouseDown(with: event) }
        }
    }
    @MainActor
    final class Coordinator: NSObject {
        var value: Binding<Float>
        init(value: Binding<Float>) { self.value = value }
        @objc func changed(_ sender: NSSlider) { value.wrappedValue = sender.floatValue }
    }
    func makeCoordinator() -> Coordinator { Coordinator(value: $value) }
    func makeNSView(context: Context) -> Control {
        let slider = Control()
        slider.isContinuous = true
        slider.target = context.coordinator
        slider.action = #selector(Coordinator.changed(_:))
        slider.setContentHuggingPriority(.defaultLow,for: .horizontal)
        return slider
    }
    func updateNSView(_ slider: Control,context: Context) {
        context.coordinator.value = $value
        slider.minValue = Double(range.lowerBound); slider.maxValue = Double(range.upperBound)
        slider.resetValue = Double(defaultValue); slider.floatValue = value
        slider.setAccessibilityLabel(label)
        slider.setAccessibilityHelp(L("Double-click to restore the default value"))
    }
}

struct EffectsControls: View {
    @ObservedObject var model: PreviewModel
    var body: some View {
        ScrollView {
            VStack(alignment: .leading,spacing: 16) {
                GroupBox(L("LUT")) {
                    VStack(spacing: 10) {
                        ParameterSlider(name: L("Mix"),value: $model.settings.lutMix,defaultValue: EffectSettings().lutMix,range: 0...1,percent: true)
                        if model.library?.presets.first(where: { $0.id == model.selected })?.role == "sceneToDisplay" {
                            ParameterSlider(name: L("PoLUT Exposure · EV"),value: $model.settings.lutExposureEV,defaultValue: EffectSettings().lutExposureEV,range: -3...3)
                                .help(L("Adjust exposure in linear light before the LUT; default is 0 EV"))
                        }
                    }.padding(.top,6)
                }
                GroupBox(L("Grain")) {
                    VStack(spacing: 10) {
                        ParameterSlider(name: L("Grain Amount"),value: $model.settings.grain.amount,defaultValue: EffectSettings().grain.amount,range: 0...1,percent: true)
                        ParameterSlider(name: L("Grain Size"),value: $model.settings.grain.size,defaultValue: EffectSettings().grain.size,range: 0.5...8)
                        ParameterSlider(name: L("Grain Texture"),value: $model.settings.grain.texture,defaultValue: EffectSettings().grain.texture,range: 0...1)
                            .help("控制颗粒尺寸的差异：越高粒径分布越宽")
                        ParameterSlider(name: L("Grain Blur"),value: $model.settings.grain.blur,defaultValue: EffectSettings().grain.blur,range: 0...2)
                            .help(L("Blur the grain texture only, not the photo"))
                        HStack {
                            Text("Seed \(model.settings.grain.seed)").font(.caption).foregroundStyle(.secondary)
                            Spacer()
                            Button(L("New grain")) { model.settings.grain.seed &+= 1 }.controlSize(.small)
                        }
                    }.padding(.top,6)
                }
                GroupBox(L("Light Leak · Procedural")) {
                    VStack(spacing: 10) {
                        ParameterSlider(name: L("Leak Amount"),value: $model.settings.leak.amount,defaultValue: EffectSettings().leak.amount,range: 0...1,percent: true)
                        ParameterSlider(name: L("Position X"),value: $model.settings.leak.x,defaultValue: EffectSettings().leak.x,range: 0...1)
                        ParameterSlider(name: L("Position Y"),value: $model.settings.leak.y,defaultValue: EffectSettings().leak.y,range: 0...1)
                        ParameterSlider(name: L("Width"),value: $model.settings.leak.width,defaultValue: EffectSettings().leak.width,range: 0.03...1)
                        ParameterSlider(name: L("Length"),value: $model.settings.leak.length,defaultValue: EffectSettings().leak.length,range: 0.1...2)
                        ParameterSlider(name: L("Rotation °"),value: $model.settings.leak.rotation,defaultValue: EffectSettings().leak.rotation,range: -180...180)
                        ParameterSlider(name: L("Hue °"),value: $model.settings.leak.hue,defaultValue: EffectSettings().leak.hue,range: 0...360)
                        ParameterSlider(name: L("Softness"),value: $model.settings.leak.softness,defaultValue: EffectSettings().leak.softness,range: 0...1)
                        ParameterSlider(name: L("Irregularity"),value: $model.settings.leak.irregularity,defaultValue: EffectSettings().leak.irregularity,range: 0...1)
                        HStack {
                            Text("Seed \(model.settings.leak.seed)").font(.caption).foregroundStyle(.secondary)
                            Spacer()
                            Button(L("New leak")) { model.settings.leak.seed &+= 1 }.controlSize(.small)
                        }
                    }.padding(.top,6)
                }
                Button(L("Reset effect parameters")) { model.settings = EffectSettings() }.frame(maxWidth: .infinity)
            }.padding(.trailing,8)
        }
    }
}
