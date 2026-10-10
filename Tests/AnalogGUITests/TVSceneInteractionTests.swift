import XCTest
import SwiftUI
import AppKit
import AnalogCore
@testable import AnalogGUI

@MainActor
final class TVSceneInteractionTests: XCTestCase {
    func testSceneBypassRetainsEditableEchoAndRestoresActualRFSettings() {
        let model = PreviewModel(); model.tvControlState.bind(model)
        let state = model.tvControlState
        state.tvChannel.echoGain = 0.4
        state.tvChannel.echoDelayMicroseconds = 8
        state.setPropagationEnabled(false)
        XCTAssertFalse(model.tvChannel.propagation.enabled)
        XCTAssertEqual(model.tvChannel.echoGain,0)
        XCTAssertEqual(state.sceneEchoGain,0.4)
        state.setSceneEchoGain(0.65)
        XCTAssertEqual(model.tvChannel.echoGain,0,"Editing a bypassed path must not restore an audible RF echo")
        state.setPropagationEnabled(true)
        XCTAssertTrue(model.tvChannel.propagation.enabled)
        XCTAssertEqual(model.tvChannel.echoGain,0.65)
        XCTAssertEqual(model.tvChannel.echoDelayMicroseconds,8)
    }
    func testEquivalentReflectorExtraPathAndDelayRoundTrip() {
        for distance in [3_000.0,10_000,50_000] {
            for delay in [0.0,0.000001,0.5,3,8,20] {
                let offset = TVEchoGeometry.offset(delayUS: delay,directMetres: distance)
                let totalPath = 2*hypot(distance/2,offset)
                XCTAssertEqual(totalPath-distance,delay*299.792458,accuracy: 1e-8)
                XCTAssertEqual(TVEchoGeometry.delayUS(offsetMetres: offset,directMetres: distance),delay,accuracy: 1e-10)
            }
        }
    }
    func testScreenReflectionDragAndFrozenGeometry() {
        for distance: Float in [3,10,50] {
            var settings = TVPropagationSettings(); settings.distanceKm = distance
            settings.ridgeEnabled = true; settings.ridgeHeightM = 500
            let geometry = TVSceneGeometry(size: CGSize(width: 276,height: 373),settings: settings)
            for delay: Float in [0,3,8,20] {
                let p = geometry.echoPoint(delay: delay)
                XCTAssertEqual(geometry.echoDelay(at: p),delay,accuracy: 1e-5)
                XCTAssertTrue((geometry.top...geometry.bottom).contains(p.y))
            }
            XCTAssertEqual(geometry.echoDelay(at: CGPoint(x: 0,y: -500)),20)
            XCTAssertEqual(geometry.echoDelay(at: CGPoint(x: 0,y: 1000)),0)
            settings.distanceKm = 45; settings.ridgeHeightM = 2
            let duringDrag = TVSceneGeometry(size: geometry.size,settings: settings,
                frozenScale: geometry.heightScale,frozenSpan: geometry.span)
            XCTAssertEqual(duringDrag.heightScale,geometry.heightScale)
            XCTAssertEqual(duringDrag.span,geometry.span)
            XCTAssertEqual(duringDrag.metresX(geometry.x(3000)),3000,accuracy: 1e-8)
        }
    }
    func testWheelUpdatesRFBindingAndLeavesClicksAvailable() throws {
        let model = PreviewModel(); model.tvControlState.bind(model)
        let region = TVSceneWheel.Region()
        region.value = 12; region.range = -5...25; region.step = 0.5
        region.change = { model.tvControlState.tvChannel.propagation.antennaGainDB = $0 }
        let cg = try XCTUnwrap(CGEvent(scrollWheelEvent2Source: nil,units: .line,wheelCount: 1,wheel1: 2,wheel2: 0,wheel3: 0))
        let event = try XCTUnwrap(NSEvent(cgEvent: cg))
        region.scrollWheel(with: event)
        XCTAssertEqual(model.tvChannel.propagation.antennaGainDB,13)
        cg.flags = .maskShift
        region.scrollWheel(with: try XCTUnwrap(NSEvent(cgEvent: cg)))
        XCTAssertEqual(model.tvChannel.propagation.antennaGainDB,13.1,accuracy: 1e-5)
        XCTAssertNil(region.hitTest(.zero),"An overlay must not capture ordinary click/drag hit testing")
        region.enabled = false
        region.scrollWheel(with: event)
        XCTAssertEqual(model.tvChannel.propagation.antennaGainDB,13.1,accuracy: 1e-5)
    }
}
