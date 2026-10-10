import Foundation

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
    public var taps: Int { 2*radius+1 }
    public var latencySeconds: Double { Double(radius)/inputRate }
    /// Flattened phase bank: phases * taps.
    private let weightTable: [Float]
    private let historyCount: Int
    private var historyI: [Float]
    private var historyQ: [Float]

    public init(inputRate: Double, outputRate: Double, radius: Int = 8, phases: Int = 512) {
        precondition(inputRate > 0 && outputRate > 0 && radius >= 1 && phases >= 2)
        self.inputRate = inputRate; self.outputRate = outputRate
        self.radius = radius; self.phases = phases
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
        var outI = [Float](repeating: 0, count: outputCount)
        var outQ = outI
        let ratio = inputRate/outputRate
        let tapCount = taps, phaseCount = phases, kernelRadius = radius
        fullI.withUnsafeBufferPointer { xp in
            fullQ.withUnsafeBufferPointer { yp in
                outI.withUnsafeMutableBufferPointer { op in
                    outQ.withUnsafeMutableBufferPointer { oq in
                        weightTable.withUnsafeBufferPointer { wp in
                            let x = xp.baseAddress!, y = yp.baseAddress!
                            let sampleCount = fullI.count
                            let table = wp.baseAddress!
                            for m in 0..<outputCount {
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
                                for k in 0..<tapCount {
                                    let local = Int(first+Int64(k)-fullStart)
                                    if local >= 0, local < sampleCount {
                                        let weight = Double(table[offset+k])
                                        si += weight*Double(x[local]); sq += weight*Double(y[local])
                                    }
                                }
                                op[m] = Float(si); oq[m] = Float(sq)
                            }
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
