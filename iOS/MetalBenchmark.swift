import Foundation
import Accelerate
import Dispatch

/// On-device CPU-vs-GPU kernel comparison for the Metal accelerator prototype.
///
/// The Mac numbers are a poor proxy for a phone: a desktop part has many fast
/// CPU cores next to a modest GPU slice, while a phone has few CPU cores next to
/// a proportionally much stronger GPU. This runs the same four kernels on the
/// device that the package test measures on the host, with the same CPU
/// references, and reports both times plus the numerical error. Both arms reuse
/// their buffers, so the comparison is steady-state rather than allocation.
struct MetalKernelMeasurement: Codable, Sendable {
    var system: String
    var kernel: String
    var samples: Int
    var cpuMS: Double
    var gpuMS: Double
    var maxError: Double
    var note: String
}

enum MetalBenchmark {
    /// Best-of-`repeats` after one warm-up call, which is what a steady pipeline
    /// would see. Returns the elapsed milliseconds.
    static func best(_ repeats: Int = 5, _ body: () -> Void) -> Double {
        body()
        var best = Double.greatestFiniteMagnitude
        for _ in 0..<repeats {
            let start = ContinuousClock.now
            body()
            let duration = start.duration(to: .now).components
            best = min(best,Double(duration.seconds)+Double(duration.attoseconds)/1e18)
        }
        return best*1000
    }

    static func error(_ a: [Float], _ b: [Float]) -> Double {
        guard a.count == b.count else { return .infinity }
        var maximum: Float = 0
        for index in a.indices { maximum = max(maximum,abs(a[index]-b[index])) }
        return Double(maximum)
    }

    static func error(_ ai: [Float], _ aq: [Float], _ bi: [Float], _ bq: [Float]) -> Double {
        max(error(ai,bi),error(aq,bq))
    }

    static func run() -> [MetalKernelMeasurement] {
        guard let metal = TVMetalAccelerator.shared else { return [] }
        var results = [MetalKernelMeasurement]()
        for system in TerrestrialSystem.allCases {
            let clock = TVChannelClock(system: system,sampleRate: system.video.sampleRate)
            let count = clock.count(frame: 0)
            // Deterministic broadband input, so neither the timing nor the error
            // comparison depends on a special case.
            var inputI = [Float](repeating: 0,count: count), inputQ = inputI
            for n in 0..<count {
                let t = Double(n)
                inputI[n] = Float(0.6*sin(2 * .pi * 0.0137 * t)+0.3*sin(2 * .pi * 0.091 * t))
                inputQ[n] = Float(0.6*cos(2 * .pi * 0.0137 * t)-0.2*sin(2 * .pi * 0.211 * t))
            }
            results.append(contentsOf: measure(system: system,count: count,i: inputI,q: inputQ,metal: metal))
        }
        return results
    }

    private static func measure(system: TerrestrialSystem, count: Int, i: [Float], q: [Float],
                                metal: TVMetalAccelerator) -> [MetalKernelMeasurement] {
        var results = [MetalKernelMeasurement]()
        let label = system.rawValue

        // 1. Complex FIR: the two 97-tap vision filters the VSB modulator applies.
        let taps = 97
        let kernel = (0..<taps).map { n -> Float in
            let fc = 0.225, index = Double(n-taps/2)
            let sinc = index == 0 ? 2*fc : sin(2 * .pi * fc*index)/(.pi*index)
            return Float(sinc*(0.54+0.46*cos(.pi*index/Double(taps/2))))
        }
        if let bank = metal.makeFIRBank([.init(kernel: kernel,plane: 0),.init(kernel: kernel,plane: 1)]) {
            // CPU arm: exactly the call the VSB modulator makes, with the filter
            // objects built once outside the timer.
            let cpuFilters = [TelevisionFIR(kernel),TelevisionFIR(kernel)]
            let cpu = best { _ = TelevisionFIR.together(cpuFilters,inputs: [i,q],execution: .accelerated) }
            let reference = TelevisionFIR.together([TelevisionFIR(kernel),TelevisionFIR(kernel)],
                                                  inputs: [i,q],execution: .accelerated).1
            let gpu = best { _ = bank.process(planes: [i,q]) }
            bank.reset()
            let actual = bank.process(planes: [i,q]) ?? []
            results.append(MetalKernelMeasurement(system: label,kernel: "complexFIR 2x97",samples: count,
                cpuMS: cpu,gpuMS: gpu,
                maxError: actual.count == 2 ? error(reference[0],reference[1],actual[0],actual[1]) : .infinity,
                note: "both arms include their own host write/readback"))
        }

        // 2. Complex rotation, as the tuner and the companion shift use it.
        let step = -2 * Double.pi * 20_000 / system.video.sampleRate
        var cpuOutI = [Float](repeating: 0,count: count), cpuOutQ = cpuOutI
        // Same parallel split the tuner and the companion shift use: disjoint
        // output ranges, each worker restarting from its exact phase.
        let ncoWorkers = min(8,max(1,count/65_536))
        let cpu = best {
            i.withUnsafeBufferPointer { ip in q.withUnsafeBufferPointer { qp in
                cpuOutI.withUnsafeMutableBufferPointer { op in cpuOutQ.withUnsafeMutableBufferPointer { oq in
                    let a = ip.baseAddress!, b = qp.baseAddress!, r = op.baseAddress!, s = oq.baseAddress!
                    DispatchQueue.concurrentPerform(iterations: ncoWorkers) { worker in
                        let lower = worker*count/ncoWorkers, upper = (worker+1)*count/ncoWorkers
                        var x = cos(step*Double(lower)), y = sin(step*Double(lower))
                        let dc = cos(step), ds = sin(step)
                        for n in lower..<upper {
                            r[n] = a[n]*Float(x)-b[n]*Float(y); s[n] = a[n]*Float(y)+b[n]*Float(x)
                            let next = x*dc-y*ds; y = x*ds+y*dc; x = next
                            if n & 1023 == 0 { let norm = hypot(x,y); x /= norm; y /= norm }
                        }
                    }
                } }
            } }
        }
        let gpuResult = metal.ncoMix(i: i,q: q,startPhase: 0,step: step)
        let gpu = best { _ = metal.ncoMix(i: i,q: q,startPhase: 0,step: step) }
        results.append(MetalKernelMeasurement(system: label,kernel: "ncoMix",samples: count,
            cpuMS: cpu,gpuMS: gpu,
            maxError: gpuResult.map { error(cpuOutI,cpuOutQ,$0.i,$0.q) } ?? .infinity,
            note: "both arms parallel over the same sample count"))

        // 3. Transmitter PA: curve lookup, 2x interpolation and the anti-alias
        // decimation, which the CPU path materialises as two 2x arrays.
        var settings = TVTransmitterSettings()
        settings.enabled = true; settings.powerDB = 3; settings.sharedCoupling = 0.15
        let otherPower = (0..<max(1,count/46)).map { _ in Float(0.0012) }
        if let pa = metal.makeTransmitterPA(settings: settings) {
            var cpuAmplifier = TVTransmitterAmplifier()
            let cpu = best {
                _ = cpuAmplifier.apply(i: i,q: q,settings: settings,execution: .accelerated,otherPower: otherPower)
            }
            let expected = cpuAmplifier.apply(i: i,q: q,settings: settings,
                                              execution: .accelerated,otherPower: otherPower)
            let gpu = best { _ = pa.apply(i: i,q: q,otherPower: otherPower) }
            let actual = pa.apply(i: i,q: q,otherPower: otherPower)
            results.append(MetalKernelMeasurement(system: label,kernel: "paTransfer",samples: count,
                cpuMS: cpu,gpuMS: gpu,
                maxError: actual.map { error(expected.0,expected.1,$0.i,$0.q) } ?? .infinity,
                note: "GPU keeps the 2x envelope inside the kernel"))
        }

        // 4. Channel noise: Box-Muller from a counter-based hash. The chain's
        // accelerated CPU generator is private to the channel, so this reports the
        // GPU arm and its distribution rather than a CPU pair.
        let gpuNoise = best { _ = metal.gaussianNoise(seed: 42,count: count,indexBase: 0,scale: 0.01) }
        let noise = metal.gaussianNoise(seed: 42,count: count,indexBase: 0,scale: 0.01)
        var varianceError = Double.infinity
        if let noise, !noise.i.isEmpty {
            let mean = noise.i.reduce(0.0) { $0+Double($1) }/Double(noise.i.count)
            let variance = noise.i.reduce(0.0) { $0+pow(Double($1)/0.01-mean/0.01,2) }/Double(noise.i.count)
            varianceError = abs(variance-1)
        }
        results.append(MetalKernelMeasurement(system: label,kernel: "gaussianNoise",samples: count,
            cpuMS: 0,gpuMS: gpuNoise,maxError: varianceError,
            note: "no CPU arm; maxError is the unit-variance error"))
        return results
    }
}
