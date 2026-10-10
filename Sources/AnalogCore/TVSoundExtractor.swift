import Foundation
import Dispatch

/// Complex rotation split across output ranges; each worker restarts from the
/// exact phase at its first sample.
private struct TVComplexShiftWork: @unchecked Sendable {
    let i: UnsafeBufferPointer<Float>, q: UnsafeBufferPointer<Float>
    let oi: UnsafeMutableBufferPointer<Float>, oq: UnsafeMutableBufferPointer<Float>
    let startPhase: Double, step: Double
    func run(_ range: Range<Int>) {
        var c = cos(startPhase+step*Double(range.lowerBound))
        var s = sin(startPhase+step*Double(range.lowerBound))
        let dc = cos(step), ds = sin(step)
        let a = i.baseAddress!, b = q.baseAddress!
        let x = oi.baseAddress!, y = oq.baseAddress!
        for n in range {
            let ri = Double(a[n]), rq = Double(b[n])
            x[n] = Float(ri*c-rq*s)
            y[n] = Float(ri*s+rq*c)
            let next = c*dc-s*ds; s = c*ds+s*dc; c = next
            if n & 1023 == 0 { let norm = hypot(c,s); c /= norm; s /= norm }
        }
    }
}

/// Real-signal down-mix to a complex envelope, split the same way.
private struct TVRealMixWork: @unchecked Sendable {
    let v: UnsafeBufferPointer<Float>
    let oi: UnsafeMutableBufferPointer<Float>, oq: UnsafeMutableBufferPointer<Float>
    let startPhase: Double, step: Double
    func run(_ range: Range<Int>) {
        var c = cos(startPhase+step*Double(range.lowerBound))
        var s = sin(startPhase+step*Double(range.lowerBound))
        let dc = cos(step), ds = sin(step)
        let a = v.baseAddress!, x = oi.baseAddress!, y = oq.baseAddress!
        for n in range {
            let sample = Double(a[n])
            x[n] = Float(sample*c)
            y[n] = Float(-sample*s)
            let next = c*dc-s*ds; s = c*ds+s*dc; c = next
            if n & 1023 == 0 { let norm = hypot(c,s); c /= norm; s /= norm }
        }
    }
}

/// Extracts one companion carrier into the narrowband sound rate. Two modes
/// share the same stateful resampler:
/// - Split Sound band-selects the carrier from the shared front-end IQ.
/// - Intercarrier mixes the detected video, where the companion already beats
///   against the recovered vision carrier, so a common tuning drift cancels.
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

    /// Drop NCO phase and FIR history when the receive mode or source changes.
    public mutating func reset() {
        resampler = nil; configuredInputRate = 0; phase = 0
    }

    private mutating func configure(rate: Double) {
        if resampler == nil || configuredInputRate != rate {
            resampler = TVComplexResampler(inputRate: rate, outputRate: outputRate, radius: radius)
            configuredInputRate = rate
            phase = 0
        }
    }

    private mutating func resample(complexI: [Float], complexQ: [Float], frameIndex: Int64,
                                   firstSampleIndex: Int64) -> TVSoundIQ {
        let outCount = TVSoundClock.count(frame: frameIndex,standard: system.video,rate: Int(outputRate))
        let outStart = TVSoundClock.offset(frame: frameIndex,standard: system.video,rate: Int(outputRate))
        let (ri,rq) = resampler!.process(i: complexI,q: complexQ,inputStart: firstSampleIndex,
                                         outputStart: outStart,outputCount: outCount)
        return TVSoundIQ(system: system,frameIndex: frameIndex,sampleRate: outputRate,i: ri,q: rq)
    }

    /// Split Sound. `shiftHz` is the carrier's offset from 0 Hz in the supplied
    /// front-end IQ; the caller composes the RF spacing with the front end's
    /// tuning shift. `firstSampleIndex` is the absolute channel index of `i[0]`.
    public mutating func extract(i: [Float], q: [Float], frameIndex: Int64,
                                 firstSampleIndex: Int64, sampleRate: Double, shiftHz: Double) -> TVSoundIQ {
        configure(rate: sampleRate)
        let count = i.count
        var shiftedI = [Float](repeating: 0,count: count)
        var shiftedQ = shiftedI
        let step = -2*Double.pi*shiftHz/sampleRate
        let workers = min(8,max(1,count/65_536))
        i.withUnsafeBufferPointer { ip in
            q.withUnsafeBufferPointer { qp in
                shiftedI.withUnsafeMutableBufferPointer { op in
                    shiftedQ.withUnsafeMutableBufferPointer { oq in
                        let work = TVComplexShiftWork(i: ip,q: qp,oi: op,oq: oq,startPhase: phase,step: step)
                        if workers > 1 {
                            DispatchQueue.concurrentPerform(iterations: workers) { worker in
                                work.run(worker*count/workers ..< (worker+1)*count/workers)
                            }
                        } else { work.run(0..<count) }
                    }
                }
            }
        }
        phase = (phase+step*Double(count)).truncatingRemainder(dividingBy: 2*Double.pi)
        return resample(complexI: shiftedI,complexQ: shiftedQ,frameIndex: frameIndex,
                        firstSampleIndex: firstSampleIndex)
    }

    /// Intercarrier. Mixes the real detected video by the companion carrier so
    /// the beat becomes the sound envelope. The vision carrier in that video is
    /// already recovered, so a common tuning/drift error cancels rather than
    /// detuning the sound.
    public mutating func extractIntercarrier(_ video: [Float], frameIndex: Int64,
                                             firstSampleIndex: Int64, sampleRate: Double,
                                             carrierHz: Double) -> TVSoundIQ {
        configure(rate: sampleRate)
        let count = video.count
        var mixedI = [Float](repeating: 0,count: count)
        var mixedQ = mixedI
        let step = -2*Double.pi*carrierHz/sampleRate
        let workers = min(8,max(1,count/65_536))
        video.withUnsafeBufferPointer { vp in
            mixedI.withUnsafeMutableBufferPointer { op in
                mixedQ.withUnsafeMutableBufferPointer { oq in
                    let work = TVRealMixWork(v: vp,oi: op,oq: oq,startPhase: phase,step: step)
                    if workers > 1 {
                        DispatchQueue.concurrentPerform(iterations: workers) { worker in
                            work.run(worker*count/workers ..< (worker+1)*count/workers)
                        }
                    } else { work.run(0..<count) }
                }
            }
        }
        phase = (phase+step*Double(count)).truncatingRemainder(dividingBy: 2*Double.pi)
        return resample(complexI: mixedI,complexQ: mixedQ,frameIndex: frameIndex,
                        firstSampleIndex: firstSampleIndex)
    }
}
