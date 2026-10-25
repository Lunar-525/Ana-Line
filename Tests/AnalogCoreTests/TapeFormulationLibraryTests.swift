import XCTest
@testable import AnalogCore

final class TapeFormulationLibraryTests: XCTestCase {
    func testBundledJSONLoads() throws {
        // Read the real source JSON directly (the packaged app loads it from
        // its Resources; load()'s Bundle lookup is covered by the override test).
        let jsonURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()      // AnalogCoreTests
            .deletingLastPathComponent()      // Tests
            .deletingLastPathComponent()      // project root
            .appendingPathComponent("Sources/AnalogCore/Resources/TapeFormulations.json")
        let lib = try TapeFormulationLibrary.parse(Data(contentsOf: jsonURL))
        XCTAssertGreaterThanOrEqual(lib.all.count, 30, "JSON should carry the full Audiochrome catalogue")
        XCTAssertEqual(lib.reference.id, "chf60", "JSON should mark CHF60 as the reference")
        // Representative models across brands.
        XCTAssertEqual(lib.named("tdkd60").name, "TDK D 60")
        XCTAssertEqual(lib.named("tdkb60").noiseDB, -47.4, accuracy: 0.0001)
        XCTAssertNotNil(lib.named("maxell-ur-94").thdPercent)
        XCTAssertNotNil(lib.named("sony-hfs-88").sol10kDB)
        // Nulls (unmeasured values) decode as nil, not a crash.
        XCTAssertNil(lib.named("maxell-ul-80").thdPercent, "UL 1980 THD was not measured")
        XCTAssertNil(lib.named("agfa-ln-72").sol10kDB, "Agfa LN SOL was not measured")
        // Unknown ids resolve to the reference, never crash.
        XCTAssertEqual(lib.named("nope").id, "chf60")
        // Every brand represented (ids vary: "sony-hf-85", "tdkd60", "chf60"...).
        for brand in ["sony","tdk","maxell","agfa","chf"] {
            XCTAssertTrue(lib.all.contains { $0.id.contains(brand) }, "Missing \(brand) formulations")
        }
    }

    func testExternalOverrideWins() throws {
        let json = """
        {"version":1,"referenceFormulation":"custom","formulations":[
          {"id":"custom","name":"Custom Tape","sensitivityDB":-1.0,"drive":2.0,"noiseDB":-50.0,
           "thdPercent":1.0,"mol400_3DB":3.0,"sol10kDB":-2.0,"sourceNote":"test"}]}
        """
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString+".json")
        try Data(json.utf8).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        let lib = TapeFormulationLibrary.load(override: url)
        XCTAssertEqual(lib.all.count, 1)
        XCTAssertEqual(lib.reference.id, "custom")
        XCTAssertEqual(lib.reference.drive, 2.0, accuracy: 0.0001)
    }

    func testCorruptOverrideFallsBackToBundled() throws {
        // load(override:) with a corrupt file must not trap: it falls through the
        // bundled candidates to the built-in reference (1 formulation here, since
        // the packaged Resources lookup is absent under the test runner).
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString+".json")
        try Data("{ not json".utf8).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        let lib = TapeFormulationLibrary.load(override: url)
        XCTAssertFalse(lib.all.isEmpty, "Corrupt override should still yield a usable library")
        XCTAssertEqual(lib.reference.id, "chf60", "Corrupt override should fall back to the reference")
        // And a valid file must fully replace it.
        let good = """
        {"referenceFormulation":"a","formulations":[
          {"id":"a","name":"A","sensitivityDB":0,"drive":2.5,"noiseDB":-48,"thdPercent":1,"mol400_3DB":3,"sol10kDB":-2,"sourceNote":"x"},
          {"id":"b","name":"B","sensitivityDB":0,"drive":2.5,"noiseDB":-48,"thdPercent":1,"mol400_3DB":3,"sol10kDB":-2,"sourceNote":"x"}]}
        """
        let goodURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString+".json")
        try Data(good.utf8).write(to: goodURL)
        defer { try? FileManager.default.removeItem(at: goodURL) }
        let goodLib = TapeFormulationLibrary.load(override: goodURL)
        XCTAssertEqual(goodLib.all.count, 2)
    }

    func testEmptyAndDuplicateRejectedButParseThrows() {
        XCTAssertThrowsError(try TapeFormulationLibrary.parse(Data("""
        {"formulations":[]}
        """.utf8)))
        XCTAssertThrowsError(try TapeFormulationLibrary.parse(Data("""
        {"formulations":[
          {"id":"a","name":"A","sensitivityDB":0,"drive":2.5,"noiseDB":-48,"thdPercent":1,"mol400_3DB":3,"sol10kDB":-2,"sourceNote":"x"},
          {"id":"a","name":"A2","sensitivityDB":0,"drive":2.5,"noiseDB":-48,"thdPercent":1,"mol400_3DB":3,"sol10kDB":-2,"sourceNote":"x"}]}
        """.utf8)))
    }

    func testReferenceDefaultsToFirstWhenReferenceNameUnknown() throws {
        let lib = try TapeFormulationLibrary.parse(Data("""
        {"referenceFormulation":"missing","formulations":[
          {"id":"first","name":"First","sensitivityDB":0,"drive":2.5,"noiseDB":-48,"thdPercent":1,"mol400_3DB":3,"sol10kDB":-2,"sourceNote":"x"}]}
        """.utf8))
        XCTAssertEqual(lib.reference.id, "first")
    }

    func testDefaultSettingsUseReferenceFormulation() {
        let s = TapeSettings()
        XCTAssertEqual(s.formulation, TapeFormulations.reference)
    }
}
