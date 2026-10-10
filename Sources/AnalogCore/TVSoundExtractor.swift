import Foundation

/// Extracts one companion carrier from a shared channel IQ. It removes the
/// carrier offset (including the front end's tuning shift) with a continuous
/// NCO, then band-limits and converts to the narrowband sound rate with the
/// same stateful resampler the combiner uses in the other direction. The
/// result feeds TVSoundDemodulator with front-end projection disabled.
public struct TVSoundExtractor: Sendable {
    public let system: TerrestrialSystem
    public let outputRate: Double
    private let radius: Int
    private var resampler: TVComplexResampler?
    private var configuredInputRate: Double = 0
    private var phase = 0.0

    public init(system: TerrestrialSystem, outputRate: Double = 384_000, radius: Int = 12) {
        self.system = system; self.outputRate = outputRate; self.radius = radius
    }

    /// `shiftHz` is the carrier's offset from 0 Hz in the supplied IQ. The caller
    /// composes the RF spacing with the front end's tuning shift. `firstSampleIndex`
    /// is the absolute channel sample index of `i[0]`.
    public mutating func extract(i: [Float], q: [Float], frameIndex: Int64,
                                 firstSampleIndex: Int64, sampleRate: Double, shiftHz: Double) -> TVSoundIQ {
        if resampler == nil || configuredInputRate != sampleRate {
            resampler = TVComplexResampler(inputRate: sampleRate, outputRate: outputRate, radius: radius)
            configuredInputRate = sampleRate
            phase = 0
        }
        let count = i.count
        var shiftedI = i, shiftedQ = q
        let step = -2*Double.pi*shiftHz/sampleRate
        var c = cos(phase), s = sin(phase)
        let dc = cos(step), ds = sin(step)
        i.withUnsafeBufferPointer { ip in
            q.withUnsafeBufferPointer { qp in
                shiftedI.withUnsafeMutableBufferPointer { op in
                    shiftedQ.withUnsafeMutableBufferPointer { oq in
                        let a = ip.baseAddress!, b = qp.baseAddress!
                        let x = op.baseAddress!, y = oq.baseAddress!
                        for n in 0..<count {
                            let ri = Double(a[n]), rq = Double(b[n])
                            x[n] = Float(ri*Double(c)-rq*Double(s))
                            y[n] = Float(ri*Double(s)+rq*Double(c))
                            let next = c*dc-s*ds; s = c*ds+s*dc; c = next
                            if n & 1023 == 0 { let norm = hypot(c,s); c /= norm; s /= norm }
                        }
                    }
                }
            }
        }
        phase = atan2(s,c)
        let outCount = TVSoundClock.count(frame: frameIndex,standard: system.video,rate: Int(outputRate))
        let outStart = TVSoundClock.offset(frame: frameIndex,standard: system.video,rate: Int(outputRate))
        let (ri,rq) = resampler!.process(i: shiftedI,q: shiftedQ,inputStart: firstSampleIndex,
                                         outputStart: outStart,outputCount: outCount)
        return TVSoundIQ(system: system,frameIndex: frameIndex,sampleRate: outputRate,i: ri,q: rq)
    }
}
