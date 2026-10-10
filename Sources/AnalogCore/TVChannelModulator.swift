import Foundation
import Accelerate

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
    private var ncoPhase = 0.0

    public init(system: TerrestrialSystem, sampleRate: Double? = nil, soundRadius: Int = 8) {
        self.system = system
        self.sampleRate = sampleRate ?? system.video.sampleRate
        self.soundRadius = soundRadius
    }

    /// Combine arbitrary-grid vision and sound blocks. `visionFirstSample` is the
    /// absolute channel sample index of `visionI[0]`; the output keeps that index.
    public mutating func combine(visionI: [Float], visionQ: [Float], frameIndex: Int64,
                                 visionFirstSample: Int64, sound: TVSoundIQ?) -> TVChannelIQ {
        var i = visionI, q = visionQ
        if let sound, !sound.i.isEmpty {
            if soundResampler == nil || soundInputRate != sound.sampleRate {
                soundResampler = TVComplexResampler(inputRate: sound.sampleRate, outputRate: sampleRate,
                                                    radius: soundRadius)
                soundInputRate = sound.sampleRate
                ncoPhase = 0
            }
            let soundStart = TVSoundClock.offset(frame: frameIndex,standard: system.video,rate: Int(sound.sampleRate))
            let resampled = soundResampler!.process(i: sound.i,q: sound.q,inputStart: soundStart,
                                                    outputStart: visionFirstSample,outputCount: i.count)
            let shiftStep = 2*Double.pi*system.soundCarrierHz/sampleRate
            var c = cos(ncoPhase), s = sin(ncoPhase)
            let dc = cos(shiftStep), ds = sin(shiftStep)
            i.withUnsafeMutableBufferPointer { ip in
                q.withUnsafeMutableBufferPointer { qp in
                    resampled.0.withUnsafeBufferPointer { ri in
                        resampled.1.withUnsafeBufferPointer { rq in
                            let pi = ip.baseAddress!, pq = qp.baseAddress!
                            let si = ri.baseAddress!, sq = rq.baseAddress!
                            let count = ip.count
                            for n in 0..<count {
                                let a = Double(si[n]), b = Double(sq[n])
                                pi[n] += Float(a*Double(c)-b*Double(s))
                                pq[n] += Float(a*Double(s)+b*Double(c))
                                let next = c*dc-s*ds; s = c*ds+s*dc; c = next
                                if n & 1023 == 0 { let norm = hypot(c,s); c /= norm; s /= norm }
                            }
                        }
                    }
                }
            }
            ncoPhase = atan2(s,c)
        }
        return TVChannelIQ(system: system,frameIndex: frameIndex,firstSampleIndex: visionFirstSample,
                           sampleRate: sampleRate,i: i,q: q)
    }

    /// High-level entry point. A nil sound signal leaves the companion carrier off.
    public mutating func combine(vision: TelevisionRF, sound: TVSoundIQ?) throws -> TVChannelIQ {
        guard vision.sampleRate == sampleRate else { throw TVError.invalidSignal }
        return combine(visionI: vision.i,visionQ: vision.q,frameIndex: vision.frameIndex,
                       visionFirstSample: system.video.sampleOffset(frame: vision.frameIndex),sound: sound)
    }
}
