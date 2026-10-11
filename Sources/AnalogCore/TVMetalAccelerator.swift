#if canImport(Metal)
import Foundation
import Metal

/// The Metal implementation of the four dense, data-parallel DSP stages of the
/// analogue chain: the real FIR (vision VSB and receiver IF), the NCO complex
/// mixer, the transmitter PA transfer curve and the RF thermal-noise generator.
///
/// Storage is deliberately `MTLStorageModeShared` everywhere: the CPU writes
/// inputs through `contents()` and reads outputs back the same way, so nothing
/// is copied or blitted by the GPU and the measured cost is the cost a caller
/// into the existing chain would actually pay. Every device buffer is allocated
/// on first use at a given length and reused afterwards, so a steady-state
/// frame path allocates nothing on the GPU side; only the returned arrays are
/// new, exactly as the CPU entry points return new arrays.
///
/// The kernels carry a history region per filter, exactly like the CPU
/// `TelevisionFIR`, so a bank can be spliced frame to frame. One instance is
/// intended to be kept by the caller and reused for every frame; it is not
/// reentrant and must be driven from one thread at a time.
///
/// Reference: `TVChainProfile`, `TelevisionFIR.process`/`decimate`,
/// `TVTunerWork`, `TVPASamples.process` and `TVNoiseBlock`.
public final class TVMetalAccelerator: @unchecked Sendable {
    /// The compute pipelines compiled from the runtime source.
    fileprivate enum Pipeline: Int, CaseIterable {
        case complexFIR, ncoMix, paTransfer, gaussianNoise
    }
    /// One-off wall time of `makeLibrary(source:options:)` plus the four
    /// `makeFunction` lookups. Reported so the caller can judge whether a Metal
    /// backend is affordable for a short-lived session.
    public let shaderCompilationSeconds: Double
    /// One-off wall time of the four `makeComputePipelineState` calls, which is
    /// a second distinct cost after the source has been compiled.
    public let pipelineSetupSeconds: Double
    public let deviceName: String
    fileprivate let device: MTLDevice
    fileprivate let queue: MTLCommandQueue
    fileprivate var pipelines = [MTLComputePipelineState]()
    /// Rotation atoms of the NCO, rewritten per call and read by exactly one
    /// dispatch, so sharing the buffer across calls cannot race.
    fileprivate let ncoPowers: MTLBuffer

    /// Fails when the process has no Metal device, when the runtime compiler
    /// rejects the kernel source, or when the device cannot build the pipelines.
    /// Callers treat a nil engine as "use the CPU path".
    public init?() {
        guard let device = MTLCreateSystemDefaultDevice(),
              let queue = device.makeCommandQueue() else { return nil }
        let compilation = ContinuousClock.now
        guard let library = try? device.makeLibrary(source: Self.kernelSource, options: nil) else { return nil }
        var functions = [MTLFunction]()
        functions.reserveCapacity(Pipeline.allCases.count)
        for name in Self.functionNames {
            guard let function = library.makeFunction(name: name) else { return nil }
            functions.append(function)
        }
        shaderCompilationSeconds = Self.seconds(compilation.duration(to: .now))
        let setup = ContinuousClock.now
        var built = [MTLComputePipelineState]()
        built.reserveCapacity(functions.count)
        for function in functions {
            guard let pipeline = try? device.makeComputePipelineState(function: function) else { return nil }
            built.append(pipeline)
        }
        pipelineSetupSeconds = Self.seconds(setup.duration(to: .now))
        let atoms = (1 + Self.stepBits + Self.maximumBlockBits) * MemoryLayout<SIMD2<Float>>.stride
        guard let powers = device.makeBuffer(length: atoms, options: .storageModeShared) else { return nil }
        self.device = device
        self.queue = queue
        self.deviceName = device.name
        self.ncoPowers = powers
        pipelines = built
    }

    /// Lazily created process-wide engine. Nil when Metal is unavailable, which
    /// is the same signal `init?()` gives.
    public static let shared: TVMetalAccelerator? = TVMetalAccelerator()

    fileprivate static func seconds(_ duration: Duration) -> Double {
        let parts = duration.components
        return Double(parts.seconds) + Double(parts.attoseconds) / 1e18
    }

    /// Number of rotation atoms the NCO decomposes a sample index into. The
    /// Metal source hardcodes the same split: sample indices shift by 10, the
    /// per-step powers start at atom 1 and the per-block powers at atom 11.
    fileprivate static let stepBits = 10
    /// Block size of the coarse rotation table, i.e. 1 << stepBits samples.
    fileprivate static let maximumBlockBits = 22

    // MARK: - Complex FIR

    /// A bank of real FIRs over one or more input planes, with one causal
    /// history region per filter. Descriptors that name the same plane share
    /// the uploaded input, so the receiver IF's four filters cost two writes.
    public final class FIRBank: @unchecked Sendable {
        private struct Slot {
            var kernel: [Float]
            var plane: Int
            var taps: Int
            var base: Int
        }
        private struct Plane {
            var buffer: MTLBuffer?
            var capacity = 0
            var base = 0
            var used = false
        }
        private struct Output {
            var buffer: MTLBuffer?
            var capacity = 0
        }
        private let accelerator: TVMetalAccelerator
        private var slots: [Slot]
        private var planes: [Plane]
        private var outputs: [Output]

        fileprivate init?(accelerator: TVMetalAccelerator, descriptors: [FIRDescriptor]) {
            guard !descriptors.isEmpty else { return nil }
            var slots = [Slot]()
            var planes = [Plane]()
            for descriptor in descriptors {
                guard !descriptor.kernel.isEmpty, descriptor.plane >= 0 else { return nil }
                while planes.count <= descriptor.plane { planes.append(Plane()) }
                planes[descriptor.plane].used = true
                // The GPU kernel walks the joined input forward, so the reversed
                // CPU kernel is uploaded once here instead of per frame.
                slots.append(Slot(kernel: descriptor.kernel.reversed(), plane: descriptor.plane,
                                  taps: descriptor.kernel.count, base: 0))
            }
            // One history region per filter on the plane, laid out ahead of the
            // single input region they share, so two filters over the same
            // signal cost one upload rather than two.
            var offsets = [Int](repeating: 0, count: planes.count)
            for index in slots.indices {
                slots[index].base = offsets[slots[index].plane]
                offsets[slots[index].plane] += slots[index].taps - 1
            }
            for plane in planes.indices where planes[plane].used { planes[plane].base = offsets[plane] }
            self.accelerator = accelerator
            self.slots = slots
            self.planes = planes
            self.outputs = [Output](repeating: Output(), count: slots.count)
        }

        /// Filters every plane and returns one output per descriptor, in
        /// descriptor order. `factor`/`phase` select the retained samples of a
        /// decimator; the retained phase of a full-rate pass is 0 and 1.
        /// The full-rate input history is kept in both cases, like the CPU's.
        public func process(planes input: [[Float]], factor: Int = 1, phase: Int = 0) -> [[Float]]? {
            guard factor > 0, phase >= 0,
                  let count = inputCount(input), count <= Int(UInt32.max) else { return nil }
            guard prepare(count: count, factor: factor, phase: phase) else { return nil }
            for plane in planes.indices where planes[plane].used {
                write(input[plane], into: plane, count: count)
            }
            guard let command = accelerator.queue.makeCommandBuffer() else { return nil }
            encode(into: command, count: count, factor: factor, phase: phase)
            command.commit()
            command.waitUntilCompleted()
            // A dispatch fault leaves the output buffers untouched, so a caller
            // must not read them as if the pass had run.
            guard command.error == nil else { return nil }
            return finish(count: count, factor: factor, phase: phase)
        }

        /// Drops all filter histories, so the next pass starts from silence.
        public func reset() {
            for index in planes.indices where planes[index].used {
                guard let buffer = planes[index].buffer else { continue }
                memset(buffer.contents(), 0, planes[index].base * MemoryLayout<Float>.stride)
            }
        }

        /// Buffer and float offset the caller must fill to feed one plane, so a
        /// producer on the GPU can write the FIR input in place. Nil when the
        /// plane is unused or the capacity does not cover the request.
        fileprivate func input(plane: Int, count: Int) -> (MTLBuffer, Int)? {
            guard plane < planes.count, planes[plane].used,
                  planes[plane].capacity >= planes[plane].base + count,
                  let buffer = planes[plane].buffer else { return nil }
            return (buffer, planes[plane].base)
        }

        /// Reserves the device buffers for one pass. Returns false when a plane
        /// index is unknown or a buffer cannot be built.
        fileprivate func prepare(count: Int, factor: Int, phase: Int) -> Bool {
            let produced = (count - phase + factor - 1)/factor
            guard produced > 0 else { return false }
            for plane in planes.indices where planes[plane].used {
                let needed = planes[plane].base + count
                if planes[plane].capacity < needed {
                    let target = Self.grow(needed)
                    guard let buffer = accelerator.device.makeBuffer(length: target*MemoryLayout<Float>.stride,
                                                                    options: .storageModeShared) else { return false }
                    planes[plane].buffer = buffer
                    planes[plane].capacity = target
                }
            }
            for index in slots.indices where outputs[index].capacity < produced {
                let target = Self.grow(produced)
                guard let buffer = accelerator.device.makeBuffer(length: target*MemoryLayout<Float>.stride,
                                                                options: .storageModeShared) else { return false }
                outputs[index].buffer = buffer
                outputs[index].capacity = target
            }
            return true
        }

        /// Encodes one dispatch per descriptor on the supplied command buffer,
        /// without touching the input regions: the caller has already written
        /// them, on the CPU or by an earlier kernel.
        fileprivate func encode(into command: MTLCommandBuffer, count: Int, factor: Int, phase: Int) {
            guard let encoder = command.makeComputeCommandEncoder() else { return }
            encoder.setComputePipelineState(accelerator.pipelines[Pipeline.complexFIR.rawValue])
            let produced = (count - phase + factor - 1)/factor
            for index in slots.indices {
                guard let plane = planes[slots[index].plane].buffer,
                      let output = outputs[index].buffer else { continue }
                var params = SIMD4<UInt32>(UInt32(slots[index].taps), UInt32(produced), UInt32(factor), UInt32(phase))
                var extra = SIMD4<UInt32>(UInt32(slots[index].base), UInt32(planes[slots[index].plane].base),
                                          UInt32(slots[index].taps - 1), 0)
                encoder.setBuffer(plane, offset: 0, index: 0)
                slots[index].kernel.withUnsafeBytes { taps in
                    encoder.setBytes(taps.baseAddress!, length: taps.count, index: 1)
                }
                encoder.setBuffer(output, offset: 0, index: 2)
                encoder.setBytes(&params, length: MemoryLayout<SIMD4<UInt32>>.size, index: 3)
                encoder.setBytes(&extra, length: MemoryLayout<SIMD4<UInt32>>.size, index: 4)
                encoder.dispatchThreadgroups(TVMetalAccelerator.grid(produced),
                                             threadsPerThreadgroup: TVMetalAccelerator.threadgroup)
            }
            encoder.endEncoding()
        }

        /// Splices each filter's history forward and returns its output.
        /// Only valid after the command buffer that encoded the pass completed.
        fileprivate func finish(count: Int, factor: Int, phase: Int) -> [[Float]] {
            let produced = (count - phase + factor - 1)/factor
            var result = [[Float]]()
            result.reserveCapacity(slots.count)
            for index in slots.indices {
                let history = slots[index].taps - 1
                if history > 0, let plane = planes[slots[index].plane].buffer {
                    let floats = plane.contents().bindMemory(to: Float.self, capacity: planes[slots[index].plane].capacity)
                    let input = planes[slots[index].plane].base
                    // The next history is the tail of this pass's joined range:
                    // the last input samples, plus whatever of the old history a
                    // pass shorter than the filter leaves at the front.
                    if count >= history {
                        memmove(floats + slots[index].base, floats + input + count - history,
                                history*MemoryLayout<Float>.stride)
                    } else {
                        memmove(floats + slots[index].base, floats + slots[index].base + count,
                                (history - count)*MemoryLayout<Float>.stride)
                        memcpy(floats + slots[index].base + history - count, floats + input,
                               count*MemoryLayout<Float>.stride)
                    }
                }
                var output = [Float](repeating: 0, count: produced)
                if let buffer = outputs[index].buffer {
                    _ = output.withUnsafeMutableBufferPointer { destination in
                        memcpy(destination.baseAddress!, buffer.contents(), produced*MemoryLayout<Float>.stride)
                    }
                }
                result.append(output)
            }
            return result
        }

        private func write(_ plane: [Float], into index: Int, count: Int) {
            guard let buffer = planes[index].buffer else { return }
            let floats = buffer.contents().bindMemory(to: Float.self, capacity: planes[index].capacity)
            _ = plane.withUnsafeBufferPointer { source in
                memcpy(floats + planes[index].base, source.baseAddress!, count*MemoryLayout<Float>.stride)
            }
        }

        private func inputCount(_ planes: [[Float]]) -> Int? {
            var count = -1
            for index in self.planes.indices where self.planes[index].used {
                guard index < planes.count else { return nil }
                if count < 0 { count = planes[index].count } else if planes[index].count != count { return nil }
            }
            return count > 0 ? count : nil
        }

        /// Rounds a required float count up so a chain with fixed frame lengths
        /// allocates its buffers once.
        private static func grow(_ needed: Int) -> Int {
            let quantum = 1 << 16
            return (needed + quantum - 1)/quantum*quantum
        }
    }

    /// One real kernel and the input plane it streams.
    public struct FIRDescriptor {
        public var kernel: [Float]
        public var plane: Int
        public init(kernel: [Float], plane: Int = 0) {
            self.kernel = kernel
            self.plane = plane
        }
    }

    public func makeFIRBank(_ descriptors: [FIRDescriptor]) -> FIRBank? {
        FIRBank(accelerator: self, descriptors: descriptors)
    }

    // MARK: - NCO complex mixing

    /// Rotates a complex block by `exp(i*(startPhase + step*n))`. The rotation
    /// is assembled per sample from stored rotation atoms instead of being
    /// integrated, so it does not drift with block length; the returned phase is
    /// the caller's next `startPhase`, reduced the same way the CPU reduces it.
    public func ncoMix(i: [Float], q: [Float], startPhase: Double,
                       step: Double) -> (i: [Float], q: [Float], phase: Double)? {
        let count = i.count
        // The kernels index the grid with a 32-bit thread id, and the coarse
        // rotation table covers every block of 1024 samples such a grid can hold.
        guard count > 0, count <= Int(UInt32.max), q.count == count,
              startPhase.isFinite, step.isFinite else { return nil }
        let blockBits = min(Self.maximumBlockBits, max(1, Int(ceil(log2(Double(count >> Self.stepBits) + 1)))))
        let atoms = ncoPowers.contents().bindMemory(to: SIMD2<Float>.self, capacity: ncoPowers.length/MemoryLayout<SIMD2<Float>>.stride)
        atoms[0] = SIMD2(Float(cos(startPhase)), Float(sin(startPhase)))
        let block = Double(1 << Self.stepBits)
        for bit in 0..<Self.stepBits {
            let angle = step*Double(1 << bit)
            atoms[1 + bit] = SIMD2(Float(cos(angle)), Float(sin(angle)))
        }
        for bit in 0..<blockBits {
            let angle = step*block*Double(1 << bit)
            atoms[1 + Self.stepBits + bit] = SIMD2(Float(cos(angle)), Float(sin(angle)))
        }
        guard let inputI = buffer(.ncoInputI, count: count), let inputQ = buffer(.ncoInputQ, count: count),
              let outputI = buffer(.ncoOutputI, count: count), let outputQ = buffer(.ncoOutputQ, count: count) else { return nil }
        inputI.contents().copyMemory(from: i, byteCount: count*MemoryLayout<Float>.stride)
        inputQ.contents().copyMemory(from: q, byteCount: count*MemoryLayout<Float>.stride)
        guard let command = queue.makeCommandBuffer(), let encoder = command.makeComputeCommandEncoder() else { return nil }
        encoder.setComputePipelineState(pipelines[Pipeline.ncoMix.rawValue])
        encoder.setBuffer(inputI, offset: 0, index: 0)
        encoder.setBuffer(inputQ, offset: 0, index: 1)
        encoder.setBuffer(outputI, offset: 0, index: 2)
        encoder.setBuffer(outputQ, offset: 0, index: 3)
        encoder.setBuffer(ncoPowers, offset: 0, index: 4)
        var params = SIMD4<UInt32>(UInt32(count), UInt32(blockBits), 0, 0)
        encoder.setBytes(&params, length: MemoryLayout<SIMD4<UInt32>>.size, index: 5)
        encoder.dispatchThreadgroups(Self.grid(count), threadsPerThreadgroup: Self.threadgroup)
        encoder.endEncoding()
        command.commit()
        command.waitUntilCompleted()
        guard command.error == nil else { return nil }
        let resultI = Self.read(outputI, count: count)
        let resultQ = Self.read(outputQ, count: count)
        let phase = (startPhase + step*Double(count)).truncatingRemainder(dividingBy: 2*Double.pi)
        return (resultI, resultQ, phase)
    }

    // MARK: - Thermal noise

    /// Independent complex Gaussian noise with unit variance per component.
    /// `indexBase` is the absolute channel index of the first sample, so two
    /// calls that cover adjacent ranges continue one stream.
    public func gaussianNoise(seed: UInt64, count: Int, indexBase: Int64 = 0,
                              scale: Float = 1) -> (i: [Float], q: [Float])? {
        guard count > 0, indexBase >= 0, indexBase + Int64(count) < Int64(UInt32.max) else { return nil }
        guard let outputI = buffer(.noiseOutputI, count: count),
              let outputQ = buffer(.noiseOutputQ, count: count) else { return nil }
        guard let command = queue.makeCommandBuffer(), let encoder = command.makeComputeCommandEncoder() else { return nil }
        encoder.setComputePipelineState(pipelines[Pipeline.gaussianNoise.rawValue])
        encoder.setBuffer(outputI, offset: 0, index: 0)
        encoder.setBuffer(outputQ, offset: 0, index: 1)
        var params = SIMD4<UInt32>(UInt32(count), UInt32(indexBase), UInt32(truncatingIfNeeded: seed),
                                   UInt32(truncatingIfNeeded: seed >> 32))
        var extra = SIMD4<UInt32>(scale.bitPattern, 0, 0, 0)
        encoder.setBytes(&params, length: MemoryLayout<SIMD4<UInt32>>.size, index: 2)
        encoder.setBytes(&extra, length: MemoryLayout<SIMD4<UInt32>>.size, index: 3)
        encoder.dispatchThreadgroups(Self.grid(count), threadsPerThreadgroup: Self.threadgroup)
        encoder.endEncoding()
        command.commit()
        command.waitUntilCompleted()
        guard command.error == nil else { return nil }
        return (Self.read(outputI, count: count), Self.read(outputQ, count: count))
    }

    // MARK: - Transmitter PA

    /// The 2x-evaluated memoryless PA curve plus its anti-alias decimator, over
    /// the same coefficient table and kernel the CPU amplifier builds. The table
    /// and the kernel are built once per instance, which is the one-off cost the
    /// caller pays for a settings change; `previous` carries the frame boundary
    /// exactly like `TVTransmitterAmplifier.previous`. Building the type fails
    /// when the transmitter is disabled, because the CPU path then bypasses the
    /// model entirely.
    public final class TransmitterPA: @unchecked Sendable {
        private let accelerator: TVMetalAccelerator
        private let settings: TVTransmitterSettings
        private let tablePoints: Int
        private let antialiasRadius: Int
        private let curve: MTLBuffer
        private let bank: FIRBank
        private var input: MTLBuffer?
        private var inputCapacity = 0
        private var other: MTLBuffer?
        private var otherCapacity = 0
        private var peak: MTLBuffer
        private var previous = SIMD2<Float>(0, 0)
        public private(set) var peakDrivePower: Float = 0

        fileprivate init?(accelerator: TVMetalAccelerator, settings: TVTransmitterSettings,
                          tablePoints: Int, antialiasRadius: Int) {
            guard tablePoints >= 16, tablePoints % 16 == 0, antialiasRadius >= 2, settings.enabled else { return nil }
            // Spanning normalized drive power 0...16 at tablePoints+1 points,
            // which is the table TVTransmitterAmplifier builds.
            var table = [SIMD2<Float>]()
            table.reserveCapacity(tablePoints + 1)
            for point in 0...tablePoints {
                table.append(TVTransmitterAmplifier.coefficient(power: Double(point)*16/Double(tablePoints),
                                                                settings: settings))
            }
            guard let curve = accelerator.device.makeBuffer(bytes: table,
                                                            length: table.count*MemoryLayout<SIMD2<Float>>.stride,
                                                            options: .storageModeShared) else { return nil }
            // Normalized sinc anti-alias kernel at the 2x rate, identical to the
            // one TVTransmitterAmplifier applies before decimating to 1x.
            let cutoff = 0.225
            var kernel = (-antialiasRadius...antialiasRadius).map { tap -> Float in
                let sinc = tap == 0 ? 2*cutoff
                    : sin(2*Double.pi*cutoff*Double(tap))/(Double.pi*Double(tap))
                let taper = 0.54 + 0.46*cos(Double.pi*Double(tap)/Double(antialiasRadius))
                return Float(sinc*taper)
            }
            let sum = kernel.reduce(0,+)
            for tap in kernel.indices { kernel[tap] /= sum }
            guard let bank = FIRBank(accelerator: accelerator,
                                     descriptors: [FIRDescriptor(kernel: kernel, plane: 0),
                                                   FIRDescriptor(kernel: kernel, plane: 1)]),
                  let peak = accelerator.device.makeBuffer(length: MemoryLayout<UInt32>.stride,
                                                           options: .storageModeShared) else { return nil }
            self.accelerator = accelerator
            self.settings = settings
            self.tablePoints = tablePoints
            self.antialiasRadius = antialiasRadius
            self.curve = curve
            self.bank = bank
            self.peak = peak
        }

        /// Applies the curve at 2x, decimates to 1x and returns the complex
        /// output. `otherPower` is the optional cross-compression drive term:
        /// one sample is a constant, several are resampled onto the input grid.
        public func apply(i: [Float], q: [Float], otherPower: [Float] = []) -> (i: [Float], q: [Float])? {
            let count = i.count
            guard count > 0, q.count == count, count <= Int(UInt32.max)/2 else { return nil }
            let doubled = count*2
            guard reserve(count: count, otherCount: max(1, otherPower.count)),
                  let input = input, let other = other,
                  bank.prepare(count: doubled, factor: 2, phase: 1) else { return nil }
            let planes = input.contents().bindMemory(to: Float.self, capacity: inputCapacity*2)
            _ = i.withUnsafeBufferPointer { source in
                memcpy(planes, source.baseAddress!, count*MemoryLayout<Float>.stride)
            }
            _ = q.withUnsafeBufferPointer { source in
                memcpy(planes + inputCapacity, source.baseAddress!, count*MemoryLayout<Float>.stride)
            }
            let drive = other.contents().bindMemory(to: Float.self, capacity: max(1, otherCapacity))
            if otherPower.isEmpty {
                drive[0] = 0
            } else {
                _ = otherPower.withUnsafeBufferPointer { source in
                    memcpy(drive, source.baseAddress!, otherPower.count*MemoryLayout<Float>.stride)
                }
            }
            peak.contents().bindMemory(to: UInt32.self, capacity: 1)[0] = 0
            guard let real = bank.input(plane: 0, count: doubled),
                  let imaginary = bank.input(plane: 1, count: doubled),
                  let command = accelerator.queue.makeCommandBuffer(),
                  let encoder = command.makeComputeCommandEncoder() else { return nil }
            encoder.setComputePipelineState(accelerator.pipelines[Pipeline.paTransfer.rawValue])
            encoder.setBuffer(input, offset: 0, index: 0)
            encoder.setBuffer(input, offset: inputCapacity*MemoryLayout<Float>.stride, index: 1)
            encoder.setBuffer(curve, offset: 0, index: 2)
            encoder.setBuffer(other, offset: 0, index: 3)
            encoder.setBuffer(real.0, offset: real.1*MemoryLayout<Float>.stride, index: 4)
            encoder.setBuffer(imaginary.0, offset: imaginary.1*MemoryLayout<Float>.stride, index: 5)
            encoder.setBuffer(peak, offset: 0, index: 6)
            var params = SIMD4<UInt32>(UInt32(count), UInt32(tablePoints),
                                       UInt32(max(1, otherPower.count)), otherPower.count > 1 ? 1 : 0)
            var extra = SIMD4<UInt32>(Float(tablePoints/16).bitPattern, Float(2*settings.sharedCoupling).bitPattern,
                                      previous.x.bitPattern, previous.y.bitPattern)
            encoder.setBytes(&params, length: MemoryLayout<SIMD4<UInt32>>.size, index: 7)
            encoder.setBytes(&extra, length: MemoryLayout<SIMD4<UInt32>>.size, index: 8)
            encoder.dispatchThreadgroups(TVMetalAccelerator.grid(count),
                                         threadsPerThreadgroup: TVMetalAccelerator.threadgroup)
            encoder.endEncoding()
            bank.encode(into: command, count: doubled, factor: 2, phase: 1)
            command.commit()
            command.waitUntilCompleted()
            guard command.error == nil else { return nil }
            peakDrivePower = Float(bitPattern: peak.contents().bindMemory(to: UInt32.self, capacity: 1)[0])
            previous = SIMD2(i[count-1], q[count-1])
            let output = bank.finish(count: doubled, factor: 2, phase: 1)
            guard output.count == 2 else { return nil }
            return (output[0], output[1])
        }

        /// Drops the frame-boundary sample and both anti-alias filter histories.
        public func reset() {
            previous = SIMD2(0, 0)
            peakDrivePower = 0
            bank.reset()
        }

        private func reserve(count: Int, otherCount: Int) -> Bool {
            let needed = Self.grow(count)
            if inputCapacity < count {
                guard let buffer = accelerator.device.makeBuffer(length: needed*2*MemoryLayout<Float>.stride,
                                                                 options: .storageModeShared) else { return false }
                input = buffer
                inputCapacity = needed
            }
            if otherCapacity < otherCount {
                guard let buffer = accelerator.device.makeBuffer(length: Self.grow(otherCount)*MemoryLayout<Float>.stride,
                                                                 options: .storageModeShared) else { return false }
                other = buffer
                otherCapacity = Self.grow(otherCount)
            }
            return true
        }

        private static func grow(_ needed: Int) -> Int {
            let quantum = 1 << 16
            return (needed + quantum - 1)/quantum*quantum
        }
    }

    public func makeTransmitterPA(settings: TVTransmitterSettings, tablePoints: Int = 8192,
                                 antialiasRadius: Int = 12) -> TransmitterPA? {
        TransmitterPA(accelerator: self, settings: settings, tablePoints: tablePoints,
                      antialiasRadius: antialiasRadius)
    }

    // MARK: - Shared plumbing

    /// Scratch buffers behind the kernels that run a single dispatch per call.
    /// Each role has its own buffer so nothing is read and written by the same
    /// dispatch, and the length only ever grows, so a chain with fixed frame
    /// lengths allocates once.
    private enum Scratch: Int, CaseIterable {
        case ncoInputI, ncoInputQ, ncoOutputI, ncoOutputQ, noiseOutputI, noiseOutputQ
    }
    private var scratch = [MTLBuffer?](repeating: nil, count: Scratch.allCases.count)

    private func buffer(_ role: Scratch, count: Int) -> MTLBuffer? {
        let length = count*MemoryLayout<Float>.stride
        if let existing = scratch[role.rawValue], existing.length >= length { return existing }
        guard let created = device.makeBuffer(length: length, options: .storageModeShared) else { return nil }
        scratch[role.rawValue] = created
        return created
    }

    fileprivate static func read(_ buffer: MTLBuffer, count: Int) -> [Float] {
        var result = [Float](repeating: 0, count: count)
        _ = result.withUnsafeMutableBufferPointer { destination in
            memcpy(destination.baseAddress!, buffer.contents(), count*MemoryLayout<Float>.stride)
        }
        return result
    }

    fileprivate static let threadgroup = MTLSize(width: 256, height: 1, depth: 1)
    fileprivate static func grid(_ count: Int) -> MTLSize {
        MTLSize(width: (count + 255)/256, height: 1, depth: 1)
    }

    private static let functionNames = ["complexFIR", "ncoMix", "paTransfer", "gaussianNoise"]

    /// Kernels are compiled at runtime so the prototype needs no .metal file,
    /// no build-system change and no Xcode target of its own. Every bound is a
    /// uniform: no kernel assumes a frame length, a filter count or a standard.
    private static let kernelSource = #"""
    #include <metal_stdlib>
    using namespace metal;

    inline float2 tvComplexMultiply(float2 a, float2 b) {
        return float2(a.x*b.x - a.y*b.y, a.x*b.y + a.y*b.x);
    }

    /// Bit-pattern maximum: drive power is non-negative, so float ordering
    /// matches unsigned ordering and the reduction is exact.
    inline void tvAtomicMaxFloat(device atomic_uint* target, float value) {
        atomic_fetch_max_explicit(target, as_type<uint>(value), memory_order_relaxed);
    }

    /// Counter-based uniform stream, the splitmix64 finalizer the CPU noise
    /// generator uses with the same per-index multipliers.
    inline float tvUniform(ulong state) {
        ulong z = state;
        z = (z ^ (z >> 30)) * 0xbf58476d1ce4e5b9UL;
        z = (z ^ (z >> 27)) * 0x94d049bb133111ebUL;
        return float((z ^ (z >> 31)) >> 40) * (1.0f / 16777216.0f);
    }

    /// Causal FIR over one plane. The bound buffer holds one history region per
    /// filter and one input region shared by every filter on the plane, so a
    /// filter's joined history/input range is addressed as two extents rather
    /// than contiguously. The CPU kernel is uploaded reversed, so output sample
    /// n is its correlation with that joined range.
    kernel void complexFIR(device const float* buffer [[buffer(0)]],
                           device const float* tapsReversed [[buffer(1)]],
                           device float* output [[buffer(2)]],
                           constant uint4& params [[buffer(3)]],
                           constant uint4& extra [[buffer(4)]],
                           uint gid [[thread_position_in_grid]]) {
        uint taps = params.x, count = params.y, factor = params.z, phase = params.w;
        uint historyOffset = extra.x, inputOffset = extra.y, historyLength = extra.z;
        if (gid >= count || taps == 0) { return; }
        uint start = phase + gid*factor;
        // Leading taps of this output still lie inside the causal history.
        uint boundary = start < historyLength ? min(taps, historyLength - start) : 0u;
        float sum = 0.0f;
        for (uint tap = 0; tap < boundary; ++tap) {
            sum += buffer[historyOffset + start + tap]*tapsReversed[tap];
        }
        for (uint tap = boundary; tap < taps; ++tap) {
            sum += buffer[inputOffset + start + tap - historyLength]*tapsReversed[tap];
        }
        output[gid] = sum;
    }

    /// Complex rotation by exp(i*(startPhase + step*n)), assembled per sample
    /// from rotation atoms: u0, the first ten powers of exp(i*step), and the
    /// first powers of exp(i*step*1024). Every atom is exact to a float, so the
    /// rotation does not drift the way an integrated recurrence does.
    kernel void ncoMix(device const float* inI [[buffer(0)]],
                       device const float* inQ [[buffer(1)]],
                       device float* outI [[buffer(2)]],
                       device float* outQ [[buffer(3)]],
                       constant float2* atoms [[buffer(4)]],
                       constant uint4& params [[buffer(5)]],
                       uint gid [[thread_position_in_grid]]) {
        uint count = params.x, blockBits = params.y;
        if (gid >= count) { return; }
        constant float2* stepPowers = atoms + 1;
        constant float2* blockPowers = atoms + 11;
        uint block = gid >> 10, offset = gid & 1023u;
        float2 rotation = atoms[0];
        for (uint bit = 0; bit < blockBits; ++bit) {
            if (((block >> bit) & 1u) != 0u) { rotation = tvComplexMultiply(rotation, blockPowers[bit]); }
        }
        for (uint bit = 0; bit < 10u; ++bit) {
            if (((offset >> bit) & 1u) != 0u) { rotation = tvComplexMultiply(rotation, stepPowers[bit]); }
        }
        float2 sample = float2(inI[gid], inQ[gid]);
        outI[gid] = rotation.x*sample.x - rotation.y*sample.y;
        outQ[gid] = rotation.x*sample.y + rotation.y*sample.x;
    }

    /// The memoryless PA curve at twice the input rate: the midpoint and the
    /// sample itself, linearly interpolated over the normalized drive-power
    /// table, complex-multiplied and interleaved into the 2x buffers that the
    /// anti-alias decimator reads. Peak drive power is reduced across the grid.
    ///
    /// The interpolation coordinate and the resampled cross-compression index
    /// are evaluated in single precision; the CPU evaluates both in double. The
    /// table interpolates, so the coordinate moves the last bits of the curve,
    /// and the index can differ by one cell only when the double product lands
    /// within a rounding step of a cell boundary.
    kernel void paTransfer(device const float* inI [[buffer(0)]],
                           device const float* inQ [[buffer(1)]],
                           device const float2* curve [[buffer(2)]],
                           device const float* other [[buffer(3)]],
                           device float* outI [[buffer(4)]],
                           device float* outQ [[buffer(5)]],
                           device atomic_uint* peak [[buffer(6)]],
                           constant uint4& params [[buffer(7)]],
                           constant uint4& extra [[buffer(8)]],
                           uint gid [[thread_position_in_grid]]) {
        uint count = params.x, tablePoints = params.y, otherCount = params.z, resampled = params.w;
        if (gid >= count) { return; }
        float tableScale = as_type<float>(extra.x);
        float coupling = as_type<float>(extra.y);
        float2 previous = float2(as_type<float>(extra.z), as_type<float>(extra.w));
        float2 current = float2(inI[gid], inQ[gid]);
        float2 prior = gid == 0 ? previous : float2(inI[gid - 1], inQ[gid - 1]);
        float external = coupling*other[0];
        if (resampled != 0u) {
            uint index = min(otherCount - 1, uint(float(gid)*float(otherCount)/float(count)));
            external = coupling*other[index];
        }
        float peakPower = 0.0f;
        for (uint stage = 0; stage < 2u; ++stage) {
            float2 x = stage == 0u ? (prior + current)*0.5f : current;
            float power = x.x*x.x + x.y*x.y + external;
            peakPower = max(peakPower, power);
            float position = clamp(power*tableScale, 0.0f, float(tablePoints));
            uint index = min(tablePoints - 1u, uint(position));
            float2 coefficient = curve[index] + (curve[index + 1] - curve[index])*(position - float(index));
            outI[gid*2 + stage] = x.x*coefficient.x - x.y*coefficient.y;
            outQ[gid*2 + stage] = x.x*coefficient.y + x.y*coefficient.x;
        }
        tvAtomicMaxFloat(peak, peakPower);
    }

    /// Box-Muller complex noise, unit variance per component: the radius comes
    /// from one uniform and the angle from an independent one, so the two
    /// components are independent and neither is correlated with its neighbour.
    kernel void gaussianNoise(device float* outI [[buffer(0)]],
                              device float* outQ [[buffer(1)]],
                              constant uint4& params [[buffer(2)]],
                              constant uint4& extra [[buffer(3)]],
                              uint gid [[thread_position_in_grid]]) {
        uint count = params.x;
        if (gid >= count) { return; }
        ulong seed = (ulong(params.w) << 32) | ulong(params.z);
        ulong index = (ulong(params.y) + ulong(gid));
        float radius = tvUniform(seed + index*0x9e3779b97f4a7c15UL);
        float angle = tvUniform(seed + index*0xd1b54a32d192ed03UL);
        float length = sqrt(-2.0f*log(max(1e-7f, radius)))*as_type<float>(extra.x);
        float phase = 2.0f*M_PI_F*angle;
        float cosine;
        float sine = sincos(phase, cosine);
        outI[gid] = length*cosine;
        outQ[gid] = length*sine;
    }
    """#
}
#endif
