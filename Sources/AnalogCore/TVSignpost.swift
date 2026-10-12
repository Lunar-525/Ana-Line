import Foundation
#if canImport(os)
import os
#endif

/// Stage-boundary signposts for Instruments. A run only pays for them when the
/// launch argument `--benchmark-signpost` (or `TV_SIGNPOST=1`) is present, so
/// production playback keeps the plain path. The intervals are what let the
/// trace separate computation from the waiting between stages and from the
/// commit boundaries, which is the critical-path information P2 needs.
enum TVSignpost {
    static let enabled = ProcessInfo.processInfo.arguments.contains("--benchmark-signpost")
        || ProcessInfo.processInfo.environment["TV_SIGNPOST"] == "1"

    #if canImport(os)
    private static let signposter = OSSignposter(subsystem: "com.analine.core", category: "stages")
    private static func name(_ stage: TVStage) -> StaticString {
        switch stage {
        case .modulation: "modulation"
        case .combination: "combination"
        case .channel: "channel"
        case .frontEnd: "frontEnd"
        case .carrierEstimation: "carrierEstimation"
        case .carrierPLL: "carrierPLL"
        case .detection: "detection"
        case .sound: "sound"
        case .decode: "decode"
        }
    }
    @discardableResult
    static func begin(_ stage: TVStage) -> OSSignpostIntervalState? {
        guard enabled else { return nil }
        return signposter.beginInterval(name(stage), id: signposter.makeSignpostID())
    }
    static func end(_ stage: TVStage, _ state: OSSignpostIntervalState?) {
        guard let state else { return }
        signposter.endInterval(name(stage), state)
    }
    #else
    @discardableResult
    static func begin(_ stage: TVStage) -> Int? { nil }
    static func end(_ stage: TVStage, _ state: Int?) {}
    #endif
}
