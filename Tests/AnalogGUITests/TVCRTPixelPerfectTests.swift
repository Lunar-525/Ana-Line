import XCTest
@testable import AnalogGUI

final class TVCRTPixelPerfectTests: XCTestCase {
    func test120LinesLetterboxesAtOnePixelStripes() throws {
        let p = try XCTUnwrap(TVCRTPixelPerfect.make(
            drawableSize: CGSize(width: 640, height: 480), requestedRows: 120,
            maximumRows: 576, aspect: 4.0/3.0, maskType: 0, enabled: true))
        XCTAssertEqual(p.rows, 120)
        XCTAssertEqual(p.triads, 160)
        XCTAssertEqual(p.stripeScale, 1)
        XCTAssertEqual(p.rect.width, 0.75, accuracy: 0.001)
        XCTAssertEqual(p.rect.height, 0.75, accuracy: 0.001)
        XCTAssertNil(p.cappedFrom)
    }

    func test160LinesFillsTheRasterAtOnePixelStripes() throws {
        let p = try XCTUnwrap(TVCRTPixelPerfect.make(
            drawableSize: CGSize(width: 640, height: 480), requestedRows: 160,
            maximumRows: 576, aspect: 4.0/3.0, maskType: 0, enabled: true))
        XCTAssertEqual(p.rows, 160)
        XCTAssertEqual(p.triads, 213)
        XCTAssertEqual(p.stripeScale, 1)
        XCTAssertEqual(p.rect.height, 1, accuracy: 0.001)
        XCTAssertEqual(p.rect.width, 639.0/640.0, accuracy: 0.001)
        XCTAssertEqual(p.rect.minX * 640, 0, accuracy: 0.001)
    }

    func testTooManyLinesIsCappedInsteadOfFractionalStripes() throws {
        let p = try XCTUnwrap(TVCRTPixelPerfect.make(
            drawableSize: CGSize(width: 640, height: 480), requestedRows: 240,
            maximumRows: 576, aspect: 4.0/3.0, maskType: 0, enabled: true))
        XCTAssertEqual(p.rows, 160)
        XCTAssertEqual(p.cappedFrom, 240)
        XCTAssertEqual(p.stripeScale, 1)
    }

    func testLargeDrawableUsesIntegerMultiples() throws {
        let geometry = CGSize(width: 1920, height: 1440)
        let one = try XCTUnwrap(TVCRTPixelPerfect.make(drawableSize: geometry,
            requestedRows: 120, maximumRows: 576, aspect: 4.0/3.0, maskType: 0, enabled: true))
        XCTAssertEqual(one.stripeScale, 4)
        XCTAssertEqual(one.rect.width, 1, accuracy: 0.001)
        XCTAssertEqual(one.rect.height, 1, accuracy: 0.001)
        let two = try XCTUnwrap(TVCRTPixelPerfect.make(drawableSize: geometry,
            requestedRows: 240, maximumRows: 576, aspect: 4.0/3.0, maskType: 0, enabled: true))
        XCTAssertEqual(two.stripeScale, 2)
        XCTAssertEqual(two.rect.width, 1, accuracy: 0.001)
    }

    func testOriginStaysOnWholePixels() throws {
        let p = try XCTUnwrap(TVCRTPixelPerfect.make(
            drawableSize: CGSize(width: 1280, height: 960), requestedRows: 480,
            maximumRows: 576, aspect: 4.0/3.0, maskType: 0, enabled: true))
        XCTAssertEqual(p.rows, 320)
        XCTAssertEqual(p.cappedFrom, 480)
        XCTAssertEqual(p.rect.minX * 1280, 1, accuracy: 0.001)
        XCTAssertEqual(p.rect.width * 1280, 1278, accuracy: 0.001)
    }

    func testBestFullFrameMatches367OnHighDensityPreview() throws {
        let fit = try XCTUnwrap(TVCRTPixelPerfect.bestFit(
            drawableSize: CGSize(width: 2936, height: 2202), maximumRows: 576,
            aspect: 4.0/3.0))
        XCTAssertEqual(fit.rows, 367)
        XCTAssertEqual(fit.stripeScale, 2)
        let ntsc = try XCTUnwrap(TVCRTPixelPerfect.bestFit(
            drawableSize: CGSize(width: 2936, height: 2202), maximumRows: 480,
            aspect: 4.0/3.0))
        XCTAssertEqual(ntsc.rows, 367)
        XCTAssertEqual(ntsc.stripeScale, 2)
    }

    func testBestFullFrameAcrossCommonDrawables() throws {
        let cases: [(Double, Double, Int, Int, Int)] = [
            (1468, 1101, 576, 367, 1),
            (1280, 960, 576, 320, 1),
            (1920, 1440, 576, 480, 1),
            (2880, 2160, 576, 360, 2),
            (4512, 3384, 576, 564, 2),
            (4512, 3384, 480, 376, 3),
            (2133, 1600, 576, 533, 1),
            (2133, 1600, 480, 266, 2),
        ]
        for (width, height, standard, rows, scale) in cases {
            let fit = try XCTUnwrap(TVCRTPixelPerfect.bestFit(
                drawableSize: CGSize(width: width, height: height), maximumRows: standard,
                aspect: 4.0/3.0))
            XCTAssertEqual(fit.rows, rows, "best rows for \(Int(width))x\(Int(height)) @ \(standard)")
            XCTAssertEqual(fit.stripeScale, scale)
        }
    }

    func testTriangularAndDisabledModesKeepFreeScaling() {
        XCTAssertNil(TVCRTPixelPerfect.make(drawableSize: CGSize(width: 1920, height: 1440),
            requestedRows: 240, maximumRows: 576, aspect: 4.0/3.0, maskType: 1, enabled: true))
        XCTAssertNil(TVCRTPixelPerfect.make(drawableSize: CGSize(width: 1920, height: 1440),
            requestedRows: 240, maximumRows: 576, aspect: 4.0/3.0, maskType: 0, enabled: false))
        XCTAssertNil(TVCRTPixelPerfect.make(drawableSize: CGSize(width: 320, height: 240),
            requestedRows: 120, maximumRows: 576, aspect: 4.0/3.0, maskType: 0, enabled: true))
    }

    func testLineCapScalesWithDrawableHeight() {
        XCTAssertEqual(TVCRTPixelPerfect.lineCap(drawableSize: CGSize(width: 640, height: 480), aspect: 4.0/3.0), 160)
        XCTAssertEqual(TVCRTPixelPerfect.lineCap(drawableSize: CGSize(width: 1280, height: 960), aspect: 4.0/3.0), 320)
        XCTAssertEqual(TVCRTPixelPerfect.lineCap(drawableSize: CGSize(width: 1920, height: 1440), aspect: 4.0/3.0), 480)
    }
}
