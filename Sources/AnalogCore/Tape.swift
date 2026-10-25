import Foundation
import CTapeDSP

/// A tape formulation profile. `sensitivityDB` is the relative 400 Hz
/// sensitivity, `noiseDB` the unweighted bias-noise level, and `drive` an
/// effective hysteresis drive calibrated so each formulation lands near its
/// measured nominal-reference THD and MOL. These capture the audible
/// differences between formulations (level, saturation, hiss); they are not a
/// full fit of each tape's measured MOL/SOL or frequency-response curves.
public struct TapeFormulation: Sendable, Equatable, Identifiable, Hashable, Decodable {
    public let id: String
    public let name: String
    /// Relative 400 Hz sensitivity in dB (reference CHF is -0.8).
    public let sensitivityDB: Double
    /// Hysteresis drive; smaller reaches a higher MOL (reference CHF is 2.5).
    public let drive: Double
    /// Unweighted bias-noise level in dB (reference CHF is -47.6).
    public let noiseDB: Double
    /// Measured nominal-reference THD (%), kept for display / verification.
    /// nil when Audiochrome did not measure it.
    public let thdPercent: Double?
    /// Measured MOL at 400 Hz (THD 3%) in dB relative to nominal reference.
    public let mol400_3DB: Double
    /// Measured SOL at 10 kHz in dB relative to nominal reference.
    /// nil when Audiochrome did not measure it.
    public let sol10kDB: Double?
    /// Human-readable provenance of the measured figures.
    public let sourceNote: String
    public init(id: String, name: String, sensitivityDB: Double, drive: Double, noiseDB: Double,
                thdPercent: Double?, mol400_3DB: Double, sol10kDB: Double?, sourceNote: String) {
        self.id=id; self.name=name; self.sensitivityDB=sensitivityDB; self.drive=drive
        self.noiseDB=noiseDB; self.thdPercent=thdPercent; self.mol400_3DB=mol400_3DB
        self.sol10kDB=sol10kDB; self.sourceNote=sourceNote
    }
}

public enum TapeFormulations {
    /// Loads the formulation library once, preferring an external JSON override
    /// when present and falling back to the bundled copy, then to a minimal
    /// built-in reference so the app still works with no resources at all.
    public static let shared: TapeFormulationLibrary = .load()
    public static var all: [TapeFormulation] { shared.all }
    public static func named(_ id: String) -> TapeFormulation { shared.named(id) }
    public static var reference: TapeFormulation { shared.reference }
}

/// CHF-inspired effective model, not measured magnetic material constants.
public struct TapeSettings: Sendable, Equatable {
    public var recordDB: Double = 0
    /// Nil links the right recording level to the left.
    public var recordRightDB: Double? = nil
    public var outputDB: Double = 0
    /// Effective head condition, from 0 (worn) to 1 (healthy).
    public var headHealth: Double = 1
    /// Effective tape condition, from 0 (degraded) to 1 (healthy).
    public var tapeHealth: Double = 1
    public var hiss = true
    public var bypass = false
    /// Tape formulation; default is the reference CHF profile.
    public var formulation: TapeFormulation = TapeFormulations.reference
    public init() {}
}

/// Own one instance on one DSP thread. State survives arbitrary block boundaries.
/// Internal 4x FIR oversampling has about 15.5 base-rate samples of group delay.
public final class TapeProcessor {
    private let handle: OpaquePointer
    public init(sampleRate: Double = 48_000) throws {
        guard let handle = al_tape_create(sampleRate) else { throw TapeError.invalidSampleRate }
        self.handle = handle
    }
    deinit { al_tape_destroy(handle) }
    public func reset() { al_tape_reset(handle) }
    public func configure(_ settings: TapeSettings) {
        al_tape_set(handle, settings.recordDB, settings.outputDB, settings.hiss ? 1 : 0, settings.bypass ? 1 : 0)
        al_tape_set_right_record_db(handle,settings.recordRightDB ?? settings.recordDB)
        al_tape_set_health(handle, settings.headHealth, settings.tapeHealth)
        let f = settings.formulation
        al_tape_set_profile(handle, f.sensitivityDB, f.drive, f.noiseDB)
    }
    public func process(left: UnsafePointer<Float>, right: UnsafePointer<Float>,
                        outputLeft: UnsafeMutablePointer<Float>, outputRight: UnsafeMutablePointer<Float>, count: Int) {
        guard count > 0, count <= Int(Int32.max) else { return }
        al_tape_process(handle,left,right,outputLeft,outputRight,Int32(count))
    }
}
public enum TapeError: Error { case invalidSampleRate }

/// Loads tape formulations from JSON. Resolution order:
///   1. An external override JSON at a well-known path, when present.
///   2. The bundled `TapeFormulations.json` resource.
///   3. A minimal built-in reference formulation, so the app never fails to start.
/// Editing the JSON adds or retunes formulations without recompiling.
public struct TapeFormulationLibrary: Sendable {
    public let all: [TapeFormulation]
    public let reference: TapeFormulation
    private let byID: [String: TapeFormulation]

    public func named(_ id: String) -> TapeFormulation { byID[id] ?? reference }

    /// Optional external override; drop a `TapeFormulations.json` next to the
    /// app (or at this path) to retune without rebuilding.
    public static var overrideURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/AnaLine/TapeFormulations.json")
    }

    public static func load(override url: URL? = nil) -> TapeFormulationLibrary {
        let decoder = JSONDecoder()
        func library(at url: URL) -> TapeFormulationLibrary? {
            guard let data = try? Data(contentsOf: url) else { return nil }
            return try? decoder.decode(TapeFormulationFile.self, from: data).library()
        }
        // 1. External override, if the file exists and parses.
        if let url = url ?? optionalFile(overrideURL), let lib = library(at: url) { return lib }
        // 2. Search a few well-known locations for a bundled copy. Deliberately
        //    avoids Bundle.module, whose accessor can trap when a packaged app
        //    lays resources out differently than SwiftPM does.
        for candidate in bundledCandidates() {
            if let lib = library(at: candidate) { return lib }
        }
        // 3. Built-in fallback: the reference CHF formulation. Never traps.
        let reference = TapeFormulation(id:"chf60",name:"Sony CHF 60",
            sensitivityDB:-0.8,drive:2.5,noiseDB:-47.6,
            thdPercent:1.5,mol400_3DB:2.1,sol10kDB:-1.4,
            sourceNote:"Audiochrome, Sony CHF (1978)")
        return TapeFormulationLibrary(formulations:[reference],referenceID:"chf60")
    }

    /// Candidate paths for a copy of `TapeFormulations.json`, without touching
    /// `Bundle.module` (whose accessor can trap outside SwiftPM's layout).
    /// Covers: the packaged app's Resources, and any SwiftPM resource bundle
    /// (whose name varies: `<module>_<package>.bundle`) next to the executable.
    private static func bundledCandidates() -> [URL] {
        var urls: [URL] = []
        let file = "TapeFormulations.json"
        func addBundles(under dir: URL, depth: Int) {
            guard depth > 0 else { return }
            guard let entries = try? FileManager.default.contentsOfDirectory(
                at: dir, includingPropertiesForKeys: nil) else { return }
            for e in entries where e.pathExtension == "bundle" {
                urls.append(e.appendingPathComponent("Contents/Resources/\(file)"))
                urls.append(e.appendingPathComponent(file))
                // Search one level further inside a bundle (SwiftPM nests the
                // module bundle under Contents/Resources).
                addBundles(under: e.appendingPathComponent("Contents/Resources"), depth: depth - 1)
                addBundles(under: e, depth: depth - 1)
            }
        }
        // 1. The packaged app copies the JSON straight into Resources.
        if let main = Bundle.main.resourceURL {
            urls.append(main.appendingPathComponent(file))
            // Test runners (xctest) nest the module bundle under Resources.
            addBundles(under: main, depth: 2)
        }
        // 2. Any bundle next to the executable (SwiftPM's <Module>_<Package>.bundle).
        if let exe = Bundle.main.executableURL {
            addBundles(under: exe.deletingLastPathComponent(), depth: 2)
        }
        // 3. Compile-time source path: reliable under `swift test` (Bundle.main is
        //    the xctest runner, not this module's bundle). Harmless in a packaged
        //    app, where step 1 already succeeds and this path simply won't exist.
        #if DEBUG
        let src = URL(fileURLWithPath: #filePath)   // .../Sources/AnalogCore/Tape.swift
            .deletingLastPathComponent()            // .../Sources/AnalogCore
            .appendingPathComponent("Resources/\(file)")
        urls.append(src)
        #endif
        return urls
    }

    public static func parse(_ data: Data, referenceID: String? = nil) throws -> TapeFormulationLibrary {
        try JSONDecoder().decode(TapeFormulationFile.self, from: data).library(referenceID: referenceID)
    }

    init(formulations: [TapeFormulation], referenceID: String) {
        self.all = formulations
        self.byID = Dictionary(uniqueKeysWithValues: formulations.map { ($0.id,$0) })
        self.reference = byID[referenceID] ?? formulations.first
            ?? TapeFormulation(id:"chf60",name:"Sony CHF 60",
                sensitivityDB:-0.8,drive:2.5,noiseDB:-47.6,
                thdPercent:1.5,mol400_3DB:2.1,sol10kDB:-1.4,
                sourceNote:"Audiochrome, Sony CHF (1978)")
    }

    private static func optionalFile(_ url: URL) -> URL? {
        FileManager.default.fileExists(atPath: url.path) ? url : nil
    }
}

/// On-disk JSON shape. `formulations` must be non-empty; `referenceFormulation`
/// names the default entry (defaults to the first when absent or unknown).
struct TapeFormulationFile: Decodable {
    let referenceFormulation: String?
    let formulations: [TapeFormulation]

    func library(referenceID: String? = nil) throws -> TapeFormulationLibrary {
        guard !formulations.isEmpty else {
            throw DecodingError.dataCorrupted(.init(codingPath: [], debugDescription: "TapeFormulations.json contains no formulations"))
        }
        let ref = referenceID ?? referenceFormulation ?? formulations[0].id
        let ids = formulations.map(\.id)
        guard Set(ids).count == ids.count else {
            throw DecodingError.dataCorrupted(.init(codingPath: [], debugDescription: "TapeFormulations.json has duplicate ids"))
        }
        return TapeFormulationLibrary(formulations: formulations, referenceID: ref)
    }
}
