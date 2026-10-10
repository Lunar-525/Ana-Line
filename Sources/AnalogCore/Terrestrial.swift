import Foundation
import Accelerate
import Dispatch

/// Analogue RF profiles with VSB vision and a primary mono FM sound carrier.
public enum TerrestrialSystem: String, CaseIterable, Codable, Sendable {
    case palDK = "PAL-D/K", ntscM = "NTSC-M"
    public var video: TVStandard { self == .palDK ? .pal : .ntsc }
    public var channelMHz: Float { self == .palDK ? 8 : 6 }
    public var videoMHz: Double { self == .palDK ? 6 : 4.2 }
    public var vestigeMHz: Double { 0.75 }
    public init(video: TVStandard) { self = video == .pal ? .palDK : .ntscM }
}

public struct TerrestrialSettings: Codable, Equatable, Sendable {
    /// Diagnostic scalar path for verifying accelerated numerical results.
    public var execution: TVExecution = .accelerated
    public var signalDB: Float = 0
    /// Noise referenced to the unattenuated vision carrier, in the RF sampling bandwidth.
    public var carrierToNoiseDB: Float = 45
    public var rfBandwidthMHz: Float = 8
    public var echoGain: Float = 0
    public var echoDelayMicroseconds: Float = 2
    /// Total relative phase at the vision carrier, including propagation and reflection.
    public var echoPhaseDegrees: Float = 0
    public var tuningOffsetKHz: Float = 0
    public var automaticFineTuning = true
    public var automaticGain = true
    public var manualGainDB: Float = 0
    public var seed: UInt64 = 42
    public var propagation = TVPropagationSettings()
    public var transmitter = TVTransmitterSettings()
    public var receiverDamage = TVReceiverDamageSettings()
    public var decoder = TVDecoderSettings()
    public init() {}
    public init(system: TerrestrialSystem) { rfBandwidthMHz = system.channelMHz }
    public func validate(rate: Double) throws {
        try propagation.validate(); try transmitter.validate(); try receiverDamage.validate(); try decoder.validate()
        let values = [signalDB, carrierToNoiseDB, rfBandwidthMHz, echoGain,
                      echoDelayMicroseconds, echoPhaseDegrees, tuningOffsetKHz, manualGainDB]
        guard values.allSatisfy(\.isFinite), (-80...20).contains(signalDB),
              (0...120).contains(carrierToNoiseDB), (0.5...10).contains(rfBandwidthMHz),
              (0...1).contains(echoGain), (0...40).contains(echoDelayMicroseconds),
              (-180...180).contains(echoPhaseDegrees), (-2000...2000).contains(tuningOffsetKHz),
              (-20...80).contains(manualGainDB), rate > 0 else { throw TVError.invalidSettings }
    }
}

/// Complex envelope around the vision carrier; the GHz/MHz carrier need not be sampled.
public struct TelevisionRF: Sendable {
    public let system: TerrestrialSystem
    public let frameIndex: Int64
    public let sampleRate: Double
    public var i: [Float]
    public var q: [Float]
    func validate() throws {
        guard frameIndex >= 0, frameIndex < 1_000_000_000,
              sampleRate == system.video.sampleRate,
              i.count == Int(system.video.sampleOffset(frame: frameIndex+1)-system.video.sampleOffset(frame: frameIndex)),
              i.count == q.count, i.allSatisfy(\.isFinite), q.allSatisfy(\.isFinite) else {
            throw TVError.invalidSignal
        }
    }
}

public enum TelevisionLock: String, Sendable { case searching, locked, holding }
public struct TelevisionSynchronization: Equatable, Sendable {
    public var horizontal: TelevisionLock = .searching
    public var vertical: TelevisionLock = .searching
    public var color: TelevisionLock = .searching
    public init() {}
}
public struct TerrestrialTimings: Sendable {
    public var modulation: Double = 0
    public var channel: Double = 0
    public var tuner: Double = 0
    public var carrier: Double = 0
    public var carrierEstimation: Double = 0
    public var carrierPLL: Double = 0
    public var synchronization: Double = 0
    public var videoDecode: Double = 0
    static func seconds(_ duration: Duration) -> Double {
        let c = duration.components
        return Double(c.seconds) + Double(c.attoseconds) / 1e18
    }
}
public struct TerrestrialReception: Sendable {
    public let frame: TVFrame
    public let lock: TelevisionLock
    public let recoveredLines: Int
    public let colorLockedLines: Int
    public let agcDB: Float
    public let carrierErrorHz: Double
    public let syncConfidence: Float
    public var timings = TerrestrialTimings()
    public var audio = [Float]()
    public var soundCarrierDB: Float = -120
    public var soundSeconds: Double = 0
    public var synchronization = TelevisionSynchronization()
    public var visionSpectrum: TVSpectrum?
    public var soundSpectrum: TVSpectrum?
    public var transmitter = TVTransmitterTelemetry()
    public var lightningEvents = [TVLightningEvent]()
}

/// A causal, streaming FIR. State survives block boundaries, including between frames.
struct TelevisionFIR: Sendable {
    var kernel: [Float]
    var history: [Float]
    init(_ kernel: [Float]) { self.kernel = kernel; history = .init(repeating: 0, count: kernel.count - 1) }
    mutating func process(_ input: [Float], chunks: Int = 1) -> [Float] {
        guard !input.isEmpty else { return [] }
        let joined = history + input
        let reversed = Array(kernel.reversed())
        var output = [Float](repeating: 0, count: input.count)
        joined.withUnsafeBufferPointer { x in
            reversed.withUnsafeBufferPointer { k in
                output.withUnsafeMutableBufferPointer { y in
                    let convolution = TelevisionConvolution(input: x,kernel: k,output: y)
                    let workers = min(chunks,max(1,input.count/131_072))
                    if workers > 1 {
                        DispatchQueue.concurrentPerform(iterations: workers) { worker in
                            convolution.run(worker*input.count/workers..<(worker+1)*input.count/workers)
                        }
                    } else { convolution.run(0..<input.count) }
                }
            }
        }
        history = Array(joined.suffix(kernel.count - 1))
        return output
    }
    /// Same causal FIR, evaluated only at the retained phase of a decimator.
    /// Input history is kept at the original sampling rate.
    mutating func decimate(_ input: [Float], factor: Int, phase: Int) -> [Float] {
        guard !input.isEmpty else { return [] }
        let joined = history + input, reversed = Array(kernel.reversed())
        let count = (input.count-phase+factor-1)/factor
        var output = [Float](repeating: 0,count: count)
        joined.withUnsafeBufferPointer { x in reversed.withUnsafeBufferPointer { k in
            output.withUnsafeMutableBufferPointer { y in
                vDSP_desamp(x.baseAddress!+phase,vDSP_Stride(factor),k.baseAddress!,y.baseAddress!,
                    vDSP_Length(count),vDSP_Length(kernel.count))
            }
        } }
        history = Array(joined.suffix(kernel.count-1))
        return output
    }
    static func together(_ filters: [TelevisionFIR], inputs: [[Float]], execution: TVExecution) -> ([TelevisionFIR], [[Float]]) {
        let work = zip(filters,inputs).map { TelevisionFilterWork(filter: $0.0,input: $0.1) }
        if execution == .accelerated {
            DispatchQueue.concurrentPerform(iterations: work.count) { work[$0].run(chunks: 2) }
        } else { for item in work { item.run() } }
        return (work.map { $0.filter },work.map { $0.output })
    }
    /// Windowed inverse Fourier design; H is real but may be asymmetric in frequency.
    static func complexKernel(rate: Double, radius: Int = 48, normalizationHz: Double = 0, normalize: Bool = true,
                              phase: ((Double) -> Double)? = nil,
                              response: (Double) -> Double) -> ([Float], [Float]) {
        let bins = 1024
        // Evaluate the frequency response once per bin, rather than once for
        // every tap. This reduces the cost of changing VSB coefficients live.
        let frequencies = (0..<bins).map { Double($0-bins/2)*rate/Double(bins) }
        let amplitudes = frequencies.map(response)
        let phases = frequencies.map { phase?($0) ?? 0 }
        var re = [Float](), im = [Float]()
        for n in -radius...radius {
            var a = 0.0, b = 0.0
            for k in 0..<bins {
                let f = frequencies[k]
                let h = amplitudes[k], p = 2 * Double.pi * f * Double(n) / rate+phases[k]
                a += h * cos(p); b += h * sin(p)
            }
            let w = 0.54 + 0.46 * cos(Double.pi * Double(n) / Double(radius))
            re.append(Float(a * w / Double(bins))); im.append(Float(b * w / Double(bins)))
        }
        if !normalize { return (re,im) }
        // Normalize inside the filter passband. A narrow IF may reject the carrier;
        // normalizing that rejected frequency would incorrectly amplify stopband noise.
        var referenceI = 0.0, referenceQ = 0.0
        for n in re.indices {
            let phase = 2 * Double.pi * normalizationHz * Double(n-radius)/rate
            referenceI += Double(re[n])*cos(phase)+Double(im[n])*sin(phase)
            referenceQ += Double(im[n])*cos(phase)-Double(re[n])*sin(phase)
        }
        let dc = Float(max(1e-8,hypot(referenceI,referenceQ)))
        return (re.map { $0 / dc }, im.map { $0 / dc })
    }
    static func taper(_ f: Double, cutoff: Double, transition: Double = 200_000) -> Double {
        let t = (abs(f) - cutoff + transition / 2) / transition
        return t <= 0 ? 1 : t >= 1 ? 0 : (1 + cos(.pi * t)) / 2
    }
}

/// Every output range reads its full causal overlap from an immutable joined
/// history/input buffer. The pointers live through synchronous worker completion.
private struct TelevisionConvolution: @unchecked Sendable {
    let input: UnsafeBufferPointer<Float>, kernel: UnsafeBufferPointer<Float>
    let output: UnsafeMutableBufferPointer<Float>
    func run(_ range: Range<Int>) {
        vDSP_conv(input.baseAddress!+range.lowerBound,1,kernel.baseAddress!,1,
                  output.baseAddress!+range.lowerBound,1,vDSP_Length(range.count),vDSP_Length(kernel.count))
    }
}

/// Each item has exactly one worker. Immutable input may be shared; its private
/// filter/history/output are read by the owner only after concurrentPerform returns.
private final class TelevisionFilterWork: @unchecked Sendable {
    var filter: TelevisionFIR
    let input: [Float]
    var output = [Float]()
    init(filter: TelevisionFIR, input: [Float]) { self.filter = filter; self.input = input }
    func run(chunks: Int = 1) { output = filter.process(input,chunks: chunks) }
}

/// Immutable array storage may be shared; each task writes only its own result.
/// All workers finish before the measured AFC value is used by the serial PLL.
private final class TVCarrierScan: @unchecked Sendable {
    let i: [Float], q: [Float], angles: [Float], range: Range<Int>
    var result = SIMD2<Double>.zero
    init(i: [Float],q: [Float],angles: [Float],range: Range<Int>) {
        self.i = i; self.q = q; self.angles = angles; self.range = range
    }
    func run() {
        result = i.withUnsafeBufferPointer { ip in q.withUnsafeBufferPointer { qp in
            angles.withUnsafeBufferPointer { ap in
                let i = ip.baseAddress!, q = qp.baseAddress!, a = ap.baseAddress!
                var winding = 0.0, power = 0.0, previous = Double(a[range.lowerBound-1])
                for n in range {
                    let phase = Double(a[n]); var delta = phase-previous
                    if delta > .pi { delta -= 2 * .pi }; if delta < -.pi { delta += 2 * .pi }
                    winding += delta; previous = phase
                    power += Double(i[n]*i[n]+q[n]*q[n])
                }
                return SIMD2(winding,power)
            }
        } }
    }
}

/// Stateful negative-AM VSB modulator. H(f)+H(-f)=2 in the video passband,
/// so coherent detection reconstructs the baseband without doubling low frequencies.
public struct VSBModulator: Sendable {
    private(set) var overmodulated = false
    public let system: TerrestrialSystem
    private var realFilter: TelevisionFIR
    private var imaginaryFilter: TelevisionFIR
    private var filterSettings = TVVSBFilterSettings()
    public init(system: TerrestrialSystem) {
        self.system = system
        let rate = system.video.sampleRate, vestige = system.vestigeMHz * 1e6
        let (r, i) = TelevisionFIR.complexKernel(rate: rate) { f in
            let side = abs(f) < vestige ? 1 + sin(.pi * f / (2 * vestige)) : (f > 0 ? 2.0 : 0.0)
            return side * TelevisionFIR.taper(f, cutoff: system.videoMHz * 1e6)
        }
        realFilter = TelevisionFIR(r); imaginaryFilter = TelevisionFIR(i)
    }
    public mutating func modulate(_ input: CompositeVideo, execution: TVExecution = .accelerated,
                                 filter settings: TVVSBFilterSettings = .init()) throws -> TelevisionRF {
        guard input.standard == system.video else { throw TVError.invalidSignal }
        try settings.validate()
        if filterSettings != settings {
            let rate = system.video.sampleRate, vestige = system.vestigeMHz*1e6
            let delay = settings.enabled ? Double(settings.groupDelayNS)*1e-9 : 0
            let fsc = system.video.subcarrierHz
            let (r,i) = TelevisionFIR.complexKernel(rate: rate,phase: { f in
                -2*Double.pi*delay*f*f*f/(3*fsc*fsc)
            }) { f in
                let side = abs(f) < vestige ? 1+sin(.pi*f/(2*vestige)) : (f > 0 ? 2.0 : 0.0)
                let transition = settings.enabled ? Double(settings.transitionMHz)*1e6 : 200_000
                let peak = settings.enabled ? (pow(10,Double(settings.peakingDB)/20)-1)*exp(-pow((abs(f)-3.5e6)/0.6e6,2)) : 0
                return side*TelevisionFIR.taper(f,cutoff: system.videoMHz*1e6,transition: transition)*(1+peak)
            }
            // Keep causal histories when changing hardware coefficients live.
            realFilter.kernel = r; imaginaryFilter.kernel = i
            filterSettings = settings
        }
        // Sync=100%, blanking=73.75%, peak white=12.5% carrier amplitude.
        // NTSC-M pedestal is inserted only in active picture, leaving blanking/burst intact.
        var voltage = input.samples
        if system == .ntscM {
            let s = input.standard, offset = s.sampleOffset(frame: input.frameIndex)
            for row in 0..<s.height {
                let start = Int(ceil((Double(input.frameIndex)*s.frameDuration + s.activeLine(row)*s.lineDuration + s.activeStart)*s.sampleRate - Double(offset)))
                let end = min(voltage.count, start + Int(s.activeDuration * s.sampleRate))
                if start >= 0, start < end {
                    for n in start..<end { voltage[n] = 0.0525 + voltage[n] * 0.925 }
                }
            }
        }
        var envelope = [Float](repeating: 0,count: voltage.count)
        var slope: Float = -0.875, pedestal: Float = 0.7375
        vDSP_vsmsa(voltage,1,&slope,&pedestal,&envelope,1,vDSP_Length(voltage.count))
        var minimum: Float = 0
        vDSP_minv(envelope,1,&minimum,vDSP_Length(envelope.count))
        overmodulated = minimum < 0
        let filtered = TelevisionFIR.together([realFilter,imaginaryFilter],inputs: [envelope,envelope],execution: execution)
        realFilter = filtered.0[0]; imaginaryFilter = filtered.0[1]
        return TelevisionRF(system: system, frameIndex: input.frameIndex, sampleRate: input.standard.sampleRate,
                            i: filtered.1[0], q: filtered.1[1])
    }
}

/// RF attenuation, complex delayed path and receiver-independent thermal noise.
public struct TerrestrialRFChannel: Sendable {
    private var scene = TVSceneChannel()
    private var tailI = [Float](), tailQ = [Float]()
    private var rng: UInt64
    public init(seed: UInt64 = 42) { rng = seed }
    private mutating func uniform() -> Float {
        rng &+= 0x9e3779b97f4a7c15
        return Self.uniformValue(rng)
    }
    @inline(__always) private static func uniformValue(_ state: UInt64) -> Float {
        var z = state; z = (z ^ (z >> 30)) &* 0xbf58476d1ce4e5b9
        z = (z ^ (z >> 27)) &* 0x94d049bb133111eb
        return Float((z ^ (z >> 31)) >> 40) / Float(1 << 24)
    }
    public mutating func transmit(_ input: TelevisionRF, settings: TerrestrialSettings) throws -> TelevisionRF {
        try input.validate()
        try settings.validate(rate: input.sampleRate)
        let (i,q) = transmit(i: input.i, q: input.q, rate: input.sampleRate,
                             carrierOffsetHz: 0, time: Double(input.frameIndex)*input.system.video.frameDuration, settings: settings)
        return TelevisionRF(system: input.system, frameIndex: input.frameIndex, sampleRate: input.sampleRate, i: i, q: q)
    }

    /// The same linear propagation model can be evaluated around either RF carrier.
    /// Noise power follows sampling bandwidth, keeping the RF noise spectral density fixed.
    mutating func transmit(i: [Float], q: [Float], rate: Double, carrierOffsetHz: Double,
                           noiseReferenceRate: Double? = nil, time: Double = 0, settings: TerrestrialSettings) -> ([Float],[Float]) {
        let (i,q) = scene.propagate(i: i,q: q,rate: rate,carrierOffsetHz: carrierOffsetHz,time: time,settings: settings.propagation)
        let delay = Double(settings.echoDelayMicroseconds) * 1e-6 * rate
        let historyCount = Int(ceil(40e-6 * rate)) + 2
        let xi = tailI + i, xq = tailQ + q, prefix = tailI.count
        let gain = pow(10, settings.signalDB / 20)
        let phase = Double(settings.echoPhaseDegrees) * .pi / 180 - 2 * .pi * carrierOffsetHz * Double(settings.echoDelayMicroseconds) * 1e-6
        let cp = Float(cos(phase)), sp = Float(sin(phase))
        let densityScale = Float(sqrt(rate / (noiseReferenceRate ?? rate)))
        let noise = Float(0.7375 / sqrt(2.0)) * pow(10, -settings.carrierToNoiseDB / 20) * densityScale * scene.noiseScale(settings.propagation)
        var re = [Float](repeating: 0, count: i.count), im = re
        if settings.execution == .reference {
            for n in re.indices {
                let p = Double(prefix + n) - delay, j = Int(floor(p)), f = Float(p - floor(p))
                var a: Float = 0, b: Float = 0
                if j >= 0, j + 1 < xi.count {
                    a = xi[j]*(1-f) + xi[j+1]*f; b = xq[j]*(1-f) + xq[j+1]*f
                } else if j == xi.count - 1 { a = xi[j]; b = xq[j] }
                let radius = sqrt(-2 * log(max(1e-7, uniform()))) * noise
                let angle = 2 * Float.pi * uniform()
                re[n] = gain * (i[n] + settings.echoGain*(a*cp-b*sp)) + radius*cos(angle)
                im[n] = gain * (q[n] + settings.echoGain*(a*sp+b*cp)) + radius*sin(angle)
            }
        } else {
            // Preserve the exact PRNG sequence across frames; vectorize only the
            // independent Box-Muller transforms, so speed does not alter the noise model.
            var radii = [Float](repeating: 0,count: re.count), angles = radii
            let seed = rng, sampleCount = re.count
            rng = radii.withUnsafeMutableBufferPointer { r in
                angles.withUnsafeMutableBufferPointer { a in
                    var state = seed
                    let radius = r.baseAddress!, angle = a.baseAddress!
                    for n in 0..<sampleCount {
                        state &+= 0x9e3779b97f4a7c15
                        radius[n] = max(1e-7,Self.uniformValue(state))
                        state &+= 0x9e3779b97f4a7c15
                        angle[n] = 2 * .pi * Self.uniformValue(state)
                    }
                    return state
                }
            }
            var length = Int32(re.count)
            radii.withUnsafeBufferPointer { u in
                re.withUnsafeMutableBufferPointer { r in vvlogf(r.baseAddress!,u.baseAddress!,&length) }
            }
            re.withUnsafeMutableBufferPointer { p in
                var scale: Float = -2
                vDSP_vsmul(p.baseAddress!,1,&scale,p.baseAddress!,1,vDSP_Length(sampleCount))
            }
            re.withUnsafeBufferPointer { logarithms in
                radii.withUnsafeMutableBufferPointer { r in vvsqrtf(r.baseAddress!,logarithms.baseAddress!,&length) }
            }
            angles.withUnsafeBufferPointer { angle in
                re.withUnsafeMutableBufferPointer { cosine in
                    im.withUnsafeMutableBufferPointer { sine in
                        vvsincosf(sine.baseAddress!,cosine.baseAddress!,angle.baseAddress!,&length)
                    }
                }
            }
            let wholeDelay = Int(ceil(delay)), fraction = Float(Double(wholeDelay)-delay)
            let echo = settings.echoGain, historySize = xi.count
            // Borrow each array once. The output cosine/sine storage is reused
            // in place; every index is bounded by the validated equal-size inputs.
            i.withUnsafeBufferPointer { inputI in
                q.withUnsafeBufferPointer { inputQ in
                    xi.withUnsafeBufferPointer { historyI in
                        xq.withUnsafeBufferPointer { historyQ in
                            radii.withUnsafeBufferPointer { radius in
                                re.withUnsafeMutableBufferPointer { real in
                                    im.withUnsafeMutableBufferPointer { imaginary in
                                        let a = inputI.baseAddress!, b = inputQ.baseAddress!
                                        let hi = historyI.baseAddress!, hq = historyQ.baseAddress!
                                        let r = radius.baseAddress!, outI = real.baseAddress!, outQ = imaginary.baseAddress!
                                        if echo == 0 {
                                            for n in 0..<sampleCount {
                                                let amplitude = r[n]*noise
                                                outI[n] = gain*a[n]+amplitude*outI[n]
                                                outQ[n] = gain*b[n]+amplitude*outQ[n]
                                            }
                                        } else {
                                            for n in 0..<sampleCount {
                                                let j = prefix+n-wholeDelay
                                                var ei: Float = 0, eq: Float = 0
                                                if j >= 0, j+1 < historySize {
                                                    ei = hi[j]*(1-fraction)+hi[j+1]*fraction
                                                    eq = hq[j]*(1-fraction)+hq[j+1]*fraction
                                                } else if j == historySize-1 { ei = hi[j]; eq = hq[j] }
                                                let amplitude = r[n]*noise
                                                outI[n] = gain*(a[n]+echo*(ei*cp-eq*sp))+amplitude*outI[n]
                                                outQ[n] = gain*(b[n]+echo*(ei*sp+eq*cp))+amplitude*outQ[n]
                                            }
                                        }
                                    }
                                }
                            }
                        }
                    }
                }
            }

        }
        tailI = Array(xi.suffix(historyCount)); tailQ = Array(xq.suffix(historyCount))
        TVSceneChannel.interference(i: &re,q: &im,rate: rate,carrierOffsetHz: carrierOffsetHz,time: time,
            noiseReferenceRate: noiseReferenceRate ?? rate,seed: settings.seed,settings: settings.propagation,execution: settings.execution)
        return (re,im)
    }
}

/// Recovered raster clock, rather than the transmitter's known frame origin.
public struct TVSyncTiming: Sendable {
    public let origin: Double
    public let samplesPerLine: Double
    public let edges: [Int]
    /// Periodic access to this sampled frame when the V oscillator rolls.
    public let wrapFrame: Bool
    public init(origin: Double,samplesPerLine: Double,edges: [Int],wrapFrame: Bool = false) {
        self.origin = origin; self.samplesPerLine = samplesPerLine; self.edges = edges; self.wrapFrame = wrapFrame
    }
}

public struct TerrestrialReceiver: Sendable {
    public let system: TerrestrialSystem
    private var frontEnd: TVReceiverFrontEnd
    private var soundNotch: TVSoundNotch?
    private var notchRate: Double = 0
    private var carrierFilterI: TelevisionFIR?
    private var carrierFilterQ: TelevisionFIR?
    private var carrierFilterRate: Double = 0
    private var carrierPhase = 0.0
    private(set) var carrierFrequency = 0.0
    private var gain: Float = 1
    private var gainAcquired = false
    private var gainDynamics = TVAGCDynamics()
    private var rasterDynamics = TVRasterDynamics()
    private var pictureReference: Float?
    private var clampState: SIMD2<Float>?
    var currentGain: Float { gain }
    private var syncLowpass: TelevisionFIR
    private var lastOrigin: Double?
    private var period: Double
    private var holdFrames = 0
    private var horizontalMisses: Int?
    private var verticalMisses: Int?
    private var colorMisses: Int?
    private var rasterMisses: Int?
    private static func syncState(detected: Bool, misses: inout Int?) -> TelevisionLock {
        if detected { misses = 0; return .locked }
        guard let previous = misses else { return .searching }
        misses = min(4,previous+1)
        return previous < 3 ? .holding : .searching
    }
    public init(system: TerrestrialSystem) {
        self.system = system; frontEnd = TVReceiverFrontEnd(system: system); period = system.video.samplesPerLine
        let (r, _) = TelevisionFIR.complexKernel(rate: system.video.sampleRate, radius: 12) {
            TelevisionFIR.taper($0, cutoff: 700_000, transition: 400_000)
        }
        syncLowpass = TelevisionFIR(r)
    }
    /// Legacy entry point: wrap a 4fsc vision frame as one channel record and
    /// receive it through the shared front end.
    public mutating func receive(_ input: TelevisionRF, settings: TerrestrialSettings) throws -> TerrestrialReception {
        try input.validate()
        let clock = TVChannelClock(system: system, sampleRate: input.sampleRate)
        let channel = TVChannelIQ(system: system, frameIndex: input.frameIndex,
                                  firstSampleIndex: clock.offset(frame: input.frameIndex),
                                  sampleRate: input.sampleRate, i: input.i, q: input.q)
        return try receive(channel, settings: settings)
    }

    /// Unified entry point: one combined channel IQ. A single tuning pass and one
    /// common IF run before carrier recovery and detection, so vision and sound
    /// share the same receiver front end.
    public mutating func receive(_ input: TVChannelIQ, settings: TerrestrialSettings) throws -> TerrestrialReception {
        try receiveWithFrontEnd(input, settings: settings).0
    }

    /// Same as receive(_:settings:) but also returns the shared front-end output,
    /// so a companion carrier can be extracted from the same receiver pass.
    mutating func receiveWithFrontEnd(_ input: TVChannelIQ, settings: TerrestrialSettings) throws -> (TerrestrialReception, TVFrontEndOutput) {
        let started = ContinuousClock.now
        try input.validate()
        guard input.system == system else { throw TVError.invalidSignal }
        try settings.validate(rate: input.sampleRate)
        let front = try frontEnd.process(input, settings: settings)
        return (try detect(front, settings: settings, started: started), front)
    }

    /// Detection-only half of the receiver, after the shared front end. The input
    /// is already tuned and IF-filtered; the spectrum is the pre-tuner RF tap.
    mutating func detect(
        _ front: TVFrontEndOutput, settings: TerrestrialSettings, started: ContinuousClock.Instant
    ) throws -> TerrestrialReception {
        let s = system.video, rate = front.sampleRate, count = front.i.count
        var re = front.i, im = front.q
        let spectrum = front.spectrum
        let frameIndex = front.frameIndex
        let tuned = ContinuousClock.now
        // Coarse AFC uses measured, unwrapped phase; it does not read transmitter
        // frequency or synchronization metadata. Capture range is deliberately finite.
        let acquisitionStart = min(2048, count/4)
        // Select the vision carrier before estimating its frequency. Near peak
        // white the companion carrier can dominate the composite IF vector, so
        // measuring the raw channel would bias AFC. The PLL below keeps tracking
        // the full signal, so the scalar and vector paths remain identical.
        if carrierFilterI == nil || carrierFilterRate != rate {
            let (k,_) = TelevisionFIR.complexKernel(rate: rate,radius: 24) {
                TelevisionFIR.taper($0,cutoff: 250_000,transition: 200_000)
            }
            carrierFilterI = TelevisionFIR(k); carrierFilterQ = TelevisionFIR(k)
            carrierFilterRate = rate
        }
        let carrierI = carrierFilterI!.process(re), carrierQ = carrierFilterQ!.process(im)
        let vectorAngles = settings.execution == .accelerated
        var angles = [Float](repeating: 0,count: vectorAngles ? count : 0)
        if vectorAngles {
            var length = Int32(count)
            re.withUnsafeBufferPointer { x in
                im.withUnsafeBufferPointer { y in
                    angles.withUnsafeMutableBufferPointer { p in
                        vvatan2f(p.baseAddress!,y.baseAddress!,x.baseAddress!,&length)
                    }
                }
            }
        }
        var winding = 0.0, totalPower = 0.0
        if vectorAngles {
            // Adjacent measured phase differences and powers are independent.
            // Each worker owns its accumulator; carrier PLL feedback stays serial.
            var carrierAngles = [Float](repeating: 0,count: count)
            var carrierLength = Int32(count)
            carrierI.withUnsafeBufferPointer { x in
                carrierQ.withUnsafeBufferPointer { y in
                    carrierAngles.withUnsafeMutableBufferPointer { p in
                        vvatan2f(p.baseAddress!,y.baseAddress!,x.baseAddress!,&carrierLength)
                    }
                }
            }
            let workers = min(8,max(1,(count-acquisitionStart)/65_536))
            let work = (0..<workers).map { worker in
                TVCarrierScan(i: carrierI,q: carrierQ,angles: carrierAngles,
                    range: acquisitionStart+1+worker*(count-acquisitionStart-1)/workers ..< acquisitionStart+1+(worker+1)*(count-acquisitionStart-1)/workers)
            }
            DispatchQueue.concurrentPerform(iterations: workers) { work[$0].run() }
            for item in work { winding += item.result.x; totalPower += item.result.y }
        } else {
            var previous = atan2(Double(carrierQ[acquisitionStart]),Double(carrierI[acquisitionStart]))
            for n in acquisitionStart+1..<count {
                let p = atan2(Double(carrierQ[n]),Double(carrierI[n]))
                var d = p-previous
                if d > .pi { d -= 2 * .pi }; if d < -.pi { d += 2 * .pi }
                winding += d; previous = p
                totalPower += Double(carrierI[n]*carrierI[n]+carrierQ[n]*carrierQ[n])
            }
        }
        let measured = winding * rate / (2 * .pi * Double(max(1,count-acquisitionStart-1)))
        let carrierPresent = totalPower / Double(count) > 1e-10
        let captured = carrierPresent && abs(measured) < 150_000
        carrierFrequency = settings.automaticFineTuning && captured ? measured : 0
        let estimated = ContinuousClock.now
        let omega = 2 * Double.pi * carrierFrequency / rate
        var demod = [Float](repeating: 0, count: count)
        // Narrow carrier PLL rejects most video modulation while following phase drift.
        let loopGain = 2 * Double.pi * 800 / rate
        var pllCorrection = 0.0
        var oscillatorI = cos(carrierPhase), oscillatorQ = sin(carrierPhase)
        let frequencyI = cos(omega), frequencyQ = sin(omega)
        if settings.execution == .accelerated {
            // atan2(z * exp(-j theta)) == wrap(arg(z) - theta). Input phase is
            // already available from vector AFC. Keep the exact per-sample PLL
            // feedback, then batch oscillator sin/cos and coherent detection.
            // This avoids a divide/polynomial and two serial complex rotations
            // per RF sample; the loop bandwidth and phase-error limiter are unchanged.
            var phases = [Float](repeating: 0,count: count)
            let initialPhase = carrierPhase
            let phaseState = re.withUnsafeBufferPointer { rp in
                im.withUnsafeBufferPointer { ip in
                    angles.withUnsafeBufferPointer { ap in
                        phases.withUnsafeMutableBufferPointer { pp in
                            var theta = initialPhase, correctionSum = 0.0
                            let r = rp.baseAddress!, i = ip.baseAddress!, a = ap.baseAddress!, p = pp.baseAddress!
                            for n in 0..<count {
                                p[n] = Float(theta)
                                var error = Double(a[n])-theta
                                if error > .pi { error -= 2 * .pi }
                                if error < -.pi { error += 2 * .pi }
                                error = r[n] == 0 && i[n] == 0 ? 0 : max(-0.2,min(0.2,error))
                                let correction = loopGain*error
                                theta += omega+correction
                                if theta > .pi { theta -= 2 * .pi }
                                if theta < -.pi { theta += 2 * .pi }
                                if n > acquisitionStart { correctionSum += correction }
                            }
                            return (theta,correctionSum)
                        }
                    }
                }
            }
            pllCorrection = phaseState.1
            var sine = [Float](repeating: 0,count: count)
            var length = Int32(count)
            phases.withUnsafeBufferPointer { p in
                demod.withUnsafeMutableBufferPointer { cosine in
                    sine.withUnsafeMutableBufferPointer { q in
                        vvsincosf(q.baseAddress!,cosine.baseAddress!,p.baseAddress!,&length)
                    }
                }
            }
            re.withUnsafeBufferPointer { rp in
                im.withUnsafeBufferPointer { ip in
                    sine.withUnsafeBufferPointer { sp in
                        demod.withUnsafeMutableBufferPointer { output in
                            let r = rp.baseAddress!, i = ip.baseAddress!, q = sp.baseAddress!, target = output.baseAddress!
                            for n in 0..<count { target[n] = r[n]*target[n]+i[n]*q[n] }
                        }
                    }
                }
            }
            carrierPhase = phaseState.0
        } else {
            re.withUnsafeBufferPointer { rp in
                im.withUnsafeBufferPointer { ip in
                    demod.withUnsafeMutableBufferPointer { output in
                        let r = rp.baseAddress!, i = ip.baseAddress!, target = output.baseAddress!
                        for n in 0..<count {
                            let c = Float(oscillatorI), q = Float(oscillatorQ)
                            let a = r[n]*c+i[n]*q, b = i[n]*c-r[n]*q
                            target[n] = a
                            let error = max(-0.2,min(0.2,atan2(Double(b),Double(a))))
                            let correction = loopGain*error
                            let x = oscillatorI*frequencyI-oscillatorQ*frequencyQ
                            let y = oscillatorI*frequencyQ+oscillatorQ*frequencyI
                            let ci = 1-correction*correction/2
                            oscillatorI = x*ci-y*correction; oscillatorQ = x*correction+y*ci
                            if n > acquisitionStart { pllCorrection += correction }
                            if n & 1023 == 0 {
                                let norm = hypot(oscillatorI,oscillatorQ); oscillatorI /= norm; oscillatorQ /= norm
                            }
                        }
                    }
                }
            }
            carrierPhase = atan2(oscillatorQ,oscillatorI)
        }
        let carrierRecovered = ContinuousClock.now
        // Notch the companion carrier before AGC and sync. A wide vision IF keeps
        // the +4.5/+6.5 MHz sound carrier, whose beat otherwise corrupts the
        // sync-tip quantile and the slicer. State persists across the session.
        if soundNotch == nil || notchRate != rate {
            soundNotch = TVSoundNotch(frequency: system.soundCarrierHz,rate: rate)
            notchRate = rate
        }
        demod = soundNotch!.process(demod)
        // Sync-tip keyed AGC is approximated by the upper carrier-amplitude quantile.
        // Independent RF noise means AGC cannot recover S/N after deep attenuation.
        let probes = stride(from: 128, to: count, by: 97).map { demod[$0] }.sorted()
        let tip = max(1e-5, probes[min(probes.count-1, Int(Double(probes.count)*0.96))])
        if settings.automaticGain {
            let target = min(10000, max(0.05, 1 / tip))
            if settings.receiverDamage.agcEnabled {
                var sum: Float = 0
                if settings.execution == .accelerated {
                    vDSP_sve(demod,1,&sum,vDSP_Length(count))
                } else { sum = demod.reduce(0,+) }
                let average = max(0.01,sum/Float(count)/tip)
                if pictureReference == nil { pictureReference = average }
                let pictureTarget = target*pow(pictureReference!/average,settings.receiverDamage.agcPictureSensitivity)
                gain = gainDynamics.step(target: pictureTarget,seconds: s.frameDuration,
                    responseMS: settings.receiverDamage.agcResponseMS,overshoot: settings.receiverDamage.agcOvershoot)
            } else {
                gainDynamics.reset(); pictureReference = nil; clampState = nil
                gain = gainAcquired ? 0.8*target + 0.2*gain : target
            }
            gainAcquired = true
        } else {
            gain = pow(10, settings.manualGainDB / 20)
            gainDynamics.reset(); pictureReference = nil; clampState = nil
        }
        var voltage: [Float]
        if settings.execution == .accelerated {
            voltage = [Float](repeating: 0,count: count)
            var scale = -gain/0.875, offset: Float = 0.7375/0.875
            vDSP_vsmsa(demod,1,&scale,&offset,&voltage,1,vDSP_Length(count))
        } else { voltage = demod.map { (0.7375 - $0*gain) / 0.875 } }
        let smoothed = syncLowpass.process(voltage,chunks: settings.execution == .accelerated ? 2 : 1)
        // Hysteretic sync slicer: smooth only the detector, preserving video bandwidth.
        var edges = [Int](), broad = [Int](), start: Int?
        smoothed.withUnsafeBufferPointer { samples in
        for n in samples.indices {
            let value = samples[n]
            if start == nil, value < -0.17 { start = n }
            if let a = start, value > -0.10 {
                let width = Double(n-a)/rate
                // Remove the detector FIR delay and threshold-crossing offset.
                let edge = max(0, a - 12)
                if (3.0e-6...6.8e-6).contains(width) { edges.append(edge) }
                if (19e-6...31e-6).contains(width) { broad.append(edge) }
                start = nil
            }
        }
        }
        // A train of broad pulses, separated by half-lines, identifies vertical sync.
        // A single accidental wide pulse cannot establish a frame origin.
        var vertical: Int?
        for j in 0..<max(0,broad.count-2) {
            let a = Double(broad[j+1]-broad[j]), b = Double(broad[j+2]-broad[j+1])
            if abs(a-s.samplesPerLine/2) < rate*0.8e-6,
               abs(b-s.samplesPerLine/2) < rate*0.8e-6 { vertical = broad[j]; break }
        }
        // Horizontal PLL: estimate line period from valid neighboring pulse intervals.
        let intervals = zip(edges.dropFirst(),edges).map { Double($0-$1) }.filter {
            abs($0-s.samplesPerLine) < rate*0.8e-6
        }.sorted()
        if intervals.count > s.height/2 {
            let median = intervals[intervals.count/2]
            let inliers = intervals.filter { abs($0-median) <= 1.5 }
            let measuredPeriod = inliers.reduce(0,+)/Double(inliers.count)
            period = 0.5*period + 0.5*measuredPeriod
        }
        let origin = vertical.map { Double($0) - Double(s.equalizingCount)*period/2 }
        var confidence: Float = 0
        if let origin {
            var matches = 0, cursor = 0
            for row in Array(stride(from: 0,to: s.height,by: 2)) + Array(stride(from: 1,to: s.height,by: 2)) {
                let expected = origin+s.activeLine(row)*period
                while cursor+1 < edges.count, abs(Double(edges[cursor+1])-expected) < abs(Double(edges[cursor])-expected) { cursor += 1 }
                if !edges.isEmpty, abs(Double(edges[cursor])-expected) < rate*1e-6 { matches += 1 }
            }
            confidence = Float(matches)/Float(s.height)
        }
        let good = captured && (settings.automaticFineTuning || abs(measured) < 1500) && confidence > 0.65
        var lock: TelevisionLock
        if good, let origin { lastOrigin = origin; holdFrames = 0; lock = .locked }
        else if lastOrigin != nil, holdFrames < 3 { holdFrames += 1; lock = .holding }
        else { holdFrames += 1; lock = .searching }
        let rasterOrigin = good ? origin! : lastOrigin ?? 0
        // Back-porch clamp uses detected sync edges, not a transmitter-known line grid.
        if good {
            var porch: [Float] = [], sync: [Float] = []
            for edge in edges {
                let a = edge+Int(rate*2e-6), b = edge+Int(rate*(s.activeStart-0.3e-6))
                if a >= 0, b < count { sync.append(voltage[a]); porch.append(voltage[b]) }
            }
            if !porch.isEmpty {
                porch.sort(); sync.sort()
                let black = porch[porch.count/2], bottom = sync[sync.count/2]
                let scale = min(3, max(0.2, 0.3/max(0.02, black-bottom)))
                var clamp = SIMD2(black,scale)
                if settings.receiverDamage.agcEnabled && settings.automaticGain {
                    if let old = clampState {
                        let alpha = Float(1-exp(-s.frameDuration/(Double(settings.receiverDamage.agcResponseMS)*0.001)))
                        clamp = old+(clamp-old)*alpha
                    }
                    clampState = clamp
                }
                if settings.execution == .accelerated {
                    var scale = clamp.y, offset = -clamp.x*scale
                    voltage.withUnsafeMutableBufferPointer { p in
                        vDSP_vsmsa(p.baseAddress!,1,&scale,&offset,p.baseAddress!,1,vDSP_Length(count))
                    }
                } else { voltage = voltage.map { ($0-clamp.x)*clamp.y } }
            }
        }
        // A free-running raster during loss produces snow/tearing; loss is not an error.
        let predicted = (0..<s.height).map { Int((rasterOrigin+s.activeLine($0)*period).rounded()) }.sorted()
        let carrierReady = captured && (settings.automaticFineTuning || abs(measured) < 1500)
        let horizontalDetected = carrierReady && intervals.count > s.height*65/100
        let raster = rasterDynamics.apply(TVSyncTiming(origin: rasterOrigin, samplesPerLine: period,
            edges: good ? edges : predicted),standard: s,settings: settings.receiverDamage,
            horizontalDetected: horizontalDetected,verticalDetected: carrierReady && vertical != nil,seed: settings.seed)
        if settings.receiverDamage.syncEnabled {
            let circuitLock = Self.syncState(detected: good && raster.1 && raster.2,misses: &rasterMisses)
            if good { lock = circuitLock }
        } else { rasterMisses = nil }
        let timing = raster.0
        let composite = try CompositeVideo(standard: s, frameIndex: frameIndex, samples: voltage)
        let synchronized = ContinuousClock.now
        var decoded = try TVEngine.decode(composite, settings: settings.decoder, timing: timing, execution: settings.execution)
        if system == .ntscM {
            // Undo the broadcast pedestal after Y/C decoding (equal offset in R,G,B).
            decoded = TVDecodeResult(frame: try TVFrame(standard: s, rgb: decoded.frame.rgb.map {
                SIMD3(max(0,($0.x-0.075)/0.925), max(0,($0.y-0.075)/0.925), max(0,($0.z-0.075)/0.925))
            }), recoveredLines: decoded.recoveredLines, colorLockedLines: decoded.colorLockedLines, meanBurstAmplitude: decoded.meanBurstAmplitude)
        }
        var reception = TerrestrialReception(frame: decoded.frame, lock: lock,
            recoveredLines: good ? decoded.recoveredLines : 0, colorLockedLines: good ? decoded.colorLockedLines : 0,
            agcDB: 20*log10(gain), carrierErrorHz: measured-carrierFrequency-pllCorrection*rate/(2 * .pi * Double(count-acquisitionStart-1)), syncConfidence: confidence)
        reception.visionSpectrum = spectrum
        // Report each detector separately. Valid H intervals can survive lost V
        // pulses, and a narrow picture IF can remove burst while retaining H/V.
        reception.synchronization.horizontal = Self.syncState(detected: horizontalDetected && raster.1,misses: &horizontalMisses)
        reception.synchronization.vertical = Self.syncState(detected: carrierReady && vertical != nil && raster.2,misses: &verticalMisses)
        reception.synchronization.color = Self.syncState(
            detected: horizontalDetected && decoded.colorLockedLines > s.height*65/100,misses: &colorMisses)
        reception.timings.tuner = TerrestrialTimings.seconds(started.duration(to: tuned))
        reception.timings.carrier = TerrestrialTimings.seconds(tuned.duration(to: carrierRecovered))
        reception.timings.carrierEstimation = TerrestrialTimings.seconds(tuned.duration(to: estimated))
        reception.timings.carrierPLL = TerrestrialTimings.seconds(estimated.duration(to: carrierRecovered))
        reception.timings.synchronization = TerrestrialTimings.seconds(carrierRecovered.duration(to: synchronized))
        reception.timings.videoDecode = TerrestrialTimings.seconds(synchronized.duration(to: .now))
        return reception
    }
}

/// Own one instance per continuous playback session. Seeking resets all DSP state.
public struct TerrestrialEngine: Sendable {
    public let system: TerrestrialSystem
    private var modulator: VSBModulator
    private var channel: TerrestrialRFChannel
    private var receiver: TerrestrialReceiver
    private var sound: TerrestrialSoundEngine
    private var amplifier = TVTransmitterAmplifier()
    public init(system: TerrestrialSystem, seed: UInt64 = 42) {
        self.system = system; modulator = VSBModulator(system: system)
        channel = TerrestrialRFChannel(seed: seed); receiver = TerrestrialReceiver(system: system)
        sound = TerrestrialSoundEngine(system: system,seed: seed)
    }
    public mutating func process(_ input: CompositeVideo, settings: TerrestrialSettings, audio: [Float]? = nil) throws -> TerrestrialReception {
        let start = ContinuousClock.now
        try settings.validate(rate: input.standard.sampleRate)
        var rf = try modulator.modulate(input,execution: settings.execution,filter: settings.transmitter.vsb)
        TVTransmitterSettings.drive(i: &rf.i,q: &rf.q,settings: settings.transmitter)
        // In-band cross-compression retains the two carrier envelopes. The sound
        // branch receives measured vision power averaged over its RF sample cells.
        var visionPower: [Float] = []
        if audio != nil, settings.transmitter.enabled, settings.transmitter.sharedCoupling > 0 {
            let cells = TVSoundClock.count(frame: input.frameIndex,standard: input.standard,rate: TerrestrialSoundEngine.rate)
            visionPower = rf.i.withUnsafeBufferPointer { ip in rf.q.withUnsafeBufferPointer { qp in
                [Float](unsafeUninitializedCapacity: cells) { output,initialized in
                    let i = ip.baseAddress!, q = qp.baseAddress!, target = output.baseAddress!, count = ip.count
                    for cell in 0..<cells {
                        let a = cell*count/cells, b = (cell+1)*count/cells
                        var sum: Float = 0
                        for n in a..<b { sum += i[n]*i[n]+q[n]*q[n] }
                        target.advanced(by: cell).initialize(to: sum/Float(max(1,b-a)))
                    }
                    initialized = cells
                }
            } }
        }
        (rf.i,rf.q) = amplifier.apply(i: rf.i,q: rf.q,settings: settings.transmitter,execution: settings.execution,
            otherPower: visionPower.isEmpty ? [] : [0.1*settings.transmitter.powerGain])
        let forward = amplifier.meanOutputPower
        TVTransmitterSettings.deliver(i: &rf.i,q: &rf.q,settings: settings.transmitter)
        let modulated = ContinuousClock.now
        let received = try channel.transmit(rf, settings: settings)
        let transmitted = ContinuousClock.now
        var result = try receiver.receive(received, settings: settings)
        result.lightningEvents = TVLightningTimeline.events(
            time: Double(input.frameIndex)*input.standard.frameDuration,
            duration: Double(input.samples.count)/input.standard.sampleRate,
            seed: settings.seed,settings: settings.propagation)
        result.transmitter.forwardPower = forward
        result.transmitter.saturated = settings.transmitter.enabled && amplifier.peakDrivePower >= pow(10,settings.transmitter.backoffDB/10)
        result.transmitter.overmodulated = modulator.overmodulated
        result.timings.modulation = TerrestrialTimings.seconds(start.duration(to: modulated))
        result.timings.channel = TerrestrialTimings.seconds(modulated.duration(to: transmitted))
        if let audio {
            let recovered = try sound.process(audio,frameIndex: input.frameIndex,settings: settings,
                                               visionCorrectionHz: receiver.carrierFrequency,receiverGain: receiver.currentGain,visionPower: visionPower)
            result.audio = recovered.samples; result.soundCarrierDB = recovered.carrierDB
            result.soundSpectrum = recovered.spectrum
            result.soundSeconds = recovered.seconds
            result.transmitter.forwardPower += recovered.transmitter.forwardPower
            result.transmitter.referencePower = 1.1
            result.transmitter.saturated = result.transmitter.saturated || recovered.transmitter.saturated
            result.transmitter.overmodulated = result.transmitter.overmodulated || recovered.transmitter.overmodulated
        }
        result.transmitter.reflectedPower = result.transmitter.forwardPower*settings.transmitter.reflectedFraction
        return result
    }
}
