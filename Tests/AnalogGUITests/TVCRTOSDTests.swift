import XCTest
@testable import AnalogGUI

@MainActor
final class TVCRTOSDTests: XCTestCase {
    private func makeState() throws -> (TVOSDState, UserDefaults) {
        let name = "TVCRTOSDTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defaults.removePersistentDomain(forName: name)
        return (TVOSDState(defaults: defaults, maxLines: 576), defaults)
    }

    func testPowerAndBooleanRowsPersist() throws {
        let (state, defaults) = try makeState()
        state.openMenu()
        XCTAssertFalse(state.isOpen, "Power off must block the OSD")
        state.togglePower()
        XCTAssertTrue(state.enabled)
        state.openMenu()
        XCTAssertTrue(state.isOpen)
        state.selection = 1
        state.enter() // HDR phosphor
        XCTAssertFalse(state.hdr)
        XCTAssertEqual(defaults.object(forKey: "tvCRTHDR") as? Bool, false)
        state.selection = 3
        state.enter() // pixel perfect
        XCTAssertFalse(state.pixelPerfect)
        XCTAssertEqual(defaults.object(forKey: "tvCRTPixelPerfectStripes") as? Bool, false)
        state.selection = 0
        state.enter() // power off closes the OSD
        XCTAssertFalse(state.enabled)
        XCTAssertFalse(state.isOpen)
        XCTAssertEqual(defaults.object(forKey: "tvCRTEnabled") as? Bool, false)
    }

    func testLineEditingClampsAndPersists() throws {
        let (state, defaults) = try makeState()
        state.togglePower()
        state.openMenu()
        state.selection = 4
        state.enter()
        XCTAssertTrue(state.editing)
        state.down()
        state.down()
        XCTAssertEqual(state.lines, 250)
        state.enter()
        XCTAssertFalse(state.editing)
        XCTAssertEqual((defaults.object(forKey: "tvCRTLines") as? NSNumber)?.intValue, 250)
    }

    func testMaskPageAppliesSelection() throws {
        let (state, defaults) = try makeState()
        state.togglePower()
        state.openMenu()
        state.selection = 8
        state.enter()
        XCTAssertEqual(state.page, .mask)
        state.down()
        state.enter()
        XCTAssertEqual(state.maskType, 1)
        XCTAssertEqual(state.page, .main)
        XCTAssertEqual((defaults.object(forKey: "tvCRTMaskType") as? NSNumber)?.intValue, 1)
    }

    func testMenuBacksOutOfMaskAndEdit() throws {
        let (state, _) = try makeState()
        state.togglePower()
        state.openMenu()
        state.selection = 8
        state.enter()
        state.menu()
        XCTAssertEqual(state.page, .main)
        XCTAssertTrue(state.isOpen)
        state.selection = 6
        state.enter() // edit mask strength
        state.menu()
        XCTAssertFalse(state.editing)
        XCTAssertTrue(state.isOpen)
        state.menu()
        XCTAssertFalse(state.isOpen)
    }

    func testPaginationTracksSelection() throws {
        let (state, _) = try makeState()
        state.togglePower()
        state.openMenu()
        XCTAssertEqual(state.mainPage, 0)
        XCTAssertEqual(state.mainPageCount, 2)
        state.selection = 5
        state.down()
        XCTAssertEqual(state.selection, 6)
        XCTAssertEqual(state.mainPage, 1)
        XCTAssertEqual(state.visibleMainRows, 6..<9)
        state.selection = 0
        state.up()
        XCTAssertEqual(state.selection, 8)
        XCTAssertEqual(state.mainPage, 1)
        state.page = .mask
        state.maskSelection = 4
        state.down()
        XCTAssertEqual(state.maskSelection, 5)
        XCTAssertEqual(state.maskPage, 1)
        XCTAssertEqual(state.visibleMaskIndices, 5..<7)
        state.down()
        state.down()
        XCTAssertEqual(state.maskSelection, 0)
        XCTAssertEqual(state.maskPage, 0)
    }

    func testReloadPicksUpExternalSettings() throws {
        let (state, defaults) = try makeState()
        defaults.set(true, forKey: "tvCRTEnabled")
        defaults.set(367.0, forKey: "tvCRTLines")
        defaults.set(4, forKey: "tvCRTMaskType")
        state.openMenu()
        XCTAssertTrue(state.enabled)
        XCTAssertEqual(state.lines, 367)
        XCTAssertEqual(state.maskType, 4)
    }
}
