import XCTest
import SwiftUI
import AppKit
@testable import AnalogCore
@testable import AnalogGUI

/// Guards the invalidation width of one parameter change.
///
/// `ObservableObject` invalidates at object level: while `settings` was a
/// published property on the model, dragging a single knob rebuilt
/// `RadioSceneView`, every transmitter card and every spectrum — measured at
/// 14–17 ms, which alone blows the 16.7 ms frame budget. The scene must stay
/// out of it; only the edited station may redraw.
final class RadioSceneInvalidationTests: XCTestCase {
    @MainActor private func hosted(_ model: RadioSceneModel) -> (NSHostingView<AnyView>,NSWindow) {
        let view = AnyView(RadioSceneView(model: model).frame(width: 1200,height: 920)
            .environment(\.colorScheme,.dark).background(Color(white: 0.15)))
        let host = NSHostingView(rootView: view)
        let window = NSWindow(contentRect: NSRect(x: -10000,y: -10000,width: 1200,height: 920),
            styleMask: [.borderless],backing: .buffered,defer: false)
        window.isReleasedWhenClosed = false; window.appearance = NSAppearance(named: .darkAqua)
        window.contentView = host; host.frame = NSRect(origin: .zero,size: NSSize(width: 1200,height: 920))
        host.layoutSubtreeIfNeeded()
        return (host,window)
    }
    @MainActor func testOneKnobMoveTouchesOneCard() async throws {
        #if DEBUG
        throw XCTSkip("Measure the production renderer with -c release")
        #else
        // The rack is fixed at eight slots, so the sweep is over how many
        // stations are on air rather than over how many exist: a powered-down
        // station keeps its card but stops drawing a spectrum.
        for enabledCount in [2,8] {
            let model = RadioSceneModel()
            model.configure { settings in
                for slot in settings.transmitters.indices { settings.transmitters[slot].enabled = slot < enabledCount }
            }
            let processor = RadioSceneProcessor(startSample: 0)
            for _ in 0..<8 {
                let result = try await processor.process(settings: model.settings,clips: [:])
                for (id,spectrum) in result.frame.transmitSpectra { model.txDisplay(id).apply(spectrum) }
                for (id,reception) in result.frame.receptions { model.rxDisplay(id).apply(reception,time: 0) }
            }
            let (host,window) = hosted(model)
            defer { window.close() }
            try await Task.sleep(for: .milliseconds(60))
            host.layoutSubtreeIfNeeded(); host.displayIfNeeded()
            RadioSceneTelemetry.reset()
            let edited = model.settings.transmitters[0].id
            model.editTX(edited) { $0.powerDB += 0.5 }
            let began = ContinuousClock.now
            host.layoutSubtreeIfNeeded(); host.displayIfNeeded()
            let d = began.duration(to: .now).components
            let ms = (Double(d.seconds)+Double(d.attoseconds)/1e18)*1000
            print(String(format: "RADIO_SCENE_INVALIDATION onAir=%d oneKnob=%.2f ms scene=%d card=%d spectrum=%d",
                enabledCount,ms,RadioSceneTelemetry.sceneBodies,RadioSceneTelemetry.cardBodies,RadioSceneTelemetry.spectrumBodies))
            XCTAssertEqual(RadioSceneTelemetry.sceneBodies,0,
                "A knob move must not rebuild the whole radio scene")
            XCTAssertEqual(RadioSceneTelemetry.cardBodies,1,
                "A knob move must redraw exactly the edited card")
            XCTAssertLessThan(ms,12,"One knob move must fit comfortably inside a frame")
            XCTAssertLessThan(RadioSceneTelemetry.knobDragPushNanos/1_000_000,5,
                "The parameter hand-off must stay sub-millisecond")
        }
        #endif
    }
}
