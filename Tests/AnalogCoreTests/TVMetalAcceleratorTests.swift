#if canImport(Metal)
import XCTest
import Metal
import Accelerate
@testable import AnalogCore

/// Numerical equivalence and cost of the four Metal kernels against the CPU
/// implementations they would replace.
///
/// The equivalence assertions are absolute error bounds on real frame-sized
/// data and do not depend on the machine. The timing section only prints, so
/// the same suite doubles as a report on whatever device runs it.
final class TVMetalAcceleratorTests: XCTestCase {
    /// Exact per-frame sample counts from `TVChannelClock` at the vision 4fsc
    /// grid. NTSC lands one sample below the nominal 477,750 because the frame
    /// boundary is a floor of a value that rounds just under the integer.
    private let palFrame = 709_379
    private let ntscFrame = 477_749

    // MARK: - Fixtures

    private func frameCount(_ system: TerrestrialSystem) -> Int {
        TVChannelClock(system: system, sampleRate: system.video.sampleRate).count(frame: 0)
    }

    private func requireAccelerator() throws -> TVMetalAccelerator {
        guard let accelerator = TVMetalAccelerator() else {
            throw XCTSkip("no Metal device or the runtime kernel library did not build")
        }
        return accelerator
    }

    /// Deterministic white-noise-ish complex input at signal amplitude 1, so a
    /// reported error is not an artefact of a low-level or tonal waveform.
    private func noiseLikeInput(count: Int) -> (i: [Float], q: [Float]) {
        var state: UInt64 = 0x243f6a8885a308d3
        var i = [Float](repeating: 0, count: count), q = i
        for n in 0..<count {
            state = state &* 6364136223846793005 &+ 1442695040888963407
            i[n] = Float(Int32(truncatingIfNeeded: state >> 33))/Float(1 << 30) - 1
            state = state &* 6364136223846793005 &+ 1442695040888963407
            q[n] = Float(Int32(truncatingIfNeeded: state >> 33))/Float(1 << 30) - 1
        }
        return (i, q)
    }

    /// One real frame through the real encoder and modulator, which is the
    /// signal the dense stages actually see.
    private func modulatedInput(_ system: TerrestrialSystem) throws -> (i: [Float], q: [Float]) {
        let composite = try TVEngine.encode(TVFrame.colorBars(system.video), frameIndex: 0)
        var modulator = VSBModulator(system: system)
        let rf = try modulator.modulate(composite)
        return (rf.i, rf.q)
    }

    /// The two VSB filters TVModulator builds: one real, one imaginary, over the
    /// same envelope.
    private func vsbKernels(_ system: TerrestrialSystem) -> ([Float], [Float]) {
        let rate = system.video.sampleRate, vestige = system.vestigeMHz*1e6
        return TelevisionFIR.complexKernel(rate: rate) { f in
            let side = abs(f) < vestige ? 1 + sin(.pi*f/(2*vestige)) : (f > 0 ? 2.0 : 0.0)
            return side*TelevisionFIR.taper(f, cutoff: system.videoMHz*1e6)
        }
    }

    private func ifKernels(_ system: TerrestrialSystem) -> ([Float], [Float]) {
        let rate = system.video.sampleRate
        let low = -1.25e6, high = Double(system.channelMHz)*1e6 - 1.25e6
        let center = (high + low)/2, half = (high-low)/2
        return TelevisionFIR.complexKernel(rate: rate, normalizationHz: center) { f in
            TelevisionFIR.taper(f-center, cutoff: half)
        }
    }

    /// The transmitter's normalized anti-alias kernel at the 2x rate.
    private func antialiasKernel(radius: Int) -> [Float] {
        let fc = 0.225
        var kernel = (-radius...radius).map { tap -> Float in
            let sinc = tap == 0 ? 2*fc : sin(2*Double.pi*fc*Double(tap))/(Double.pi*Double(tap))
            let taper = 0.54 + 0.46*cos(Double.pi*Double(tap)/Double(radius))
            return Float(sinc*taper)
        }
        let sum = kernel.reduce(0,+)
        for tap in kernel.indices { kernel[tap] /= sum }
        return kernel
    }

    private func maximumError(_ a: [Float], _ b: [Float]) -> Float {
        var maximum: Float = 0
        for n in a.indices { maximum = max(maximum, abs(a[n]-b[n])) }
        return maximum
    }

    // MARK: - References

    /// Literal transcription of the mixer bodies in `TVTunerWork` and
    /// `TVComplexShiftWork`. Both are file-private inside public types, so the
    /// test target cannot call them; the recurrence, its Double accumulator and
    /// the every-1024 renormalisation are copied verbatim, which is the
    /// `.reference` path of `TVReceiverFrontEnd` and of `TVSoundExtractor`.
    private enum ReferenceMixer {
        static func mix(i: [Float], q: [Float], startPhase: Double,
                        step: Double) -> (i: [Float], q: [Float]) {
            var outI = [Float](repeating: 0, count: i.count), outQ = outI
            var x = cos(startPhase), y = sin(startPhase)
            let c = cos(step), s = sin(step)
            for n in i.indices {
                outI[n] = i[n]*Float(x)-q[n]*Float(y)
                outQ[n] = i[n]*Float(y)+q[n]*Float(x)
                let next = x*c-y*s; y = x*s+y*c; x = next
                if n & 1023 == 0 { let norm = hypot(x,y); x /= norm; y /= norm }
            }
            return (outI, outQ)
        }

        /// The parallel split `TVReceiverFrontEnd` uses when tuned off centre,
        /// where each worker restarts from the analytic phase of its first
        /// sample. This is the CPU side of the tuner timing row.
        static func parallelMix(i: [Float], q: [Float], startPhase: Double, step: Double) -> (i: [Float], q: [Float]) {
            var outI = [Float](repeating: 0, count: i.count), outQ = outI
            let count = i.count
            let workers = cappedWorkers(min(ProcessInfo.processInfo.activeProcessorCount, max(1, count/65_536)))
            i.withUnsafeBufferPointer { a in q.withUnsafeBufferPointer { b in
                outI.withUnsafeMutableBufferPointer { r in outQ.withUnsafeMutableBufferPointer { o in
                    let work = ReferenceTuner(i: a, q: b, outI: r, outQ: o, phase: startPhase, step: step)
                    if workers > 1 {
                        DispatchQueue.concurrentPerform(iterations: workers) { worker in
                            work.run(worker*count/workers ..< (worker+1)*count/workers)
                        }
                    } else { work.run(0..<count) }
                } }
            } }
            return (outI, outQ)
        }
    }

    /// Borrowed buffers live only through the synchronous workers, exactly like
    /// the private `TVTunerWork` this mirrors.
    private struct ReferenceTuner: @unchecked Sendable {
        let i: UnsafeBufferPointer<Float>, q: UnsafeBufferPointer<Float>
        let outI: UnsafeMutableBufferPointer<Float>, outQ: UnsafeMutableBufferPointer<Float>
        let phase: Double, step: Double
        func run(_ range: Range<Int>) {
            var x = cos(phase+step*Double(range.lowerBound)), y = sin(phase+step*Double(range.lowerBound))
            let c = cos(step), s = sin(step)
            let a = i.baseAddress!, b = q.baseAddress!
            let r = outI.baseAddress!, o = outQ.baseAddress!
            for n in range {
                r[n] = a[n]*Float(x)-b[n]*Float(y)
                o[n] = a[n]*Float(y)+b[n]*Float(x)
                let next = x*c-y*s; y = x*s+y*c; x = next
                if n & 1023 == 0 { let norm = hypot(x,y); x /= norm; y /= norm }
            }
        }
    }

    /// Transcription of the noise generator the RF channel evaluates: the same
    /// splitmix64 finalizer and per-index multipliers as `TVNoiseBlock`, then
    /// Box-Muller. The engine deliberately allows a different realization here,
    /// so this only verifies the hash and transform, not the sample sequence.
    private enum ReferenceNoise {
        static func uniform(_ state: UInt64) -> Float {
            var z = state; z = (z ^ (z >> 30)) &* 0xbf58476d1ce4e5b9
            z = (z ^ (z >> 27)) &* 0x94d049bb133111eb
            return Float((z ^ (z >> 31)) >> 40)/Float(1 << 24)
        }

        static func generate(seed: UInt64, count: Int, indexBase: Int, scale: Float = 1) -> (i: [Float], q: [Float]) {
            var outI = [Float](repeating: 0, count: count), outQ = outI
            for n in 0..<count {
                let index = UInt64(indexBase + n)
                let radius = max(1e-7, uniform(seed &+ index &* 0x9e3779b97f4a7c15))
                let angle = 2*Float.pi*uniform(seed &+ index &* 0xd1b54a32d192ed03)
                let length = sqrt(-2*log(radius))*scale
                outI[n] = length*cos(angle)
                outQ[n] = length*sin(angle)
            }
            return (outI, outQ)
        }

        /// The accelerated path: one stream over disjoint ranges, with the
        /// vector log/sqrt/sincos `TVNoiseBlock` uses. This is the CPU side of
        /// the noise timing row.
        static func parallel(seed: UInt64, count: Int, indexBase: Int) -> (i: [Float], q: [Float]) {
            var radii = [Float](repeating: 0, count: count), angles = radii
            var outI = radii, outQ = radii
            let workers = cappedWorkers(min(8, max(1, count/65_536)))
            radii.withUnsafeMutableBufferPointer { r in angles.withUnsafeMutableBufferPointer { a in
                outI.withUnsafeMutableBufferPointer { cosine in outQ.withUnsafeMutableBufferPointer { sine in
                    let block = ReferenceNoiseBlock(radius: r, angle: a, cosine: cosine, sine: sine,
                                                    seed: seed, indexBase: indexBase)
                    if workers > 1 {
                        DispatchQueue.concurrentPerform(iterations: workers) { worker in
                            block.run(worker*count/workers ..< (worker+1)*count/workers)
                        }
                    } else { block.run(0..<count) }
                } }
            } }
            return (outI, outQ)
        }
    }

    /// Mirrors `TVNoiseBlock.run`, including its in-place vector transforms.
    private struct ReferenceNoiseBlock: @unchecked Sendable {
        let radius: UnsafeMutableBufferPointer<Float>, angle: UnsafeMutableBufferPointer<Float>
        let cosine: UnsafeMutableBufferPointer<Float>, sine: UnsafeMutableBufferPointer<Float>
        let seed: UInt64, indexBase: Int
        func run(_ range: Range<Int>) {
            guard !range.isEmpty else { return }
            let r = radius.baseAddress!, a = angle.baseAddress!
            let cosines = cosine.baseAddress!, sines = sine.baseAddress!
            for n in range {
                let index = UInt64(indexBase + n)
                r[n] = max(1e-7, ReferenceNoise.uniform(seed &+ index &* 0x9e3779b97f4a7c15))
                a[n] = 2 * .pi * ReferenceNoise.uniform(seed &+ index &* 0xd1b54a32d192ed03)
            }
            var length = Int32(range.count)
            let base = range.lowerBound
            vvlogf(r+base, r+base, &length)
            var scale: Float = -2
            vDSP_vsmul(r+base, 1, &scale, r+base, 1, vDSP_Length(length))
            vvsqrtf(r+base, r+base, &length)
            vvsincosf(sines+base, cosines+base, a+base, &length)
        }
    }

    // MARK: - Complex FIR

    /// A pass shorter than the filter's own history, which is the one case
    /// where the next history is not simply the tail of the input just written.
    func testComplexFIRShortPassHistorySplice() throws {
        let accelerator = try requireAccelerator()
        let system = TerrestrialSystem.palDK
        let (kernelReal, kernelImaginary) = vsbKernels(system)
        let block = 32
        let signal = noiseLikeInput(count: block*5)
        guard let bank = accelerator.makeFIRBank([.init(kernel: kernelReal, plane: 0),
                                                  .init(kernel: kernelImaginary, plane: 0)]) else {
            return XCTFail("bank did not build")
        }
        var real = TelevisionFIR(kernelReal), imaginary = TelevisionFIR(kernelImaginary)
        var maximum: Float = 0
        for index in 0..<5 {
            let envelope = Array(signal.i[(index*block)..<((index+1)*block)])
            let expected = TelevisionFIR.together([real, imaginary],
                                                  inputs: [envelope, envelope], execution: .accelerated)
            real = expected.0[0]; imaginary = expected.0[1]
            let actual = try XCTUnwrap(bank.process(planes: [envelope]))
            maximum = max(maximum, maximumError(actual[0], expected.1[0]))
            maximum = max(maximum, maximumError(actual[1], expected.1[1]))
        }
        print("complexFIR PAL-D/K \(block)-sample passes of a \(kernelReal.count) tap filter: max |error| \(maximum)")
        XCTAssertLessThan(maximum, 1e-5)
    }

    func testComplexFIRMatchesCPU() throws {
        let accelerator = try requireAccelerator()
        for system in TerrestrialSystem.allCases {
            let (kernelReal, kernelImaginary) = vsbKernels(system)
            let frames = frameCount(system)
            XCTAssertEqual(frames, system == .palDK ? palFrame : ntscFrame)
            for blocks in [1, 3] {
                let signal = noiseLikeInput(count: frames*blocks)
                guard let bank = accelerator.makeFIRBank([.init(kernel: kernelReal, plane: 0),
                                                          .init(kernel: kernelImaginary, plane: 0)]) else {
                    return XCTFail("bank did not build")
                }
                var real = TelevisionFIR(kernelReal), imaginary = TelevisionFIR(kernelImaginary)
                var maximum: Float = 0
                for block in 0..<blocks {
                    let start = block*frames, end = start + frames
                    let envelope = Array(signal.i[start..<end])
                    let expected = TelevisionFIR.together([real, imaginary],
                                                          inputs: [envelope, envelope], execution: .accelerated)
                    real = expected.0[0]; imaginary = expected.0[1]
                    let actual = try XCTUnwrap(bank.process(planes: [envelope]))
                    XCTAssertEqual(actual.count, 2)
                    maximum = max(maximum, maximumError(actual[0], expected.1[0]))
                    maximum = max(maximum, maximumError(actual[1], expected.1[1]))
                }
                print("complexFIR \(system.rawValue) 2x\(kernelReal.count) taps, \(blocks) block(s): max |error| \(maximum)")
                XCTAssertLessThan(maximum, 1e-5)
            }
        }
    }

    func testComplexFIRFourPlanarFiltersMatchReceiverIF() throws {
        let accelerator = try requireAccelerator()
        for system in TerrestrialSystem.allCases {
            let (ai, bi) = ifKernels(system)
            let input = try modulatedInput(system)
            guard let bank = accelerator.makeFIRBank([.init(kernel: ai, plane: 0), .init(kernel: bi, plane: 0),
                                                      .init(kernel: ai, plane: 1), .init(kernel: bi, plane: 1)]) else {
                return XCTFail("bank did not build")
            }
            let expected = TelevisionFIR.together([TelevisionFIR(ai), TelevisionFIR(bi),
                                                   TelevisionFIR(ai), TelevisionFIR(bi)],
                                                  inputs: [input.i, input.i, input.q, input.q], execution: .accelerated)
            let actual = try XCTUnwrap(bank.process(planes: [input.i, input.q]))
            XCTAssertEqual(actual.count, 4)
            var maximum: Float = 0
            for index in 0..<4 { maximum = max(maximum, maximumError(actual[index], expected.1[index])) }
            // |ai - bq| and |bi + aq| is the receiver's IF combination.
            var combined: Float = 0
            for n in input.i.indices {
                combined = max(combined, abs((actual[0][n]-actual[3][n]) - (expected.1[0][n]-expected.1[3][n])))
                combined = max(combined, abs((actual[1][n]+actual[2][n]) - (expected.1[1][n]+expected.1[2][n])))
            }
            print("complexFIR \(system.rawValue) 4x\(ai.count) taps over 2 planes: max |error| \(maximum), IF combination \(combined)")
            XCTAssertLessThan(maximum, 1e-5)
            XCTAssertLessThan(combined, 1e-5)
        }
    }

    func testComplexFIRDecimationMatchesCPU() throws {
        let accelerator = try requireAccelerator()
        let kernel = antialiasKernel(radius: 12)
        for system in TerrestrialSystem.allCases {
            let frames = frameCount(system)*2
            let signal = noiseLikeInput(count: frames)
            guard let bank = accelerator.makeFIRBank([.init(kernel: kernel, plane: 0)]) else {
                return XCTFail("bank did not build")
            }
            var filter = TelevisionFIR(kernel)
            let expected = filter.decimate(signal.i, factor: 2, phase: 1)
            let actual = try XCTUnwrap(bank.process(planes: [signal.i], factor: 2, phase: 1))
            let maximum = maximumError(actual[0], expected)
            print("complexFIR \(system.rawValue) decimate 2/1, \(kernel.count) taps: "
                  + "\(actual[0].count) of \(signal.i.count) samples, max |error| \(maximum)")
            XCTAssertEqual(actual[0].count, expected.count)
            XCTAssertLessThan(maximum, 1e-5)
        }
    }

    // MARK: - NCO complex mixing

    func testNCOMixMatchesCPU() throws {
        let accelerator = try requireAccelerator()
        for system in TerrestrialSystem.allCases {
            let input = try modulatedInput(system)
            let rate = system.video.sampleRate
            // A split-sound companion shift and a tuner detune, streamed over
            // two frames with the phase carried exactly as the callers carry it.
            for (name, shiftHz) in [("companion", system == .palDK ? 5.5e6 : 4.5e6), ("detune", 2e6)] {
                let step = -2*Double.pi*shiftHz/rate
                var phase = 0.0
                var maximum: Float = 0
                var phaseError = 0.0
                for block in 0..<2 {
                    let start = block*input.i.count/2, end = start + input.i.count/2
                    let blockI = Array(input.i[start..<end]), blockQ = Array(input.q[start..<end])
                    let expected = ReferenceMixer.mix(i: blockI, q: blockQ, startPhase: phase, step: step)
                    let actual = try XCTUnwrap(accelerator.ncoMix(i: blockI, q: blockQ, startPhase: phase, step: step))
                    maximum = max(maximum, maximumError(actual.i, expected.i))
                    maximum = max(maximum, maximumError(actual.q, expected.q))
                    let advanced = (phase + step*Double(blockI.count)).truncatingRemainder(dividingBy: 2*Double.pi)
                    phaseError = max(phaseError, abs(actual.phase - advanced))
                    phase = advanced
                }
                print("ncoMix \(system.rawValue) \(name) step \(step) rad: max |error| \(maximum), phase \(phaseError)")
                XCTAssertLessThan(maximum, 1e-6)
                XCTAssertLessThan(phaseError, 1e-12)
            }
        }
    }

    // MARK: - PA transfer curve

    func testPATransferMatchesCPU() throws {
        let accelerator = try requireAccelerator()
        let profile = TVChainProfile.full
        for system in TerrestrialSystem.allCases {
            let input = try modulatedInput(system)
            // The sound transmitter drives its PA with the vision power array, so
            // the resampled cross-compression term is a real code path, not a
            // constant.
            let varying = (0..<(input.i.count/4)).map { 0.5 + 0.5*Float(sin(Double($0)*0.001)) }
            for configuration in [(backoff: Float(6), hardness: Float(0.5), phase: Float(0), coupling: Float(0), other: []),
                                  (backoff: Float(0), hardness: Float(1), phase: Float(5), coupling: Float(0), other: []),
                                  (backoff: Float(12), hardness: Float(0.25), phase: Float(-5), coupling: Float(0.1), other: [1]),
                                  (backoff: Float(6), hardness: Float(0.5), phase: Float(0), coupling: Float(0.2), other: varying)] {
                var settings = TVTransmitterSettings()
                settings.enabled = true
                settings.backoffDB = configuration.backoff
                settings.hardness = configuration.hardness
                settings.phaseDegrees = configuration.phase
                settings.sharedCoupling = configuration.coupling
                let other = configuration.other
                var amplifier = TVTransmitterAmplifier()
                let expected = amplifier.apply(i: input.i, q: input.q, settings: settings,
                                               execution: .accelerated, otherPower: other, profile: profile)
                guard let pa = accelerator.makeTransmitterPA(settings: settings,
                                                             tablePoints: profile.amplifierTablePoints,
                                                             antialiasRadius: profile.amplifierAntiAliasRadius) else {
                    return XCTFail("PA did not build")
                }
                let actual = try XCTUnwrap(pa.apply(i: input.i, q: input.q, otherPower: other))
                let maximum = max(maximumError(actual.i, expected.0), maximumError(actual.q, expected.1))
                let expectedPeak = Double(amplifier.peakDrivePower), actualPeak = Double(pa.peakDrivePower)
                let peakError = abs(actualPeak-expectedPeak)/max(abs(expectedPeak), 1e-30)
                print("paTransfer \(system.rawValue) backoff \(configuration.backoff)"
                      + " hardness \(configuration.hardness) phase \(configuration.phase)"
                      + " coupling \(configuration.coupling) other \(other.count):"
                      + " max |error| \(maximum), peak \(expectedPeak) vs \(actualPeak)"
                      + " (\(peakError) relative)")
                XCTAssertEqual(actual.i.count, expected.0.count)
                XCTAssertLessThan(maximum, 1e-5)
                XCTAssertLessThan(peakError, 1e-4)
            }
        }
    }

    // MARK: - Gaussian noise

    func testGaussianNoiseDistribution() throws {
        let accelerator = try requireAccelerator()
        for system in TerrestrialSystem.allCases {
            let count = frameCount(system)
            let noise = try XCTUnwrap(accelerator.gaussianNoise(seed: 42, count: count))
            XCTAssertEqual(noise.i.count, count)
            XCTAssertEqual(noise.q.count, count)
            XCTAssertTrue(noise.i.allSatisfy(\.isFinite) && noise.q.allSatisfy(\.isFinite))
            for (name, component) in [("i", noise.i), ("q", noise.q)] {
                let mean = component.reduce(0,+)/Float(count)
                let variance = component.reduce(0) { $0 + ($1-mean)*($1-mean) }/Float(count)
                var correlation: Float = 0
                for n in 1..<count { correlation += (component[n]-mean)*(component[n-1]-mean) }
                correlation /= Float(count)*variance
                print("gaussianNoise \(system.rawValue) \(name): mean \(mean), variance \(variance), lag-1 rho \(correlation)")
                XCTAssertLessThan(abs(mean), 0.01)
                XCTAssertLessThan(abs(variance-1), 0.03)
                XCTAssertLessThan(abs(correlation), 0.02)
            }
            // The same hash and transform the channel evaluates: identical
            // constants must give the same stream when indexed the same way.
            let reference = ReferenceNoise.generate(seed: 42, count: count, indexBase: 0)
            let error = max(maximumError(noise.i, reference.i), maximumError(noise.q, reference.q))
            print("gaussianNoise \(system.rawValue) vs reference hash: max |error| \(error)")
            XCTAssertLessThan(error, 1e-3)
            // Splitting a stream at an absolute index must not change it.
            let half = count/2
            let first = try XCTUnwrap(accelerator.gaussianNoise(seed: 42, count: half, indexBase: 0))
            let second = try XCTUnwrap(accelerator.gaussianNoise(seed: 42, count: count-half, indexBase: Int64(half)))
            XCTAssertEqual(first.i, Array(noise.i[..<half]))
            XCTAssertEqual(second.i, Array(noise.i[half...]))
            XCTAssertEqual(second.q, Array(noise.q[half...]))
        }
    }

    // MARK: - Cost

    private func milliseconds(_ duration: Duration) -> Double {
        let parts = duration.components
        return (Double(parts.seconds) + Double(parts.attoseconds)/1e18)*1e3
    }

    /// Fastest of a warm-up call plus `iterations` timed ones. The minimum is
    /// the stable statistic here: each stage is short enough that a first call
    /// after a CPU-bound stage pays for the GPU's power state, and that is a
    /// property of the sequencing rather than of the kernel.
    private func timed(_ iterations: Int = 5, _ body: () -> Void) -> Double {
        body()
        let clock = ContinuousClock()
        var best = Double.infinity
        for _ in 0..<iterations {
            let start = clock.now
            body()
            best = min(best, milliseconds(start.duration(to: clock.now)))
        }
        return best
    }

    /// Fastest of a short burst and then of a long one. The gap between the two
    /// is the GPU clock ramping under load: a stage that runs alone for a few
    /// hundred microseconds, as it would between two frames, does not reach the
    /// sustained rate, so a Metal backend has to keep the GPU busy to see the
    /// second number.
    private func profile(_ body: () -> Void) -> (burst: Double, sustained: Double) {
        let clock = ContinuousClock()
        var burst = Double.infinity, sustained = Double.infinity
        body()
        for _ in 0..<5 {
            let start = clock.now
            body()
            burst = min(burst, milliseconds(start.duration(to: clock.now)))
        }
        for _ in 0..<40 {
            let start = clock.now
            body()
            sustained = min(sustained, milliseconds(start.duration(to: clock.now)))
        }
        return (burst, min(burst, sustained))
    }

    /// Bandwidth of a `MTLStorageModeShared` buffer written and read straight
    /// through `contents()`, i.e. the floor the zero-copy path is limited by.
    private func hostTransfer(count: Int, device: MTLDevice) -> (write: Double, read: Double, megabytes: Double) {
        let bytes = count*MemoryLayout<Float>.stride
        guard let buffer = device.makeBuffer(length: bytes, options: .storageModeShared) else { return (0, 0, 0) }
        let source = [Float](repeating: 0.5, count: count)
        var destination = [Float](repeating: 0, count: count)
        let write = timed {
            source.withUnsafeBytes { source in
                buffer.contents().copyMemory(from: source.baseAddress!, byteCount: bytes)
            }
        }
        let read = timed {
            _ = destination.withUnsafeMutableBytes { destination in
                memcpy(destination.baseAddress!, buffer.contents(), bytes)
            }
        }
        return (write, read, Double(bytes)/1e6)
    }

    func testKernelTiming() throws {
        let accelerator = try requireAccelerator()
        print("Metal device: \(accelerator.deviceName)")
        print("one-off shader compilation: \(accelerator.shaderCompilationSeconds*1e3) ms,"
              + " pipeline states: \(accelerator.pipelineSetupSeconds*1e3) ms")
        print("GPU columns are the fastest call of a short burst and of a long one;"
              + " both include the host write and the readback.")
        guard let device = MTLCreateSystemDefaultDevice() else { return XCTFail("no device") }
        for system in TerrestrialSystem.allCases {
            let count = frameCount(system)
            let frames = count*2
            let signal = noiseLikeInput(count: frames)
            let envelope = Array(signal.i[..<count])
            let input = try modulatedInput(system)
            let (kernelReal, kernelImaginary) = vsbKernels(system)
            let transfer = hostTransfer(count: frames, device: device)
            print("--- \(system.rawValue), \(count) samples/frame; shared-buffer copy of"
                  + " \(transfer.megabytes) MB: write \(transfer.write) ms, read \(transfer.read) ms")
            // FIR: the two VSB filters over one envelope, all of it on both sides.
            var filters = [TelevisionFIR(kernelReal), TelevisionFIR(kernelImaginary)]
            guard let bank = accelerator.makeFIRBank([.init(kernel: kernelReal, plane: 0),
                                                      .init(kernel: kernelImaginary, plane: 0)]) else {
                return XCTFail("bank")
            }
            let cpuFIR = timed {
                let result = TelevisionFIR.together(filters, inputs: [envelope, envelope], execution: .accelerated)
                filters = result.0
            }
            let gpuFIR = profile { _ = bank.process(planes: [envelope]) }
            // Control: the same buffers, planes, dispatches and readbacks with a
            // single-tap kernel, so it separates host traffic and dispatch from
            // the tap loop. One input plane is written and two output planes are
            // read, at the copy rate the shared-buffer measurement reports.
            guard let control = accelerator.makeFIRBank([.init(kernel: [1], plane: 0),
                                                         .init(kernel: [1], plane: 0)]) else {
                return XCTFail("control")
            }
            let gpuControl = profile { _ = control.process(planes: [envelope]) }
            print("complexFIR  \(kernelReal.count)+\(kernelImaginary.count) taps  CPU \(cpuFIR) ms"
                  + "  GPU \(gpuFIR.burst) ms burst / \(gpuFIR.sustained) ms sustained"
                  + "  (1-tap control \(gpuControl.sustained) ms; host traffic about"
                  + " \(String(format: "%.2f", 3*transfer.write)) ms of it)")
            // NCO: the companion shift on real frame IQ.
            let shiftHz = system == .palDK ? 5.5e6 : 4.5e6
            let step = -2*Double.pi*shiftHz/system.video.sampleRate
            var phase = 0.0
            let cpuNCO = timed {
                _ = ReferenceMixer.parallelMix(i: input.i, q: input.q, startPhase: phase, step: step)
                phase = (phase+step*Double(count)).truncatingRemainder(dividingBy: 2*Double.pi)
            }
            phase = 0
            let gpuNCO = profile {
                if let mixed = accelerator.ncoMix(i: input.i, q: input.q, startPhase: phase, step: step) {
                    phase = mixed.phase
                }
            }
            print("ncoMix      \(count) samples  CPU \(cpuNCO) ms"
                  + "  GPU \(gpuNCO.burst) ms burst / \(gpuNCO.sustained) ms sustained")
            // PA: the real transmitter settings, including the anti-alias decimator.
            var settings = TVTransmitterSettings()
            settings.enabled = true
            settings.hardness = 0.5
            var amplifier = TVTransmitterAmplifier()
            let chainProfile = TVChainProfile.full
            let cpuPA = timed {
                _ = amplifier.apply(i: input.i, q: input.q, settings: settings,
                                    execution: .accelerated, profile: chainProfile)
            }
            guard let pa = accelerator.makeTransmitterPA(settings: settings,
                                                         tablePoints: chainProfile.amplifierTablePoints,
                                                         antialiasRadius: chainProfile.amplifierAntiAliasRadius) else {
                return XCTFail("PA")
            }
            let gpuPA = profile { _ = pa.apply(i: input.i, q: input.q) }
            print("paTransfer  2x curve + \(2*chainProfile.amplifierAntiAliasRadius+1) tap decimation"
                  + "  CPU \(cpuPA) ms  GPU \(gpuPA.burst) ms burst / \(gpuPA.sustained) ms sustained")
            // Noise: the accelerated CPU path the engine uses, plus the serial
            // reference the distribution is defined by.
            let cpuNoise = timed {
                _ = ReferenceNoise.parallel(seed: 42, count: count, indexBase: 0)
            }
            let cpuNoiseSerial = timed {
                _ = ReferenceNoise.generate(seed: 42, count: count, indexBase: 0)
            }
            let gpuNoise = profile { _ = accelerator.gaussianNoise(seed: 42, count: count) }
            print("gaussianNoise \(count) samples  CPU \(cpuNoise) ms parallel /"
                  + " \(cpuNoiseSerial) ms serial  GPU \(gpuNoise.burst) ms burst /"
                  + " \(gpuNoise.sustained) ms sustained")
        }
    }
}
#endif
