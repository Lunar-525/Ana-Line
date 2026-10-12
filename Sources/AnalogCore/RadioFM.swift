import Foundation

public enum FMError: Error { case invalidSettings, invalidSignal, discontinuity }

/// Mono FM, represented as complex baseband IQ rather than sampled VHF RF.
public struct FMSettings: Sendable, Codable, Equatable {
    public var audioSampleRate = 48_000
    public var oversampling = 8
    public var deviationHz = 75_000.0
    public var audioBandwidthHz = 15_000.0
    public var emphasisSeconds = 50e-6
    public var tuningOffsetHz = 0.0
    public var noiseAmplitude: Float = 0
    public var iqSampleRate: Double { Double(audioSampleRate * oversampling) }
    public init() {}
    public func validate() throws {
        guard (8_000...192_000).contains(audioSampleRate), (2...32).contains(oversampling),
              deviationHz.isFinite, deviationHz > 0,
              audioBandwidthHz.isFinite, audioBandwidthHz > 0,
              audioBandwidthHz < Double(audioSampleRate)/2,
              emphasisSeconds.isFinite, (0...0.0001).contains(emphasisSeconds),
              tuningOffsetHz.isFinite,
              deviationHz + audioBandwidthHz + abs(tuningOffsetHz) < iqSampleRate/2,
              noiseAmplitude.isFinite, (0...2).contains(noiseAmplitude) else { throw FMError.invalidSettings }
    }
}

public struct FMIQ: Sendable {
    public let sampleRate: Double
    public let firstSampleIndex: Int64
    public var i: [Float]
    public var q: [Float]
    public init(sampleRate: Double, firstSampleIndex: Int64, i: [Float], q: [Float]) {
        self.sampleRate = sampleRate; self.firstSampleIndex = firstSampleIndex
        self.i = i; self.q = q
    }
}

public struct FMTransmitter: Sendable {
    public let settings: FMSettings
    public private(set) var limited = false
    private var sourceFilter: TelevisionFIR
    private var resampler: TVComplexResampler
    private var cursor: Int64 = 0
    private var phase = 0.0
    private var previous: Float = 0
    public init(settings: FMSettings = FMSettings()) throws {
        try settings.validate(); self.settings = settings
        sourceFilter = TelevisionFIR(TVSoundFilterDesign.lowpass(settings.audioBandwidthHz,
            rate: Double(settings.audioSampleRate), radius: 32))
        resampler = TVComplexResampler(inputRate: Double(settings.audioSampleRate),
            outputRate: settings.iqSampleRate, radius: 16)
    }
    /// Consecutive calls preserve filter history, emphasis and carrier phase.
    public mutating func transmit(_ pcm: [Float]) throws -> FMIQ {
        guard pcm.allSatisfy(\.isFinite) else { throw FMError.invalidSignal }
        let start = cursor * Int64(settings.oversampling)
        guard !pcm.isEmpty else { return FMIQ(sampleRate: settings.iqSampleRate, firstSampleIndex: start, i: [], q: []) }
        var source = sourceFilter.process(pcm)
        let tau = Float(settings.emphasisSeconds * Double(settings.audioSampleRate))
        limited = false
        for n in source.indices {
            let sample = source[n]
            let emphasized = sample + tau * (sample - previous)
            previous = sample
            limited = limited || abs(emphasized) > 1
            source[n] = max(-1, min(1, emphasized))
        }
        let count = pcm.count * settings.oversampling
        let audio = resampler.process(i: source, q: source, inputStart: cursor,
            outputStart: start, outputCount: count).0
        var i = [Float](repeating: 0, count: count), q = i
        let step = 2 * Double.pi * settings.deviationHz / settings.iqSampleRate
        for n in audio.indices {
            phase = (phase + step * Double(audio[n])).remainder(dividingBy: 2 * .pi)
            i[n] = Float(cos(phase)); q[n] = Float(sin(phase))
        }
        cursor += Int64(pcm.count)
        return FMIQ(sampleRate: settings.iqSampleRate, firstSampleIndex: start, i: i, q: q)
    }
}

public struct FMReceiver: Sendable {
    public let settings: FMSettings
    private var ifI: TelevisionFIR
    private var ifQ: TelevisionFIR
    private var audioFilter: TelevisionFIR
    private var previous = SIMD2<Float>(0, 0)
    private var deemphasis: Float = 0
    private var phase = 0.0
    private var cursor: Int64 = 0
    public init(settings: FMSettings = FMSettings()) throws {
        try settings.validate(); self.settings = settings
        let kernel = TVSoundFilterDesign.lowpass(settings.deviationHz + settings.audioBandwidthHz,
            rate: settings.iqSampleRate, radius: 64)
        ifI = TelevisionFIR(kernel); ifQ = TelevisionFIR(kernel)
        audioFilter = TelevisionFIR(TVSoundFilterDesign.lowpass(settings.audioBandwidthHz,
            rate: settings.iqSampleRate, radius: settings.oversampling * 16))
    }
    /// Accepts arbitrary contiguous IQ block sizes. Invalid calls leave state intact.
    public mutating func receive(_ signal: FMIQ) throws -> [Float] {
        guard signal.sampleRate == settings.iqSampleRate, signal.i.count == signal.q.count,
              signal.i.allSatisfy(\.isFinite), signal.q.allSatisfy(\.isFinite) else { throw FMError.invalidSignal }
        guard signal.firstSampleIndex == cursor else { throw FMError.discontinuity }
        guard !signal.i.isEmpty else { return [] }
        var i = signal.i, q = signal.q
        let tune = -2 * Double.pi * settings.tuningOffsetHz / settings.iqSampleRate
        for n in i.indices {
            let a = Double(i[n]), b = Double(q[n]), c = cos(phase), s = sin(phase)
            i[n] = Float(a*c-b*s); q[n] = Float(a*s+b*c)
            phase = (phase + tune).remainder(dividingBy: 2 * .pi)
        }
        i = ifI.process(i); q = ifQ.process(q)
        let scale = settings.iqSampleRate / (2 * Double.pi * settings.deviationHz)
        let alpha = Float(1 / (1 + settings.emphasisSeconds * settings.iqSampleRate))
        for n in i.indices {
            let z = SIMD2(i[n], q[n])
            let angle = atan2(Double(z.y*previous.x-z.x*previous.y), Double(z.x*previous.x+z.y*previous.y))
            previous = z
            deemphasis += alpha * (Float(angle * scale) - deemphasis)
            i[n] = deemphasis
        }
        let filtered = audioFilter.process(i)
        var output: [Float] = []
        for n in filtered.indices where (cursor + Int64(n)) % Int64(settings.oversampling) == 0 {
            output.append(filtered[n])
        }
        cursor += Int64(i.count)
        return output
    }
}

/// Stateful in-memory TX → additive IQ noise channel → RX chain.
public struct FMEngine: Sendable {
    public private(set) var transmitter: FMTransmitter
    public private(set) var receiver: FMReceiver
    private var seed: UInt64
    public init(settings: FMSettings = FMSettings(), seed: UInt64 = 42) throws {
        transmitter = try FMTransmitter(settings: settings)
        receiver = try FMReceiver(settings: settings); self.seed = seed
    }
    public mutating func process(_ pcm: [Float]) throws -> [Float] {
        var iq = try transmitter.transmit(pcm)
        let noise = transmitter.settings.noiseAmplitude
        if noise > 0 {
            for n in iq.i.indices {
                seed = seed &* 6364136223846793005 &+ 1
                iq.i[n] += (Float(seed >> 40)/Float(1 << 24)*2-1)*noise
                seed = seed &* 6364136223846793005 &+ 1
                iq.q[n] += (Float(seed >> 40)/Float(1 << 24)*2-1)*noise
            }
        }
        return try receiver.receive(iq)
    }
}
