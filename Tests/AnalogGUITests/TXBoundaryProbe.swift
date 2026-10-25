import XCTest
import SwiftUI
import AppKit
import QuartzCore
@testable import AnalogCore
@testable import AnalogGUI

/// Directly delivers trackpad-shaped events to the real NSScrollView. No events
/// are posted to the user's global input stream. Momentum is supplied explicitly:
/// AppKit receives momentum phases from the device, not from a position sweep.
final class TXBoundaryProbe: XCTestCase {
    @available(macOS 14.0, *)
    @MainActor private final class FrameClock: NSObject {
        var active = false { didSet { previous = nil } }
        var gaps: [Double] = []
        private var previous: CFTimeInterval?
        @objc func tick(_ link: CADisplayLink) {
            guard active else { return }
            let now = CACurrentMediaTime()
            if let previous { gaps.append((now-previous)*1000) }
            previous = now
        }
    }
    @MainActor private func scrollViews(_ view: NSView) -> [NSScrollView] {
        (view as? NSScrollView).map { [$0] } ?? view.subviews.flatMap { scrollViews($0) }
    }
    @MainActor private func wheel(_ delta: Int32, window: NSWindow, phase: Int64 = 0, momentum: Int64 = 0) throws -> NSEvent {
        let cg = try XCTUnwrap(CGEvent(scrollWheelEvent2Source: nil, units: .pixel,
                                      wheelCount: 1, wheel1: delta, wheel2: 0, wheel3: 0))
        cg.timestamp = DispatchTime.now().uptimeNanoseconds
        cg.setIntegerValueField(.mouseEventWindowUnderMousePointer, value: Int64(window.windowNumber))
        cg.setIntegerValueField(.mouseEventWindowUnderMousePointerThatCanHandleThisEvent, value: Int64(window.windowNumber))
        cg.setIntegerValueField(.scrollWheelEventIsContinuous, value: 1)
        cg.setIntegerValueField(.scrollWheelEventScrollPhase, value: phase)
        cg.setIntegerValueField(.scrollWheelEventMomentumPhase, value: momentum)
        return try XCTUnwrap(NSEvent(cgEvent: cg))
    }
    private func milliseconds(_ start: ContinuousClock.Instant, _ end: ContinuousClock.Instant = .now) -> Double {
        let d = start.duration(to: end).components
        return Double(d.seconds)*1000 + Double(d.attoseconds)/1e15
    }
    private func percentile(_ values: [Double], _ fraction: Double) -> Double {
        let sorted = values.sorted()
        return sorted[min(sorted.count-1, Int(Double(sorted.count-1)*fraction))]
    }
    @MainActor func testFastBurstAndMomentum() async throws {
        #if DEBUG
        throw XCTSkip("Scroll budgets require the optimized app")
        #else
        guard #available(macOS 14.0, *) else { throw XCTSkip("Display cadence measurement requires macOS 14") }
        // The rack is fixed at eight stations, so the scroll range no longer
        // varies with a station count; the probe compares the drag mechanisms on
        // the one configuration instead of sweeping 6/7/8.
        for onAir in [RadioSceneSettings.transmitterSlots] {
            for mechanism in [WindowDragMechanism.gesture,.none,.native] {
                let model = RadioSceneModel()
                XCTAssertEqual(model.settings.transmitters.count,onAir)
                model.muted = true
                let root = AnyView(VStack(spacing: 0) {
                    HStack {
                        Text("Radio")
                        WindowDragSpacer(mechanism: mechanism)
                        Button("Control") {}
                    }.padding(20).frame(height: 80)
                        .modifier(WindowDragRegion(mechanism: mechanism))
                    ScrollView { RadioSceneView(model: model) }
                }.frame(width: 1100,height: 500)
                    .environment(\.colorScheme,.dark)
                    .background(WorkspaceGlassBackground()))
                let host = NSHostingView(rootView: root)
                let window = NSWindow(contentRect: NSRect(x: 80,y: 80,width: 1100,height: 500),
                    styleMask: [.titled,.closable],backing: .buffered,defer: false)
                window.isReleasedWhenClosed = false
                window.appearance = NSAppearance(named: .darkAqua)
                window.contentView = host
                window.orderFrontRegardless()
                model.play()
                defer { model.pause(); window.close() }
                try await Task.sleep(for: .milliseconds(450))
                host.layoutSubtreeIfNeeded(); window.displayIfNeeded()
                let scroll = try XCTUnwrap(scrollViews(host).max { a,b in
                    (a.documentView?.frame.height ?? 0)-a.contentView.bounds.height <
                    (b.documentView?.frame.height ?? 0)-b.contentView.bounds.height
                })
                let clip = scroll.contentView
                let range = (clip.documentView?.frame.height ?? 0)-clip.bounds.height
                XCTAssertGreaterThan(range,300,"A short scroll range invalidates this benchmark")
                XCTAssertFalse(window.isMovableByWindowBackground)
                let frameClock = FrameClock()
                var displayLink: CADisplayLink?
                if #available(macOS 14.0, *) {
                    displayLink = window.displayLink(target: frameClock,selector: #selector(FrameClock.tick(_:)))
                    displayLink?.add(to: .main,forMode: .common)
                }
                defer { displayLink?.invalidate() }
                var costs: [Double] = [], intervals: [Double] = []
                var travel: CGFloat = 0, momentumTravel: CGFloat = 0
                // Three flicks in alternating directions. Fingers move for only
                // ~25 ms; the remaining ~350 ms is a decaying momentum tail.
                for repeatIndex in 0..<3 {
                    frameClock.active = true
                    let direction: Int32 = repeatIndex % 2 == 0 ? -1 : 1
                    var previousTick: ContinuousClock.Instant?
                    var sequence: [(Int32,Int64,Int64)] = [(45,1,0),(90,2,0),(120,2,0),(0,4,0)]
                    for n in 0..<42 {
                        let delta = Int32((25.0 * exp(-Double(n)/12.0)).rounded())
                        let momentum: Int64 = n == 0 ? 1 : 2
                        sequence.append((delta,0,momentum))
                    }
                    sequence.append((0,0,3))
                    for (delta,phase,momentum) in sequence {
                        let event = try wheel(delta*direction,window: window,phase: phase,momentum: momentum)
                        let start = ContinuousClock.now
                        if let previousTick { intervals.append(milliseconds(previousTick,start)) }
                        previousTick = start
                        let before = clip.bounds.origin.y
                        if repeatIndex == 0 && costs.isEmpty {
                            print("FLICK_EVENT delta=\(event.scrollingDeltaY) phase=\(event.phase.rawValue) window=\(event.windowNumber) scroll=\(type(of: scroll))")
                        }
                        scroll.scrollWheel(with: event)
                        host.layoutSubtreeIfNeeded(); host.displayIfNeeded(); window.displayIfNeeded()
                        costs.append(milliseconds(start))
                        // Let AppKit's asynchronous scroll animation advance before
                        // measuring position; counting only the handler misses it.
                        try await Task.sleep(for: .milliseconds(8))
                        let moved = abs(clip.bounds.origin.y-before)
                        travel += moved
                        if momentum != 0 { momentumTravel += moved }
                    }
                    frameClock.active = false
                    try await Task.sleep(for: .milliseconds(150))
                }
                let mean = costs.reduce(0,+)/Double(costs.count)
                print(String(format: "RADIO_FLICK tx=%d drag=%@ range=%.0f travel=%.0f momentum=%.0f events=%d mean=%.2f p95=%.2f p99=%.2f worst=%.2f cadenceP95=%.2f underruns=%lld",
                    onAir,String(describing: mechanism),range,travel,momentumTravel,costs.count,
                    mean,percentile(costs,0.95),percentile(costs,0.99),costs.max()!,
                    percentile(intervals,0.95),model.clock.underruns))
                XCTAssertGreaterThan(travel,range*1.5,"The flicks must actually traverse the page")
                XCTAssertGreaterThan(momentumTravel,80,"Momentum events must cause measurable motion")
                if !frameClock.gaps.isEmpty {
                    print(String(format: "RADIO_FLICK_DISPLAY tx=%d drag=%@ frames=%d p95=%.2f p99=%.2f worst=%.2f",
                        onAir,String(describing: mechanism),frameClock.gaps.count,
                        percentile(frameClock.gaps,0.95),percentile(frameClock.gaps,0.99),frameClock.gaps.max()!))
                }
                if mechanism == .native {
                    if displayLink != nil {
                        XCTAssertGreaterThan(frameClock.gaps.count,20,"The display clock must observe the flicks")
                        if !frameClock.gaps.isEmpty {
                            XCTAssertLessThan(percentile(frameClock.gaps,0.95),33.34,"Main-thread display callbacks must keep up during inertia")
                        }
                    }
                    XCTAssertLessThan(percentile(costs,0.95),16.67,"Most scroll work must fit a 60 Hz frame")
                    XCTAssertLessThan(percentile(intervals,0.95),33.34,"Catch stalls outside the synchronous event handler")
                    XCTAssertEqual(model.clock.underruns,0)
                }
                model.pause(); window.close()
            }
        }
        #endif
    }
}
