import Foundation
import Accelerate

/// Vision-only RF profiles. Sound is deliberately separate from the video simulator.
public enum TerrestrialSystem: String, CaseIterable, Codable, Sendable {
    case palDK = "PAL-D/K", ntscM = "NTSC-M"
    public var video: TVStandard { self == .palDK ? .pal : .ntsc }
    public var channelMHz: Float { self == .palDK ? 8 : 6 }
    public var videoMHz: Double { self == .palDK ? 6 : 4.2 }
    public var vestigeMHz: Double { 0.75 }
    public init(video: TVStandard) { self = video == .pal ? .palDK : .ntscM }
}

public struct TerrestrialSettings: Equatable, Sendable {
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
    public init() {}
    public init(system: TerrestrialSystem) { rfBandwidthMHz = system.channelMHz }
    func validate(rate: Double) throws {
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
public struct TerrestrialTimings: Sendable {
    public var modulation: Double = 0
    public var channel: Double = 0
    public var tuner: Double = 0
    public var carrier: Double = 0
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
}

/// A causal, streaming FIR. State survives block boundaries, including between frames.
struct TelevisionFIR: Sendable {
    let kernel: [Float]
    var history: [Float]
    init(_ kernel: [Float]) { self.kernel = kernel; history = .init(repeating: 0, count: kernel.count - 1) }
    mutating func process(_ input: [Float]) -> [Float] {
        guard !input.isEmpty else { return [] }
        let joined = history + input
        let reversed = Array(kernel.reversed())
        var output = [Float](repeating: 0, count: input.count)
        joined.withUnsafeBufferPointer { x in
            reversed.withUnsafeBufferPointer { k in
                output.withUnsafeMutableBufferPointer { y in
                    vDSP_conv(x.baseAddress!, 1, k.baseAddress!, 1, y.baseAddress!, 1,
                              vDSP_Length(input.count), vDSP_Length(kernel.count))
                }
            }
        }
        history = Array(joined.suffix(kernel.count - 1))
        return output
    }
    /// Windowed inverse Fourier design; H is real but may be asymmetric in frequency.
    static func complexKernel(rate: Double, radius: Int = 48, normalizationHz: Double = 0,
                              response: (Double) -> Double) -> ([Float], [Float]) {
        let bins = 1024
        var re = [Float](), im = [Float]()
        for n in -radius...radius {
            var a = 0.0, b = 0.0
            for k in 0..<bins {
                let f = Double(k - bins / 2) * rate / Double(bins)
                let h = response(f), p = 2 * Double.pi * f * Double(n) / rate
                a += h * cos(p); b += h * sin(p)
            }
            let w = 0.54 + 0.46 * cos(Double.pi * Double(n) / Double(radius))
            re.append(Float(a * w / Double(bins))); im.append(Float(b * w / Double(bins)))
        }
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

/// Stateful negative-AM VSB modulator. H(f)+H(-f)=2 in the video passband,
/// so coherent detection reconstructs the baseband without doubling low frequencies.
public struct VSBModulator: Sendable {
    public let system: TerrestrialSystem
    private var realFilter: TelevisionFIR
    private var imaginaryFilter: TelevisionFIR
    public init(system: TerrestrialSystem) {
        self.system = system
        let rate = system.video.sampleRate, vestige = system.vestigeMHz * 1e6
        let (r, i) = TelevisionFIR.complexKernel(rate: rate) { f in
            let side = abs(f) < vestige ? 1 + sin(.pi * f / (2 * vestige)) : (f > 0 ? 2.0 : 0.0)
            return side * TelevisionFIR.taper(f, cutoff: system.videoMHz * 1e6)
        }
        realFilter = TelevisionFIR(r); imaginaryFilter = TelevisionFIR(i)
    }
    public mutating func modulate(_ input: CompositeVideo) throws -> TelevisionRF {
        guard input.standard == system.video else { throw TVError.invalidSignal }
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
        let envelope = voltage.map { 0.7375 - 0.875 * $0 }
        return TelevisionRF(system: system, frameIndex: input.frameIndex, sampleRate: input.standard.sampleRate,
                            i: realFilter.process(envelope), q: imaginaryFilter.process(envelope))
    }
}

/// RF attenuation, complex delayed path and receiver-independent thermal noise.
public struct TerrestrialRFChannel: Sendable {
    private var tailI = [Float](), tailQ = [Float]()
    private var rng: UInt64
    public init(seed: UInt64 = 42) { rng = seed }
    private mutating func uniform() -> Float {
        rng &+= 0x9e3779b97f4a7c15
        var z = rng; z = (z ^ (z >> 30)) &* 0xbf58476d1ce4e5b9
        z = (z ^ (z >> 27)) &* 0x94d049bb133111eb
        return Float((z ^ (z >> 31)) >> 40) / Float(1 << 24)
    }
    public mutating func transmit(_ input: TelevisionRF, settings: TerrestrialSettings) throws -> TelevisionRF {
        try input.validate()
        try settings.validate(rate: input.sampleRate)
        let delay = Double(settings.echoDelayMicroseconds) * 1e-6 * input.sampleRate
        let historyCount = Int(ceil(40e-6 * input.sampleRate)) + 2
        let xi = tailI + input.i, xq = tailQ + input.q, prefix = tailI.count
        let gain = pow(10, settings.signalDB / 20)
        let phase = settings.echoPhaseDegrees * .pi / 180, cp = cos(phase), sp = sin(phase)
        let noise = Float(0.7375 / sqrt(2.0)) * pow(10, -settings.carrierToNoiseDB / 20)
        var re = [Float](repeating: 0, count: input.i.count), im = re
        for n in re.indices {
            let p = Double(prefix + n) - delay, j = Int(floor(p)), f = Float(p - floor(p))
            var a: Float = 0, b: Float = 0
            if j >= 0, j + 1 < xi.count {
                a = xi[j]*(1-f) + xi[j+1]*f; b = xq[j]*(1-f) + xq[j+1]*f
            } else if j == xi.count - 1 { a = xi[j]; b = xq[j] }
            let radius = sqrt(-2 * log(max(1e-7, uniform()))) * noise
            let angle = 2 * Float.pi * uniform()
            re[n] = gain * (input.i[n] + settings.echoGain*(a*cp-b*sp)) + radius*cos(angle)
            im[n] = gain * (input.q[n] + settings.echoGain*(a*sp+b*cp)) + radius*sin(angle)
        }
        tailI = Array(xi.suffix(historyCount)); tailQ = Array(xq.suffix(historyCount))
        return TelevisionRF(system: input.system, frameIndex: input.frameIndex, sampleRate: input.sampleRate, i: re, q: im)
    }
}

/// Recovered raster clock, rather than the transmitter's known frame origin.
public struct TVSyncTiming: Sendable {
    public let origin: Double
    public let samplesPerLine: Double
    public let edges: [Int]
}

public struct TerrestrialReceiver: Sendable {
    public let system: TerrestrialSystem
    private var ifII: TelevisionFIR?, ifIQ: TelevisionFIR?
    private var ifQI: TelevisionFIR?, ifQQ: TelevisionFIR?
    private var bandwidth: Float = -1
    private var tunerPhase = 0.0
    private var carrierPhase = 0.0
    private var carrierFrequency = 0.0
    private var gain: Float = 1
    private var gainAcquired = false
    private var syncLowpass: TelevisionFIR
    private var lastOrigin: Double?
    private var period: Double
    private var holdFrames = 0
    public init(system: TerrestrialSystem) {
        self.system = system; period = system.video.samplesPerLine
        let (r, _) = TelevisionFIR.complexKernel(rate: system.video.sampleRate, radius: 12) {
            TelevisionFIR.taper($0, cutoff: 700_000, transition: 400_000)
        }
        syncLowpass = TelevisionFIR(r)
    }
    public mutating func receive(_ input: TelevisionRF, settings: TerrestrialSettings) throws -> TerrestrialReception {
        let started = ContinuousClock.now
        try input.validate()
        guard input.system == system else { throw TVError.invalidSignal }
        try settings.validate(rate: input.sampleRate)
        let s = system.video, rate = input.sampleRate, count = input.i.count
        // Tune the complex RF signal before the IF filter; detuning therefore changes
        // the signal's position within the passband, even when AFC can track its carrier.
        let step = -2 * Double.pi * Double(settings.tuningOffsetKHz) * 1000 / rate
        var re = input.i, im = input.q
        if step != 0 || tunerPhase != 0 {
            var x = cos(tunerPhase), y = sin(tunerPhase)
            let c = cos(step), q = sin(step)
            for n in re.indices {
                re[n] = input.i[n]*Float(x)-input.q[n]*Float(y)
                im[n] = input.i[n]*Float(y)+input.q[n]*Float(x)
                let next = x*c-y*q; y = x*q+y*c; x = next
                if n & 1023 == 0 { let norm = hypot(x,y); x /= norm; y /= norm }
            }
            tunerPhase = atan2(y,x)
        }
        if bandwidth != settings.rfBandwidthMHz {
            bandwidth = settings.rfBandwidthMHz
            let low = -1.25e6, high = Double(bandwidth)*1e6 - 1.25e6
            let center = (high + low)/2, half = (high-low)/2
            let (a,b) = TelevisionFIR.complexKernel(rate: rate, normalizationHz: center) { f in
                TelevisionFIR.taper(f-center, cutoff: half)
            }
            ifII = TelevisionFIR(a); ifIQ = TelevisionFIR(b)
            ifQI = TelevisionFIR(a); ifQQ = TelevisionFIR(b)
        }
        let ai = ifII!.process(re), bi = ifIQ!.process(re)
        let aq = ifQI!.process(im), bq = ifQQ!.process(im)
        for n in re.indices { re[n] = ai[n]-bq[n]; im[n] = bi[n]+aq[n] }
        let tuned = ContinuousClock.now
        // Coarse AFC uses measured, unwrapped phase; it does not read transmitter
        // frequency or synchronization metadata. Capture range is deliberately finite.
        let acquisitionStart = min(2048, count/4)
        var winding = 0.0, previous = atan2(Double(im[acquisitionStart]), Double(re[acquisitionStart]))
        var totalPower = 0.0
        for n in acquisitionStart+1..<count {
            let p = atan2(Double(im[n]), Double(re[n]))
            var d = p-previous
            if d > .pi { d -= 2 * .pi }; if d < -.pi { d += 2 * .pi }
            winding += d; previous = p
            totalPower += Double(re[n]*re[n]+im[n]*im[n])
        }
        let measured = winding * rate / (2 * .pi * Double(max(1,count-acquisitionStart-1)))
        let carrierPresent = totalPower / Double(count) > 1e-10
        let captured = carrierPresent && abs(measured) < 150_000
        carrierFrequency = settings.automaticFineTuning && captured ? measured : 0
        let omega = 2 * Double.pi * carrierFrequency / rate
        var demod = [Float](repeating: 0, count: count)
        // Narrow carrier PLL rejects most video modulation while following phase drift.
        let loopGain = 2 * Double.pi * 800 / rate
        var pllCorrection = 0.0
        var oscillatorI = cos(carrierPhase), oscillatorQ = sin(carrierPhase)
        let frequencyI = cos(omega), frequencyQ = sin(omega)
        for n in demod.indices {
            let c = Float(oscillatorI), q = Float(oscillatorQ)
            let a = re[n]*c + im[n]*q, b = im[n]*c - re[n]*q
            demod[n] = a
            let error = max(-0.2, min(0.2, atan2(Double(b), Double(a))))
            let correction = loopGain*error
            let x = oscillatorI*frequencyI-oscillatorQ*frequencyQ
            let y = oscillatorI*frequencyQ+oscillatorQ*frequencyI
            // The PLL correction is <0.0001 rad/sample; second-order small-angle
            // rotation avoids evaluating sin/cos millions of times per second.
            let ci = 1-correction*correction/2
            oscillatorI = x*ci-y*correction; oscillatorQ = x*correction+y*ci
            if n > acquisitionStart { pllCorrection += loopGain*error }
            if n & 1023 == 0 {
                let norm = hypot(oscillatorI,oscillatorQ); oscillatorI /= norm; oscillatorQ /= norm
            }
        }
        carrierPhase = atan2(oscillatorQ,oscillatorI)
        let carrierRecovered = ContinuousClock.now
        // Sync-tip keyed AGC is approximated by the upper carrier-amplitude quantile.
        // Independent RF noise means AGC cannot recover S/N after deep attenuation.
        let probes = stride(from: 128, to: count, by: 97).map { demod[$0] }.sorted()
        let tip = max(1e-5, probes[min(probes.count-1, Int(Double(probes.count)*0.96))])
        if settings.automaticGain {
            let target = min(10000, max(0.05, 1 / tip))
            gain = gainAcquired ? 0.8*target + 0.2*gain : target
            gainAcquired = true
        } else { gain = pow(10, settings.manualGainDB / 20) }
        var voltage = demod.map { (0.7375 - $0*gain) / 0.875 }
        let smoothed = syncLowpass.process(voltage)
        // Hysteretic sync slicer: smooth only the detector, preserving video bandwidth.
        var edges = [Int](), broad = [Int](), start: Int?
        for n in smoothed.indices {
            if start == nil, smoothed[n] < -0.17 { start = n }
            if let a = start, smoothed[n] > -0.10 {
                let width = Double(n-a)/rate
                // Remove the detector FIR delay and threshold-crossing offset.
                let edge = max(0, a - 12)
                if (3.0e-6...6.8e-6).contains(width) { edges.append(edge) }
                if (19e-6...31e-6).contains(width) { broad.append(edge) }
                start = nil
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
        let lock: TelevisionLock
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
                voltage = voltage.map { ($0-black)*scale }
            }
        }
        // A free-running raster during loss produces snow/tearing; loss is not an error.
        let predicted = (0..<s.height).map { Int((rasterOrigin+s.activeLine($0)*period).rounded()) }.sorted()
        let timing = TVSyncTiming(origin: rasterOrigin, samplesPerLine: period, edges: good ? edges : predicted)
        let composite = try CompositeVideo(standard: s, frameIndex: input.frameIndex, samples: voltage)
        let synchronized = ContinuousClock.now
        var decoded = try TVEngine.decode(composite, timing: timing)
        if system == .ntscM {
            // Undo the broadcast pedestal after Y/C decoding (equal offset in R,G,B).
            decoded = TVDecodeResult(frame: try TVFrame(standard: s, rgb: decoded.frame.rgb.map {
                SIMD3(max(0,($0.x-0.075)/0.925), max(0,($0.y-0.075)/0.925), max(0,($0.z-0.075)/0.925))
            }), recoveredLines: decoded.recoveredLines, colorLockedLines: decoded.colorLockedLines, meanBurstAmplitude: decoded.meanBurstAmplitude)
        }
        var reception = TerrestrialReception(frame: decoded.frame, lock: lock,
            recoveredLines: good ? decoded.recoveredLines : 0, colorLockedLines: good ? decoded.colorLockedLines : 0,
            agcDB: 20*log10(gain), carrierErrorHz: measured-carrierFrequency-pllCorrection*rate/(2 * .pi * Double(count-acquisitionStart-1)), syncConfidence: confidence)
        reception.timings.tuner = TerrestrialTimings.seconds(started.duration(to: tuned))
        reception.timings.carrier = TerrestrialTimings.seconds(tuned.duration(to: carrierRecovered))
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
    public init(system: TerrestrialSystem, seed: UInt64 = 42) {
        self.system = system; modulator = VSBModulator(system: system)
        channel = TerrestrialRFChannel(seed: seed); receiver = TerrestrialReceiver(system: system)
    }
    public mutating func process(_ input: CompositeVideo, settings: TerrestrialSettings) throws -> TerrestrialReception {
        let start = ContinuousClock.now
        let rf = try modulator.modulate(input)
        let modulated = ContinuousClock.now
        let received = try channel.transmit(rf, settings: settings)
        let transmitted = ContinuousClock.now
        var result = try receiver.receive(received, settings: settings)
        result.timings.modulation = TerrestrialTimings.seconds(start.duration(to: modulated))
        result.timings.channel = TerrestrialTimings.seconds(modulated.duration(to: transmitted))
        return result
    }
}
