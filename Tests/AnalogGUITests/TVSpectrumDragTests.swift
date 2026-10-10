import XCTest
import AppKit
import SwiftUI
@testable import AnalogGUI

@MainActor
final class TVSpectrumDragTests: XCTestCase {
    private func event(_ type: NSEvent.EventType,at point: NSPoint,
                       in view: NSView,shift: Bool = false) throws -> NSEvent {
        // Local event data only; no events are posted to the user's input stream.
        try XCTUnwrap(NSEvent.mouseEvent(with: type,location: view.convert(point,to: nil),
            modifierFlags: shift ? .shift : [],timestamp: 0,windowNumber: view.window!.windowNumber,
            context: nil,eventNumber: 0,clickCount: 1,pressure: 1))
    }
    private func fixture() -> (NSWindow,TVSpectrumDragSurface.Surface) {
        _ = NSApplication.shared
        let view = TVSpectrumDragSurface.Surface(frame: NSRect(x: 0,y: 0,width: 500,height: 100))
        view.sampleRate = 20_000_000
        let window = NSWindow(contentRect: view.frame,styleMask: .borderless,backing: .buffered,defer: false)
        window.isReleasedWhenClosed = false; window.contentView = view
        return (window,view)
    }
    func testHostedSpectrumOverlayReceivesInputAndUpdatesReceiver() async throws {
        _ = NSApplication.shared
        let model = PreviewModel(); model.tvControlState.bind(model)
        let host = NSHostingView(rootView: TVReceptionView(model: model).frame(width: 800,height: 174))
        let window = NSWindow(contentRect: NSRect(x: 0,y: 0,width: 800,height: 174),
            styleMask: .borderless,backing: .buffered,defer: false)
        window.isReleasedWhenClosed = false; window.contentView = host
        defer { window.contentView = nil; window.close() }
        try await Task.sleep(for: .milliseconds(100))
        host.layoutSubtreeIfNeeded()
        func surface(in view: NSView) -> TVSpectrumDragSurface.Surface? {
            if let found = view as? TVSpectrumDragSurface.Surface { return found }
            for child in view.subviews { if let found = surface(in: child) { return found } }
            return nil
        }
        let dragView = try XCTUnwrap(surface(in: host))
        XCTAssertGreaterThan(dragView.bounds.width,300)
        let start = NSPoint(x: dragView.bounds.midX,y: 50)
        XCTAssertTrue(host.hitTest(host.convert(start,from: dragView)) === dragView,
            "The transparent native overlay must be reachable through SwiftUI hit testing")
        try dragView.mouseDown(with: event(.leftMouseDown,at: start,in: dragView))
        try dragView.mouseDragged(with: event(.leftMouseDragged,
            at: NSPoint(x: start.x+10,y: start.y),in: dragView))
        XCTAssertGreaterThan(model.tvChannel.tuningOffsetKHz,0)
        XCTAssertEqual(model.tvControlState.tvChannel.tuningOffsetKHz,model.tvChannel.tuningOffsetKHz)
    }
    func testMarkerDragFineControlAndKnobStateStayInSync() throws {
        let (window,view) = fixture()
        defer { window.contentView = nil; window.close() }
        let model = PreviewModel(); model.tvControlState.bind(model)
        var callbacks = 0
        view.onChange = { next in
            callbacks += 1
            var channel = model.tvChannel
            channel.tuningOffsetKHz = Float(next.offsetHz/1000)
            channel.rfBandwidthMHz = Float(next.bandwidthHz/1e6)
            model.tvChannel = channel
        }
        XCTAssertEqual(view.part(at: NSPoint(x: 255,y: 60)),.tuning)
        XCTAssertNil(view.part(at: NSPoint(x: 100,y: 60)),"Empty plot areas must not intercept mouse input")
        try view.mouseDown(with: event(.leftMouseDown,at: NSPoint(x: 255,y: 60),in: view))
        try view.mouseDragged(with: event(.leftMouseDragged,at: NSPoint(x: 280,y: 60),in: view,shift: true))
        XCTAssertEqual(model.tvChannel.tuningOffsetKHz,100,accuracy: 0.001)
        XCTAssertEqual(model.tvControlState.tvChannel.tuningOffsetKHz,100,accuracy: 0.001)
        XCTAssertEqual(model.tvChannel.rfBandwidthMHz,8)
        try view.mouseUp(with: event(.leftMouseUp,at: NSPoint(x: 280,y: 60),in: view))
        try view.mouseDragged(with: event(.leftMouseDragged,at: NSPoint(x: 300,y: 60),in: view))
        XCTAssertEqual(callbacks,1,"Mouse-up must release the latched drag target")
    }
    func testPassbandEdgesResizeWithPhysicalConstraints() throws {
        let (window,view) = fixture()
        defer { window.contentView = nil; window.close() }
        XCTAssertEqual(view.part(at: NSPoint(x: 418.75,y: 6)),.upperEdge)
        try view.mouseDown(with: event(.leftMouseDown,at: NSPoint(x: 418.75,y: 6),in: view))
        try view.mouseDragged(with: event(.leftMouseDragged,at: NSPoint(x: 393.75,y: 6),in: view))
        XCTAssertEqual(view.tuning.bandwidthHz,7_000_000,accuracy: 0.01)
        XCTAssertEqual(view.tuning.offsetHz,0)
        try view.mouseUp(with: event(.leftMouseUp,at: NSPoint(x: 393.75,y: 6),in: view))
        view.refresh(tuning: .init(offsetHz: 0,bandwidthHz: 8_000_000,carrierHz: 0),
            centerHz: 0,sampleRate: 20_000_000)
        let anchoredRight = view.tuning.upperHz
        try view.mouseDown(with: event(.leftMouseDown,at: NSPoint(x: 218.75,y: 6),in: view))
        try view.mouseDragged(with: event(.leftMouseDragged,at: NSPoint(x: 243.75,y: 6),in: view))
        XCTAssertEqual(view.tuning.offsetHz,1_000_000,accuracy: 0.01)
        XCTAssertEqual(view.tuning.bandwidthHz,7_000_000,accuracy: 0.01)
        XCTAssertEqual(view.tuning.upperHz,anchoredRight,accuracy: 0.01)
        try view.mouseDragged(with: event(.leftMouseDragged,at: NSPoint(x: 343.75,y: 6),in: view))
        XCTAssertEqual(view.tuning.offsetHz,1_500_000)
        XCTAssertEqual(view.tuning.upperHz,anchoredRight)
        let maximum = view.tuning.dragged(.upperEdge,by: 20_000_000)
        let minimum = maximum.dragged(.upperEdge,by: -20_000_000)
        XCTAssertEqual(maximum.bandwidthHz,10_000_000)
        XCTAssertEqual(minimum.bandwidthHz,1_000_000)
    }
    func testSoundSliceUsesItsOwnFrequencyScaleAndDoesNotInventEdgeHandles() throws {
        let (window,view) = fixture()
        defer { window.contentView = nil; window.close() }
        view.refresh(tuning: .init(offsetHz: 0,bandwidthHz: 8_000_000,carrierHz: 6_500_000),
            centerHz: 6_500_000,sampleRate: 384_000)
        XCTAssertEqual(view.part(at: NSPoint(x: 1,y: 6)),.tuning,
            "The clipped bracket is a tuning handle, not a false IF edge")
        try view.mouseDown(with: event(.leftMouseDown,at: NSPoint(x: 250,y: 50),in: view))
        try view.mouseDragged(with: event(.leftMouseDragged,at: NSPoint(x: 275,y: 50),in: view))
        XCTAssertEqual(view.tuning.offsetHz,19_200,accuracy: 0.01)
        XCTAssertEqual(view.tuning.bandwidthHz,8_000_000)
    }
}
