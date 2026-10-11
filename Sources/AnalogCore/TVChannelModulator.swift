import Foundation
import Accelerate
import Dispatch

/// Carrier shift plus add, split across output ranges. Each worker restarts its
/// oscillator from the exact phase at its first sample, so the parallel result
/// matches the serial recurrence to rounding and never accumulates phase error.
private struct TVSoundChannelNCO: @unchecked Sendable {
    let ri: UnsafeBufferPointer<Float>, rq: UnsafeBufferPointer<Float>
    let vi: UnsafeMutableBufferPointer<Float>, vq: UnsafeMutableBufferPointer<Float>
    let startPhase: Double, step: Double
    func run(_ range: Range<Int>) {
        var c = cos(startPhase+step*Double(range.lowerBound))
        var s = sin(startPhase+step*Double(range.lowerBound))
        let dc = cos(step), ds = sin(step)
        let a = ri.baseAddress!, b = rq.baseAddress!
        let x = vi.baseAddress!, y = vq.baseAddress!
        for n in range {
            let ra = Double(a[n]), rb = Double(b[n])
            x[n] += Float(ra*c-rb*s)
            y[n] += Float(ra*s+rb*c)
            let next = c*dc-s*ds; s = c*ds+s*dc; c = next
            if n & 1023 == 0 { let norm = hypot(c,s); c /= norm; s /= norm }
        }
    }
}

/// Linear channel combiner. Vision stays on its own 4fsc grid at the 0 Hz
/// reference; the narrowband sound envelope is band-limited up to that grid and
/// shifted to +soundCarrierHz, so both real carriers live in one IQ record.
/// Common-PA nonlinearity is intentionally not applied here yet; the first
/// combined version is linear for reference comparison.
public struct TVChannelModulator: Sendable {
    public let system: TerrestrialSystem
    public let sampleRate: Double
    private let soundRadius: Int
    private var soundResampler: TVComplexResampler?
    private var soundInputRate: Double = 0
    private var soundProfile: TVChainProfile?
    private var ncoPhase = 0.0

    public init(system: TerrestrialSystem, sampleRate: Double? = nil, soundRadius: Int = 6) {
        self.system = system
        self.sampleRate = sampleRate ?? system.video.sampleRate
        self.soundRadius = soundRadius
    }

    /// The full profile keeps the value this instance was built with; a reduced
    /// profile supplies its own kernel. Either way the companion band-limit
    /// filter and the carrier placement are untouched.
    private func upsampleRadius(_ profile: TVChainProfile) -> Int {
        profile == .full ? soundRadius : profile.soundUpsampleRadius
    }

    /// Combine arbitrary-grid vision and sound blocks. `visionFirstSample` is the
    /// absolute channel sample index of `visionI[0]`; the output keeps that index.
    /// `profile` selects the companion upsampling kernel; the sound band-limit
    /// filter and the carrier placement are unchanged by it.
    public mutating func combine(visionI: [Float], visionQ: [Float], frameIndex: Int64,
                                 visionFirstSample: Int64, sound: TVSoundIQ?,
                                 profile: TVChainProfile = .full) -> TVChannelIQ {
        var i = visionI, q = visionQ
        if let sound, !sound.i.isEmpty {
            if soundResampler == nil || soundInputRate != sound.sampleRate || soundProfile != profile {
                soundResampler = TVComplexResampler(inputRate: sound.sampleRate, outputRate: sampleRate,
                                                    radius: upsampleRadius(profile),
                                                    phases: profile.soundUpsamplePhases,
                                                    singlePrecisionAccumulation: profile.soundResamplerSinglePrecision)
                soundInputRate = sound.sampleRate
                soundProfile = profile
                ncoPhase = 0
            }
            let soundStart = TVSoundClock.offset(frame: frameIndex,standard: system.video,rate: Int(sound.sampleRate))
            let resampled = soundResampler!.process(i: sound.i,q: sound.q,inputStart: soundStart,
                                                    outputStart: visionFirstSample,outputCount: i.count)
            let shiftStep = 2*Double.pi*system.soundCarrierHz/sampleRate
            let count = i.count
            i.withUnsafeMutableBufferPointer { ip in
                q.withUnsafeMutableBufferPointer { qp in
                    resampled.0.withUnsafeBufferPointer { ri in
                        resampled.1.withUnsafeBufferPointer { rq in
                            let work = TVSoundChannelNCO(ri: ri,rq: rq,vi: ip,vq: qp,
                                startPhase: ncoPhase,step: shiftStep)
                            let workers = cappedWorkers(min(12,max(1,count/65_536)))
                            if workers > 1 {
                                DispatchQueue.concurrentPerform(iterations: workers) { worker in
                                    work.run(worker*count/workers ..< (worker+1)*count/workers)
                                }
                            } else { work.run(0..<count) }
                        }
                    }
                }
            }
            ncoPhase = (ncoPhase+shiftStep*Double(count)).truncatingRemainder(dividingBy: 2*Double.pi)
        }
        return TVChannelIQ(system: system,frameIndex: frameIndex,firstSampleIndex: visionFirstSample,
                           sampleRate: sampleRate,i: i,q: q)
    }

    /// High-level entry point. A nil sound signal leaves the companion carrier off.
    public mutating func combine(vision: TelevisionRF, sound: TVSoundIQ?,
                                 profile: TVChainProfile = .full) throws -> TVChannelIQ {
        try vision.validate()
        guard vision.system == system, vision.sampleRate == sampleRate else { throw TVError.invalidSignal }
        if let sound {
            guard sound.system == system, sound.frameIndex == vision.frameIndex,
                  sound.sampleRate.isFinite, sound.sampleRate >= 48_000, sound.sampleRate <= 1_000_000_000,
                  sound.sampleRate.rounded() == sound.sampleRate,
                  sound.i.count == TVSoundClock.count(frame: sound.frameIndex,standard: system.video,rate: Int(sound.sampleRate)),
                  sound.i.count == sound.q.count,
                  sound.i.allSatisfy(\.isFinite), sound.q.allSatisfy(\.isFinite) else { throw TVError.invalidSignal }
        }
        return combine(visionI: vision.i,visionQ: vision.q,frameIndex: vision.frameIndex,
                       visionFirstSample: system.video.sampleOffset(frame: vision.frameIndex),sound: sound,
                       profile: profile)
    }
}
