import XCTest
@testable import AnalogCore
@testable import AnalogGUI

@MainActor
final class TVSpectrumHistoryTests: XCTestCase {
    func testPauseSeekAndChangingFrequencyAxisDoNotInventHistory() throws {
        let history = TVSpectrumHistory()
        let first = TVSpectrum(sampleRate: 16_000_000, centerHz: 0,
            powerDB: .init(repeating: -20, count: 512))
        history.update(first,time: 4)
        let pixels = try XCTUnwrap(history.image?.dataProvider?.data)
        // Re-presenting a paused frame must replace, rather than scroll, the row.
        history.update(first,time: 4)
        XCTAssertEqual(pixels,history.image?.dataProvider?.data)
        history.update(first,time: 4.2)
        let advanced = try XCTUnwrap(history.image?.dataProvider?.data)
        let bytes = advanced as Data
        XCTAssertEqual(bytes[512*4+3],0,"An unmeasured time bucket stays black")
        XCTAssertEqual(bytes[512*4*2+3],255,"The measured older row scrolls down")
        history.update(first,time: 1)
        let sought = try XCTUnwrap(history.image?.dataProvider?.data) as Data
        XCTAssertEqual(sought[512*4+3],0,"Backward seeking clears history")
        let sound = TVSpectrum(sampleRate: 384_000,centerHz: 6_500_000,powerDB: first.powerDB)
        history.update(sound,time: 1.1)
        let retuned = try XCTUnwrap(history.image?.dataProvider?.data) as Data
        XCTAssertEqual(retuned[512*4+3],0,"Rows with different frequency axes cannot share a waterfall")
        history.reset()
        XCTAssertNil(history.image)
        XCTAssertNil(history.latestTime)
    }
}
