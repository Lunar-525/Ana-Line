import XCTest
import SwiftUI
import AppKit
import Combine
import AnalogCore
@testable import AnalogGUI

@MainActor
final class TVRackTests: XCTestCase {
    private func wheel(_ delta: Int32,shift: Bool = false,precise: Bool = false,momentum: Bool = false) throws -> NSEvent {
        // Event objects are data passed directly to the control under test.
        // They are never posted into the user's input stream.
        let event = try XCTUnwrap(CGEvent(scrollWheelEvent2Source: nil,units: precise ? .pixel : .line,wheelCount: 1,wheel1: delta,wheel2: 0,wheel3: 0))
        if shift { event.flags = .maskShift }
        if precise { event.setIntegerValueField(.scrollWheelEventIsContinuous,value: 1) }
        if momentum { event.setIntegerValueField(.scrollWheelEventMomentumPhase,value: 2) }
        return try XCTUnwrap(NSEvent(cgEvent: event))
    }
    func testWheelFineAdjustmentBoundsAndMomentum() throws {
        let dial = TVNativeKnob.Dial(); dial.lower = -1; dial.upper = 1; dial.increment = 0.1
        dial.scrollWheel(with: try wheel(1)); XCTAssertEqual(dial.position,0.1,accuracy: 1e-6)
        dial.scrollWheel(with: try wheel(-1)); XCTAssertEqual(dial.position,0,accuracy: 1e-6)
        dial.scrollWheel(with: try wheel(1,shift: true)); XCTAssertEqual(dial.position,0.01,accuracy: 1e-6)
        dial.scrollWheel(with: try wheel(100)); XCTAssertEqual(dial.position,1)
        dial.scrollWheel(with: try wheel(-100)); XCTAssertEqual(dial.position,-1)
        let event = try wheel(10,momentum: true)
        XCTAssertFalse(event.momentumPhase.isEmpty)
        dial.scrollWheel(with: event); XCTAssertEqual(dial.position,-1)
        dial.isEnabled = false; dial.setPosition(0); XCTAssertEqual(dial.position,-1)
    }
    func testPreciseScrollAccumulatesAndDoubleClickResets() throws {
        let dial = TVNativeKnob.Dial(); dial.upper = 24; dial.increment = 0.1; dial.reset = 6
        for _ in 0..<7 { dial.scrollWheel(with: try wheel(1,precise: true)) }
        XCTAssertEqual(dial.position,0)
        dial.scrollWheel(with: try wheel(1,precise: true)); XCTAssertEqual(dial.position,0.1,accuracy: 1e-6)
        let click = try XCTUnwrap(NSEvent.mouseEvent(with: .leftMouseDown,location: .zero,modifierFlags: [],
            timestamp: 0,windowNumber: 0,context: nil,eventNumber: 0,clickCount: 2,pressure: 1))
        dial.mouseDown(with: click); XCTAssertEqual(dial.position,6)
        XCTAssertTrue(dial.accessibilityPerformIncrement()); XCTAssertEqual(dial.position,6.1,accuracy: 1e-6)
    }
    func testMeterRefreshDoesNotInvalidateRackControlsOrWorkspace() {
        let model = PreviewModel(); model.tvControlState.bind(model)
        var controls = 0, workspace = 0
        let a = model.tvControlState.objectWillChange.sink { controls += 1 }
        let b = model.objectWillChange.sink { workspace += 1 }
        model.tvTXInstrumentState.reading = TVTransmitterTelemetry()
        XCTAssertEqual(controls,0); XCTAssertEqual(workspace,0)
        withExtendedLifetime((a,b)) {}
    }
    func testNativeRackSnapshots() async throws {
        guard ProcessInfo.processInfo.environment["ANALINE_CAPTURE_RACK"] == "1" else {
            throw XCTSkip("Opt-in native rack layout verification")
        }
        _ = NSApplication.shared
        let model = PreviewModel()
        model.tvChannel.transmitter.enabled = true
        model.tvChannel.transmitter.encoder.enabled = true
        model.tvChannel.transmitter.vsb.enabled = true
        model.tvChannel.transmitter.vsb.groupDelayNS = -500
        model.tvChannel.transmitter.encoder.differentialGain = -1
        model.tvChannel.transmitter.encoder.differentialPhaseDegrees = -90
        model.tvChannel.transmitter.audioDriveDB = 24
        model.tvChannel.transmitter.powerDB = -60
        var fixture = TVTransmitterTelemetry(); fixture.forwardPower = 0.62; fixture.reflectedPower = 0.155
        fixture.saturated = true; fixture.overmodulated = true; fixture.referencePower = 1.1
        model.tvTXInstrumentState.reading = fixture
        let window = NSWindow(contentRect: NSRect(x: 60,y: 60,width: 460,height: 460),
                              styleMask: [.titled,.closable],backing: .buffered,defer: false)
        window.isReleasedWhenClosed = false
        defer { window.orderOut(nil); window.contentView = nil; window.close() }
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        for width in [460,380] {
            window.contentView = NSHostingView(rootView: TVTransmitterControls(model: model)
                .padding(20).frame(width: CGFloat(width),height: 460,alignment: .top).background(Color(white: 0.06)))
            window.setContentSize(NSSize(width: width,height: 460)); window.orderFront(nil)
            try await Task.sleep(for: .milliseconds(200))
            let view = try XCTUnwrap(window.contentView)
            let bitmap = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
            view.cacheDisplay(in: view.bounds,to: bitmap)
            try XCTUnwrap(bitmap.representation(using: .png,properties: [:]))
                .write(to: root.appendingPathComponent("build/TV-rack-\(width).png"))
        }
    }
}
