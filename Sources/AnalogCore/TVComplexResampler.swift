import Foundation
import Dispatch

/// One disjoint output range per synchronous worker. Inputs and the phase bank
/// are read-only; each worker writes only its own output samples, so the
/// per-sample arithmetic and therefore the result stay bit-identical.
private struct TVResamplerWork: @unchecked Sendable {
    let x: UnsafeBufferPointer<Float>
    let y: UnsafeBufferPointer<Float>
    let table: UnsafeBufferPointer<Float>
    let outI: UnsafeMutableBufferPointer<Float>
    let outQ: UnsafeMutableBufferPointer<Float>
    let tapCount: Int, phaseCount: Int, kernelRadius: Int
    let ratio: Double
    let fullStart: Int64
    let outputStart: Int64
    /// Accumulate the tap sum in single precision. The kernel, the tap positions
    /// and the output rate are unchanged, so the filter response is unchanged;
    /// only the rounding of the sum moves, by far less than one output LSB.
    let singlePrecision: Bool
    func run(_ range: Range<Int>) {
        if singlePrecision { runSingle(range) } else { runDouble(range) }
    }
    private func runDouble(_ range: Range<Int>) {
        let sampleCount = x.count
        let xb = x.baseAddress!, yb = y.baseAddress!, tb = table.baseAddress!
        let oi = outI.baseAddress!, oq = outQ.baseAddress!
        for m in range {
            let position = Double(outputStart+Int64(m))*ratio
            let center = position-Double(kernelRadius)
            let base = center.rounded(.down)
            let fraction = center-base
            var phase = Int(fraction*Double(phaseCount))
            if phase >= phaseCount { phase = phaseCount-1 }
            if phase < 0 { phase = 0 }
            let offset = phase*tapCount
            let first = Int64(base)-Int64(kernelRadius)
            var si = 0.0, sq = 0.0
            let localFirst = Int(first-fullStart)
            if localFirst >= 0, localFirst <= sampleCount-tapCount {
                // Almost every output has its entire FIR window in the block.
                // Check that window once so the hot dot products have no
                // per-tap branches or absolute-index conversions.
                for k in 0..<tapCount {
                    let weight = Double(tb[offset+k])
                    si += weight*Double(xb[localFirst+k]); sq += weight*Double(yb[localFirst+k])
                }
            } else {
                for k in 0..<tapCount {
                    let local = localFirst+k
                    guard local >= 0, local < sampleCount else { continue }
                    let weight = Double(tb[offset+k])
                    si += weight*Double(xb[local]); sq += weight*Double(yb[local])
                }
            }
            oi[m] = Float(si); oq[m] = Float(sq)
        }
    }
    private func runSingle(_ range: Range<Int>) {
        let sampleCount = x.count
        let xb = x.baseAddress!, yb = y.baseAddress!, tb = table.baseAddress!
        let oi = outI.baseAddress!, oq = outQ.baseAddress!
        for m in range {
            let position = Double(outputStart+Int64(m))*ratio
            let center = position-Double(kernelRadius)
            let base = center.rounded(.down)
            let fraction = center-base
            var phase = Int(fraction*Double(phaseCount))
            if phase >= phaseCount { phase = phaseCount-1 }
            if phase < 0 { phase = 0 }
            let offset = phase*tapCount
            let first = Int64(base)-Int64(kernelRadius)
            let localFirst = Int(first-fullStart)
            if localFirst >= 0, localFirst <= sampleCount-tapCount {
                // The tap sum is a chain of dependent float adds, and at these
                // lengths that chain, not the multiply throughput, sets the cost.
                // Four independent partial sums keep four adds in flight. They are
                // lanes of one SIMD4 pair so the multiply-accumulate runs on the
                // vector unit, and the lane assignment, the order inside each lane
                // and the final (s0+s1)+(s2+s3) fold are exactly the scalar ones,
                // so the sum is bit-identical rather than merely close.
                var accI = SIMD4<Float>(), accQ = SIMD4<Float>()
                var k = 0
                while k + 4 <= tapCount {
                    let w = UnsafeRawPointer(tb+offset+k).loadUnaligned(as: SIMD4<Float>.self)
                    let xi = UnsafeRawPointer(xb+localFirst+k).loadUnaligned(as: SIMD4<Float>.self)
                    let xq = UnsafeRawPointer(yb+localFirst+k).loadUnaligned(as: SIMD4<Float>.self)
                    accI += w*xi; accQ += w*xq
                    k += 4
                }
                // The remaining taps have always gone into the first partial sum,
                // so they are added to lane 0 in the same order.
                var si0 = accI[0], sq0 = accQ[0]
                while k < tapCount {
                    let weight = tb[offset+k]
                    si0 += weight*xb[localFirst+k]; sq0 += weight*yb[localFirst+k]
                    k += 1
                }
                oi[m] = (si0+accI[1])+(accI[2]+accI[3])
                oq[m] = (sq0+accQ[1])+(accQ[2]+accQ[3])
            } else {
                var si: Float = 0, sq: Float = 0
                for k in 0..<tapCount {
                    let local = localFirst+k
                    guard local >= 0, local < sampleCount else { continue }
                    let weight = tb[offset+k]
                    si += weight*xb[local]; sq += weight*yb[local]
                }
                oi[m] = si; oq[m] = sq
            }
        }
    }
}

/// Stateful, band-limited complex resampler. It converts between two arbitrary
/// rates through a windowed-sinc interpolation kernel, keeps FIR history across
/// blocks and derives every tap position from the absolute output index, so
/// consecutive frames splice without an accumulated phase or count drift.
///
/// The kernel is causal: output sample m is the input signal at
/// `m/outputRate - radius/inputRate`. That constant delay is reported as
/// `latencySeconds` so callers can account for it instead of hiding it in a
/// second signal path.
public struct TVComplexResampler: Sendable {
    public let inputRate: Double
    public let outputRate: Double
    public let radius: Int
    public let phases: Int
    /// Sum the tap products in single precision. Diagnostic and profile knob;
    /// the kernel and tap positions are unaffected.
    public let singlePrecisionAccumulation: Bool
    public var taps: Int { 2*radius+1 }
    public var latencySeconds: Double { Double(radius)/inputRate }
    /// Flattened phase bank: phases * taps.
    private let weightTable: [Float]
    private let historyCount: Int
    private var historyI: [Float]
    private var historyQ: [Float]

    public init(inputRate: Double, outputRate: Double, radius: Int = 8, phases: Int = 512,
                singlePrecisionAccumulation: Bool = false) {
        precondition(inputRate > 0 && outputRate > 0 && radius >= 1 && phases >= 2)
        self.inputRate = inputRate; self.outputRate = outputRate
        self.radius = radius; self.phases = phases
        self.singlePrecisionAccumulation = singlePrecisionAccumulation
        historyCount = 2*radius+2
        historyI = [Float](repeating: 0, count: historyCount)
        historyQ = [Float](repeating: 0, count: historyCount)
        // Anti-imaging while upsampling; anti-aliasing before decimation.
        let normalized = min(1.0, outputRate/inputRate)
        let tapCount = 2*radius+1
        var table = [Float](repeating: 0, count: phases*tapCount)
        for phase in 0..<phases {
            let fraction = Double(phase)/Double(phases)
            var sum = 0.0
            for k in -radius...radius {
                let tau = fraction-Double(k)
                let x = normalized*tau
                let sinc = x == 0 ? 1.0 : sin(Double.pi*x)/(Double.pi*x)
                let window = 0.54+0.46*cos(Double.pi*tau/Double(radius))
                let value = normalized*sinc*window
                table[phase*tapCount+radius+k] = Float(value)
                sum += value
            }
            if abs(sum) > 1e-12 {
                for k in 0..<tapCount { table[phase*tapCount+k] /= Float(sum) }
            }
        }
        weightTable = table
    }

    /// Resample one input block aligned to absolute indices. `inputStart` is the
    /// absolute input sample index of `i[0]`; `outputStart` is the absolute output
    /// sample index of the first returned sample. Exactly `outputCount` samples
    /// are returned. Taps that reach past the supplied input read as zero.
    public mutating func process(i: [Float], q: [Float], inputStart: Int64,
                                 outputStart: Int64, outputCount: Int) -> ([Float],[Float]) {
        guard outputCount > 0 else { return ([],[]) }
        guard i.count == q.count, !i.isEmpty else {
            return ([Float](repeating:0,count: outputCount),[Float](repeating:0,count: outputCount))
        }
        let fullI = historyI+i, fullQ = historyQ+q
        let fullStart = inputStart-Int64(historyI.count)
        var outI = uninitializedFloats(outputCount), outQ = uninitializedFloats(outputCount)
        let ratio = inputRate/outputRate
        let tapCount = taps, phaseCount = phases, kernelRadius = radius
        fullI.withUnsafeBufferPointer { xp in
            fullQ.withUnsafeBufferPointer { yp in
                outI.withUnsafeMutableBufferPointer { op in
                    outQ.withUnsafeMutableBufferPointer { oq in
                        weightTable.withUnsafeBufferPointer { wp in
                            let work = TVResamplerWork(x: xp,y: yp,table: wp,outI: op,outQ: oq,
                                tapCount: tapCount,phaseCount: phaseCount,kernelRadius: kernelRadius,
                                ratio: ratio,fullStart: fullStart,outputStart: outputStart,
                                singlePrecision: singlePrecisionAccumulation)
                            let workers = cappedWorkers(min(12,max(1,outputCount/32_768)))
                            if workers > 1 {
                                DispatchQueue.concurrentPerform(iterations: workers) { worker in
                                    work.run(worker*outputCount/workers ..< (worker+1)*outputCount/workers)
                                }
                            } else { work.run(0..<outputCount) }
                        }
                    }
                }
            }
        }
        let keep = min(fullI.count, historyCount)
        historyI = Array(fullI.suffix(keep)); historyQ = Array(fullQ.suffix(keep))
        return (outI,outQ)
    }
}
