import Foundation

/// Unified complex-channel clock. One rate and one absolute sample index define
/// every frame boundary, so the vision 4fsc grid, the narrowband sound grid and
/// any future channel rate share an exact time mapping. Counts come from
/// adjacent absolute boundaries rather than a rounded per-frame increment.
public struct TVChannelClock: Sendable {
    public let system: TerrestrialSystem
    public let sampleRate: Double
    public init(system: TerrestrialSystem, sampleRate: Double) {
        self.system = system; self.sampleRate = sampleRate
    }
    public func offset(frame: Int64) -> Int64 {
        Int64((Double(frame) * system.video.frameDuration * sampleRate).rounded(.down))
    }
    public func count(frame: Int64) -> Int { Int(offset(frame: frame+1)-offset(frame: frame)) }
    public func time(sampleIndex: Int64) -> Double { Double(sampleIndex)/sampleRate }
    public func sampleIndex(time: Double) -> Int64 { Int64((time*sampleRate).rounded(.down)) }
    /// Samples of a whole channel frame, including the vision 4fsc convention.
    public var isVisionGrid: Bool { sampleRate == system.video.sampleRate }
}

/// One frame of combined complex IQ on a single channel grid. The vision carrier
/// is the 0 Hz reference; the sound carrier sits at +soundCarrierHz. `audio`
/// semantics stay explicit: a nil sound signal means the companion carrier is
/// off, while an all-zero PCM frame still carries a modulated (silent) carrier.
public struct TVChannelIQ: Sendable {
    public let system: TerrestrialSystem
    public let frameIndex: Int64
    public let firstSampleIndex: Int64
    public let sampleRate: Double
    public var i: [Float]
    public var q: [Float]
    public var count: Int { i.count }
    public init(system: TerrestrialSystem, frameIndex: Int64, firstSampleIndex: Int64,
                sampleRate: Double, i: [Float], q: [Float]) {
        self.system = system; self.frameIndex = frameIndex; self.firstSampleIndex = firstSampleIndex
        self.sampleRate = sampleRate; self.i = i; self.q = q
    }
    func validate() throws {
        let clock = TVChannelClock(system: system, sampleRate: sampleRate)
        guard frameIndex >= 0, frameIndex < 1_000_000_000,
              firstSampleIndex == clock.offset(frame: frameIndex),
              i.count == clock.count(frame: frameIndex), i.count == q.count,
              i.allSatisfy(\.isFinite), q.allSatisfy(\.isFinite) else { throw TVError.invalidSignal }
    }
    public var visionCarrierHz: Double { 0 }
    public var soundCarrierHz: Double { system.soundCarrierHz }
}
