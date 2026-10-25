import AppKit
import QuartzCore

/// Opt-in, in-process diagnostic for the complete packaged app. It does not
/// post input globally or touch another application. Normal launches never run it.
@MainActor
@available(macOS 14.0, *)
enum RadioTrackpadProbe {
    private final class FrameClock: NSObject {
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
    private static func scrollViews(_ view: NSView) -> [NSScrollView] {
        (view as? NSScrollView).map { [$0] } ?? view.subviews.flatMap { scrollViews($0) }
    }
    private static func percentile(_ values: [Double], _ fraction: Double) -> Double {
        guard !values.isEmpty else { return -1 }
        let sorted = values.sorted()
        return sorted[min(sorted.count-1,Int(Double(sorted.count-1)*fraction))]
    }
    static func run(model: RadioSceneModel) async {
        do {
            try await Task.sleep(for: .seconds(2))
            guard let window = NSApp.windows.first(where: { $0.isVisible && $0.contentView != nil }),
                  let host = window.contentView else { print("RADIO_APP_FLICK_ERROR no window"); return }
            window.setContentSize(NSSize(width: 1100,height: 760))
            window.center()
            window.makeKeyAndOrderFront(nil)
            window.orderFrontRegardless()
            _ = NSRunningApplication.current.activate(options: [.activateAllWindows])
            print("RADIO_APP_FLICK_START pid=\(ProcessInfo.processInfo.processIdentifier) drag=\(WindowDragMechanism.current) version=\(Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") ?? "unknown")")
            fflush(stdout)
            let clock = FrameClock()
            let link = window.displayLink(target: clock,selector: #selector(FrameClock.tick(_:)))
            link.add(to: .main,forMode: .common)
            defer { link.invalidate() }
            let requested = ProcessInfo.processInfo.environment["ANALINE_SCROLL_ROUNDS"].flatMap(Int.init)
            let rounds = min(20,max(1,requested ?? 2))
            // Activation and window restoration may animate asynchronously.
            // Measure only after the actual workspace is foreground and settled.
            for _ in 0..<100 {
                if NSApp.isActive && window.occlusionState.contains(.visible) { break }
                try await Task.sleep(for: .milliseconds(100))
            }
            guard NSApp.isActive && window.occlusionState.contains(.visible) else {
                print("RADIO_APP_FLICK_ERROR window not foreground"); fflush(stdout); return
            }
            try await Task.sleep(for: .seconds(1))
            // The rack is fixed at eight stations now, so there is no station
            // count left to sweep; each round repeats the same scroll range.
            for round in 0..<rounds {
                try await Task.sleep(for: .milliseconds(400))
                host.layoutSubtreeIfNeeded(); window.displayIfNeeded()
                guard let scroll = scrollViews(host).max(by: { a,b in
                    (a.documentView?.frame.height ?? 0)-a.contentView.bounds.height <
                    (b.documentView?.frame.height ?? 0)-b.contentView.bounds.height
                }) else { print("RADIO_APP_FLICK_ERROR no scroll view"); return }
                let clip = scroll.contentView
                let range = (clip.documentView?.frame.height ?? 0)-clip.bounds.height
                guard range > 300 else { print("RADIO_APP_FLICK_ERROR insufficient range=\(range)"); return }
                var travel: CGFloat = 0, momentumTravel: CGFloat = 0
                var visibilityDrops = 0
                clock.gaps = []
                for flick in 0..<3 {
                    clock.active = true
                    let direction: Int32 = flick % 2 == 0 ? -1 : 1
                    var sequence: [(Int32,Int64,Int64)] = [(45,1,0),(90,2,0),(120,2,0),(0,4,0)]
                    for n in 0..<42 {
                        sequence.append((Int32((25.0*exp(-Double(n)/12.0)).rounded()),0,n == 0 ? 1 : 2))
                    }
                    sequence.append((0,0,3))
                    for (delta,phase,momentum) in sequence {
                        try Task.checkCancellation()
                        if !NSApp.isActive || !window.occlusionState.contains(.visible) { visibilityDrops += 1 }
                        guard let cg = CGEvent(scrollWheelEvent2Source: nil,units: .pixel,wheelCount: 1,
                                               wheel1: delta*direction,wheel2: 0,wheel3: 0) else { return }
                        cg.timestamp = DispatchTime.now().uptimeNanoseconds
                        cg.setIntegerValueField(.scrollWheelEventIsContinuous,value: 1)
                        cg.setIntegerValueField(.scrollWheelEventScrollPhase,value: phase)
                        cg.setIntegerValueField(.scrollWheelEventMomentumPhase,value: momentum)
                        guard let event = NSEvent(cgEvent: cg) else { return }
                        let before = clip.bounds.origin.y
                        scroll.scrollWheel(with: event)
                        // Do not force synchronous display: the full app's normal
                        // run loop and compositor must handle the scroll themselves.
                        try await Task.sleep(for: .milliseconds(8))
                        let moved = abs(clip.bounds.origin.y-before)
                        travel += moved
                        if momentum != 0 { momentumTravel += moved }
                    }
                    clock.active = false
                    try await Task.sleep(for: .milliseconds(150))
                }
                let active = NSApp.isActive && window.occlusionState.contains(.visible)
                let valid = active && visibilityDrops == 0 && travel > range*1.5 && momentumTravel > 80 && clock.gaps.count > 20
                print(String(format: "RADIO_APP_FLICK round=%d tx=%d rx=%d drag=%@ range=%.0f travel=%.0f momentum=%.0f frames=%d frameP95=%.2f frameP99=%.2f frameWorst=%.2f underruns=%lld active=%@ visible=%@ visibilityDrops=%d valid=%@",
                    round+1,model.settings.transmitters.filter(\.enabled).count,model.settings.receivers.count,String(describing: WindowDragMechanism.current),range,
                    travel,momentumTravel,clock.gaps.count,percentile(clock.gaps,0.95),percentile(clock.gaps,0.99),
                    clock.gaps.max() ?? -1,model.audioSnapshot.underrun,NSApp.isActive ? "yes" : "no",window.occlusionState.contains(.visible) ? "yes" : "no",visibilityDrops,valid ? "yes" : "no"))
                fflush(stdout)
            }
            print("RADIO_APP_FLICK_DONE"); fflush(stdout)
        } catch { print("RADIO_APP_FLICK_ERROR \(error)"); fflush(stdout) }
    }
}
