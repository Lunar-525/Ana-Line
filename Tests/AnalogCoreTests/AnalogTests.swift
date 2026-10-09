import XCTest
@testable import AnalogCore

final class AnalogTests: XCTestCase {
    func testIdentity() {
        let image = Raster(width: 1,height: 1,pixels: [SIMD4<Float>(0.2,0.4,0.6,0.3)])
        var r = Recipe()
        r.film = 0; r.grain = 0; r.halation = 0; r.vignette = 0
        r.lightLeak = 0; r.dust = 0; r.scratches = 0
        XCTAssertEqual(AnalogEngine.render(image,recipe: r).pixels,image.pixels)
    }
    func testDeterminismAlphaAndBounds() {
        let image = Raster(width: 32,height: 24,pixels: Array(repeating: SIMD4<Float>(0.9,0.4,0.2,0.3),count: 768))
        let a = AnalogEngine.render(image,recipe: Recipe())
        XCTAssertEqual(a.pixels,AnalogEngine.render(image,recipe: Recipe()).pixels)
        for p in a.pixels {
            XCTAssertEqual(p.w,0.3)
            for c in 0..<3 { XCTAssertTrue(p[c].isFinite && p[c] >= 0 && p[c] <= 1) }
        }
        var other = Recipe(); other.seed = 123
        XCTAssertNotEqual(a.pixels,AnalogEngine.render(image,recipe: other).pixels)
    }
}
