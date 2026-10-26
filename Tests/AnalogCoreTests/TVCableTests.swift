import XCTest
import AnalogImaging

final class TVCableTests: XCTestCase {
    private let width = 4, height = 4
    private var testRGB: [SIMD3<Float>] {
        [SIMD3<Float>](repeating: SIMD3(0.8, 0.3, 0.2), count: width*height)
    }
    private func apply(_ settings: TVCableSettings) -> [SIMD3<Float>] {
        TVCableProcessor.apply(testRGB, width: width, height: height,
            settings: settings, frameIndex: 1)
    }
    private func mean(_ values: [SIMD3<Float>]) -> Float {
        values.reduce(0) { $0 + ($1.x + $1.y + $1.z) / 3 } / Float(max(1, values.count))
    }

    func testOffIsIdentity() {
        XCTAssertEqual(apply(.off), testRGB)
    }

    func testUnpluggedCompositeIsBlack() {
        var settings = TVCableSettings(kind: .av)
        settings.lines[0].connected = false
        XCTAssertEqual(mean(apply(settings)), 0, accuracy: 1e-6)
    }

    func testComponentYOpenIsBlack() {
        var settings = TVCableSettings(kind: .component)
        settings.lines[0].connected = false
        XCTAssertEqual(mean(apply(settings)), 0, accuracy: 1e-6)
    }

    func testComponentMissingPbOrPrLeavesColorCastThenMonochrome() {
        var pbOpen = TVCableSettings(kind: .component)
        pbOpen.lines[1].connected = false
        let color = apply(pbOpen)
        XCTAssertGreaterThan(abs(color[0].x - color[0].y), 0.02, "Pb open should not be neutral")

        var bothOpen = pbOpen
        bothOpen.lines[2].connected = false
        let mono = apply(bothOpen)[0]
        XCTAssertEqual(mono.x, mono.y, accuracy: 1e-4)
        XCTAssertEqual(mono.y, mono.z, accuracy: 1e-4)
    }

    func testSVideoMissingChromaIsMonochrome() {
        var settings = TVCableSettings(kind: .sVideo)
        settings.lines[1].connected = false
        let pixel = apply(settings)[0]
        XCTAssertEqual(pixel.x, pixel.y, accuracy: 1e-4)
        XCTAssertEqual(pixel.y, pixel.z, accuracy: 1e-4)
    }

    func testBadHealthAndImpedanceReduceLevel() {
        let good = apply(TVCableSettings(kind: .bnc))
        var bad = TVCableSettings(kind: .bnc)
        bad.cableHealth = 0.2
        bad.cableImpedance = 50
        bad.lines[0].connectorHealth = 0.2
        bad.lines[0].connectorImpedance = 50
        bad.lines[0].tightness = 0.2
        XCTAssertLessThan(mean(apply(bad)), mean(good) * 0.6)
    }

    func testMainsInterferenceChangesImage() {
        let clean = apply(TVCableSettings(kind: .bnc))
        var noisy = TVCableSettings(kind: .bnc)
        noisy.interferences = [.init(kind: .mains, intensity: 1, distance: 0)]
        XCTAssertNotEqual(apply(noisy), clean)
    }

    func testCompressorTransformerAndGroundPotentialInterfere() {
        let clean = apply(TVCableSettings(kind: .bnc))
        for kind in [TVCableSettings.Interference.Kind.compressor,
                     .transformer, .groundPotential] {
            var settings = TVCableSettings(kind: .bnc)
            settings.interferences = [.init(kind: kind, intensity: 1, distance: 0)]
            XCTAssertNotEqual(apply(settings), clean, "\(kind) must change the signal")
        }
    }

    func testLineNormalizationAndPersistence() throws {
        var settings = TVCableSettings(kind: .component)
        settings.lines[0].connectorHealth = 0.4
        let suite = "TVCableTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defaults.removePersistentDomain(forName: suite)
        settings.save(to: defaults)
        let loaded = TVCableSettings.load(from: defaults)
        XCTAssertEqual(loaded.kind, .component)
        XCTAssertEqual(loaded.lines.count, 3)
        XCTAssertEqual(loaded.lines[0].connectorHealth, 0.4, accuracy: 1e-6)

        var open = TVCableSettings(kind: .off, lines: settings.lines)
        open.normalize()
        XCTAssertTrue(open.lines.isEmpty)
    }
}
