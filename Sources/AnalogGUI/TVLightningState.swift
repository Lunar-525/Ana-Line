import SwiftUI
import AnalogCore

/// Observed only by the bolt canvas, never the workspace or terrain controls.
@MainActor
final class TVLightningState: ObservableObject {
    struct Flash: Equatable {
        let event: TVLightningEvent
        let age: Double
        var opacity: Double { sqrt(Double(event.intensity))*exp(-age*9) }
        // One short whole-panel pulse, followed by the longer bolt afterglow.
        var panelOpacity: Double { age < 0.16 ? 0.24*Double(event.intensity)*exp(-age/0.045) : 0 }
        var horizontalFraction: Double { 0.3+Double(event.token % 43)/100 }
    }
    @Published private(set) var flash: Flash?
    private var event: TVLightningEvent?
    private var firstFrameTime = 0.0
    private var lastFrameTime: Double?

    /// Latch even a 3 ms pulse when its affected frame becomes visible. The
    /// short visual afterglow follows presented media time: pause freezes it,
    /// buffering cannot trigger it early, and repeated presentations do nothing.
    func present(events: [TVLightningEvent], time: Double) {
        if let lastFrameTime, time < lastFrameTime { reset() }
        lastFrameTime = time
        if let latest = events.last {
            if latest.token != event?.token || latest.time != event?.time { firstFrameTime = time }
            event = latest
        }
        let age = max(0,time-firstFrameTime)
        let next = event.flatMap { age < 0.32 ? Flash(event: $0,age: age) : nil }
        if next != flash { flash = next }
    }

    func reset() {
        event = nil; lastFrameTime = nil
        if flash != nil { flash = nil }
    }
}

struct TVLightningOverlay: View {
    @ObservedObject var state: TVLightningState
    var body: some View {
        // Synchronous drawing keeps the initial bolt on the same presentation
        // update as the video frame. This tiny path needs no independent timer.
        Canvas { context,size in
            guard let flash = state.flash else { return }
            let h = Double(size.height)-26, x = Double(size.width)*flash.horizontalFraction
            var bolt = Path(); bolt.addLines([
                CGPoint(x: x,y: 26),CGPoint(x: x-13,y: h*0.3),
                CGPoint(x: x+3,y: h*0.3-3),CGPoint(x: x-18,y: h*0.61),
                CGPoint(x: x-6,y: h*0.59),CGPoint(x: x-27,y: h-5)
            ])
            context.stroke(bolt,with: .color(TVPropagationPalette.accent.opacity(flash.opacity*0.4)),lineWidth: 6)
            context.stroke(bolt,with: .color(TVPropagationPalette.flash.opacity(flash.opacity*0.95)),lineWidth: 1.3)
            var branch = Path(); branch.addLines([CGPoint(x: x-18,y: h*0.61),
                CGPoint(x: x-33,y: h*0.65),CGPoint(x: x-44,y: h*0.85)])
            context.stroke(branch,with: .color(TVPropagationPalette.flash.opacity(flash.opacity*0.55)),lineWidth: 0.7)
        }.allowsHitTesting(false).accessibilityHidden(true)
    }
}

/// Only this lightweight wash subscribes to strike frames. The header, terrain
/// and controls keep their existing configuration-only observation cadence.
struct TVLightningPanelFlash: View {
    @ObservedObject var state: TVLightningState
    let enabled: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var body: some View {
        Canvas { context,size in
            guard enabled, let flash = state.flash, flash.panelOpacity > 0 else { return }
            context.fill(Path(CGRect(origin: .zero,size: size)),
                with: .color(TVPropagationPalette.flash.opacity(flash.panelOpacity*(reduceMotion ? 0.25 : 1))))
        }.allowsHitTesting(false).accessibilityHidden(true)
    }
}
