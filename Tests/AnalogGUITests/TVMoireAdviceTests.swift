import XCTest
@testable import AnalogGUI

@MainActor
final class TVMoireAdviceTests: XCTestCase {
    private func advice(_ width: Double, _ height: Double, lines: Double = 240,
                        scans: Double = 0, type: Int = 0, curvature: Double = 0.018) -> TVMoireAdvice {
        TVMoireAdvice(drawableSize: CGSize(width: width, height: height), maximum: 576,
            requestedLines: lines, requestedScanlines: scans, maskType: type, curvature: curvature)
    }
    func testPhysicalPixelsChangeRisk() {
        XCTAssertGreaterThan(advice(1280, 960).estimate.score, advice(2560, 1920).estimate.score)
        XCTAssertEqual(advice(2560, 1920).estimate.risk, .low)
    }
    func testFullyUnresolvedMaskUsesShaderFallback() {
        XCTAssertEqual(advice(640, 480, lines: 480).estimate.mask, 0)
    }
    func testManualScanlinesRemainIndependent() {
        let automatic = advice(1280, 960, lines: 120)
        let manual = advice(1280, 960, lines: 120, scans: 480)
        XCTAssertEqual(manual.scanlines, 480)
        XCTAssertGreaterThan(manual.estimate.scan, automatic.estimate.scan)
    }
    func testMaskGeometryMatters() {
        XCTAssertNotEqual(advice(1280, 960).estimate.mask, advice(1280, 960, type: 1).estimate.mask)
    }
    func testCurvatureOnlyAddsLocalStretchSamples() {
        let flat = advice(1280, 960, curvature: 0)
        let curved = advice(1280, 960, curvature: 0.018)
        XCTAssertGreaterThanOrEqual(curved.estimate.score, flat.estimate.score)
        XCTAssertEqual(flat.estimate.score.isFinite, true)
    }

    func testTriangularLatticeAllowsHigherLineCounts() {
        for (width, height) in [(1920.0, 1440.0), (2560.0, 1920.0)] {
            for lines in [480.0, 576.0] {
                let shadow = advice(width, height, lines: lines, type: 1).estimate.mask
                let hex = advice(width, height, lines: lines, type: 4).estimate.mask
                XCTAssertLessThan(shadow, 0.2,
                    "triangular lattice should stay low-risk at \(Int(lines)) lines")
                XCTAssertEqual(shadow, hex, accuracy: 1e-9)
            }
        }
    }
    func testSuggestionsActuallyReduceRisk() {
        let current = advice(1280, 960)
        XCTAssertFalse(current.suggestions.isEmpty)
        for lines in current.suggestions {
            XCTAssertLessThan(advice(1280, 960, lines: Double(lines)).estimate.score + 0.12, current.estimate.score)
        }
    }
    func testPALAndNTSCUseDisplaySamplingInsteadOfSourceDivisibility() {
        for (width, height) in [(768.0, 576.0), (640.0, 480.0)] {
            for type in TVCRTMaskType.allCases {
                let result = TVMoireAdvice(drawableSize: CGSize(width: width * 4, height: height * 4),
                    maximum: height, requestedLines: 240, maskType: type.rawValue)
                XCTAssertEqual(result.estimate.risk, .low)
                XCTAssertEqual(result.lines, 240)
            }
        }
    }

    func testRasterClampingAndInvalidGeometry() {
        let small = advice(320, 240, lines: 576, scans: 576)
        XCTAssertEqual(small.lines, 240)
        XCTAssertEqual(small.scanlines, 240)
        XCTAssertTrue(advice(.nan, .infinity).estimate.score.isFinite)
    }
}
