import Foundation

/// Identity of one processed frame: its frame number and the exact input sample
/// interval it covers. Stages commit identities rather than bare counters, so a
/// repeated or rewound frame becomes a detected contract violation instead of
/// silent state skew.
public struct TVFrameIdentity: Equatable, Sendable {
    public let frameIndex: Int64
    public let sampleStart: Int64
    public let sampleCount: Int
    public init(frameIndex: Int64, sampleStart: Int64, sampleCount: Int) {
        self.frameIndex = frameIndex
        self.sampleStart = sampleStart
        self.sampleCount = sampleCount
    }
    public var sampleEnd: Int64 { sampleStart+Int64(sampleCount) }
}

/// How an identity relates to the one a stage committed before it.
public enum TVFrameContinuity: Equatable, Sendable {
    /// The first identity this stage ever committed.
    case first
    /// Exactly continues the previous frame on the same sample grid.
    case continuous
    /// Starts after the previous frame ended. A seek is legitimate, but the
    /// recursive state can no longer be claimed to correspond to the samples
    /// before the gap, so the discontinuity is recorded rather than hidden and
    /// the caller is responsible for resetting that stage.
    case forwardGap(skippedSamples: Int64, skippedFrames: Int64)
    /// Repeats or rewinds the same samples with state that has already advanced
    /// past them. Always a violation.
    case repeatOrRewind

    public var isViolation: Bool { self == .repeatOrRewind }
    public var isDiscontinuity: Bool {
        switch self {
        case .forwardGap: true
        default: false
        }
    }
}

/// One pipeline stage. Stages are named individually so a stalled, skipped or
/// skewed stage is visible on its own instead of being averaged into the frame.
public enum TVStage: String, CaseIterable, Codable, Sendable {
    case modulation, combination, channel, frontEnd, carrierEstimation, carrierPLL, detection, sound, decode
}

/// Committed progress of one stateful stage.
public struct TVStageProgress: Equatable, Sendable {
    public let stage: TVStage
    public private(set) var last: TVFrameIdentity?
    public private(set) var continuity: TVFrameContinuity = .first
    public private(set) var commits: Int64 = 0
    public private(set) var discontinuities: Int64 = 0
    /// Commits that re-ran samples the stage had already consumed.
    public private(set) var repeats: Int64 = 0
    public init(stage: TVStage) { self.stage = stage }

    /// Commit `next` and report how it relates to the previous commit. A repeat
    /// is recorded rather than refused: this engine is also used to re-run the
    /// same source frame on purpose, to let the carrier, AGC and sync loops
    /// settle before a paused preview. It still costs a full frame, so it is
    /// counted and exposed instead of being invisible.
    @discardableResult
    public mutating func advance(to next: TVFrameIdentity) -> TVFrameContinuity {
        guard let previous = last else {
            last = next; continuity = .first; commits += 1
            return .first
        }
        if next.sampleStart < previous.sampleEnd {
            continuity = .repeatOrRewind
            repeats += 1
            last = next; commits += 1
            return .repeatOrRewind
        }
        if next.sampleStart > previous.sampleEnd {
            continuity = .forwardGap(skippedSamples: next.sampleStart-previous.sampleEnd,
                                     skippedFrames: max(0,next.frameIndex-previous.frameIndex-1))
            discontinuities += 1
        } else {
            continuity = .continuous
        }
        last = next; commits += 1
        return continuity
    }
}

/// Per-stage committed progress for one engine. Value semantics give the
/// transaction for free: a frame that fails is abandoned together with its
/// candidate ledger, so progress can never advance further than the state that
/// produced it.
public struct TVProgressLedger: Equatable, Sendable {
    public private(set) var records: [TVStage: TVStageProgress] = [:]
    public init() {}
    public func progress(_ stage: TVStage) -> TVStageProgress {
        records[stage] ?? TVStageProgress(stage: stage)
    }
    public func last(_ stage: TVStage) -> TVFrameIdentity? { records[stage]?.last }
    public var totalCommits: Int64 { records.values.reduce(0) { $0+$1.commits } }
    public var totalDiscontinuities: Int64 { records.values.reduce(0) { $0+$1.discontinuities } }
    /// Repeated-frame commits. Each one is a whole extra frame of work.
    public var totalRepeats: Int64 { records.values.reduce(0) { $0+$1.repeats } }

    @discardableResult
    public mutating func advance(_ stage: TVStage, to identity: TVFrameIdentity) -> TVFrameContinuity {
        var record = progress(stage)
        let verdict = record.advance(to: identity)
        records[stage] = record
        return verdict
    }

    /// Stages whose last committed frame differs from `frameIndex`. Empty means
    /// every stage that has ever run is on the same frame.
    public func stagesBehind(frameIndex: Int64) -> [TVStage] {
        records.filter { $0.value.last?.frameIndex != frameIndex }.keys.sorted { $0.rawValue < $1.rawValue }
    }
}

/// Test-only fault injection for the commit contract. A frame that fails must
/// leave the engine exactly as it was, including every stage's recursive state;
/// the acceptance tests make a late stage fail to prove that.
public enum TVProcessFault: String, CaseIterable, Sendable {
    case afterModulation, afterChannel, afterFrontEnd, afterSound, beforeCommit
}

public enum TVProcessDiagnostics {
    /// Set by a test to force a stage failure. Not for production use.
    nonisolated(unsafe) public static var injectedFault: TVProcessFault?

    @inline(__always) static func check(_ fault: TVProcessFault) throws {
        if injectedFault == fault { throw TVError.injectedFault }
    }
}
