import Foundation

public struct AMSettings: Sendable, Codable, Equatable {
    public var audioSampleRate = 48_000
    public var oversampling = 2
    public var audioBandwidthHz = 5_000.0
    public var modulationIndex = 0.8
    public var tuningOffsetHz = 0.0
    public var noiseAmplitude: Float = 0
    public var iqSampleRate: Double { Double(audioSampleRate * oversampling) }
    public init() {}
    public func validate() throws {
        guard (8_000...192_000).contains(audioSampleRate), (2...32).contains(oversampling),
              audioBandwidthHz.isFinite, audioBandwidthHz > 0,
              audioBandwidthHz < Double(audioSampleRate)/2,
              modulationIndex.isFinite, (0.01...1).contains(modulationIndex),
              tuningOffsetHz.isFinite, abs(tuningOffsetHz)+audioBandwidthHz < iqSampleRate/2,
              noiseAmplitude.isFinite, (0...2).contains(noiseAmplitude) else { throw FMError.invalidSettings }
    }
}

public struct AMTransmitter: Sendable {
    public let settings: AMSettings
    public private(set) var limited = false
    private var filter: TelevisionFIR
    private var resampler: TVComplexResampler
    private var cursor: Int64 = 0
    public init(settings: AMSettings = AMSettings()) throws {
        try settings.validate(); self.settings = settings
        filter = TelevisionFIR(TVSoundFilterDesign.lowpass(settings.audioBandwidthHz,
            rate: Double(settings.audioSampleRate), radius: 32))
        resampler = TVComplexResampler(inputRate: Double(settings.audioSampleRate),
            outputRate: settings.iqSampleRate, radius: 16)
    }
    public mutating func transmit(_ pcm: [Float]) throws -> FMIQ {
        guard pcm.allSatisfy(\.isFinite) else { throw FMError.invalidSignal }
        let start = cursor * Int64(settings.oversampling)
        guard !pcm.isEmpty else { return FMIQ(sampleRate: settings.iqSampleRate, firstSampleIndex: start, i: [], q: []) }
        let source = filter.process(pcm)
        var samples = resampler.process(i: source, q: source, inputStart: cursor,
            outputStart: start, outputCount: pcm.count * settings.oversampling).0
        limited = false
        for n in samples.indices {
            limited = limited || abs(samples[n]) > 1
            samples[n] = 1 + Float(settings.modulationIndex)*max(-1, min(1, samples[n]))
        }
        cursor += Int64(pcm.count)
        return FMIQ(sampleRate: settings.iqSampleRate, firstSampleIndex: start,
            i: samples, q: [Float](repeating: 0, count: samples.count))
    }
}

/// Carrier-preserving AM with envelope detection. No TV voltage conventions.
public struct AMReceiver: Sendable {
    public let settings: AMSettings
    private var ifI: TelevisionFIR
    private var ifQ: TelevisionFIR
    private var audioFilter: TelevisionFIR
    private var phase = 0.0
    private var dcInput: Float = 0
    private var dcOutput: Float = 0
    private var cursor: Int64 = 0
    public init(settings: AMSettings = AMSettings()) throws {
        try settings.validate(); self.settings = settings
        let kernel = TVSoundFilterDesign.lowpass(settings.audioBandwidthHz * 1.5,
            rate: settings.iqSampleRate, radius: 64)
        ifI = TelevisionFIR(kernel); ifQ = TelevisionFIR(kernel)
        audioFilter = TelevisionFIR(TVSoundFilterDesign.lowpass(settings.audioBandwidthHz,
            rate: settings.iqSampleRate, radius: settings.oversampling * 16))
    }
    public mutating func receive(_ iq: FMIQ) throws -> [Float] {
        guard iq.sampleRate == settings.iqSampleRate, iq.i.count == iq.q.count,
              iq.i.allSatisfy(\.isFinite), iq.q.allSatisfy(\.isFinite) else { throw FMError.invalidSignal }
        guard iq.firstSampleIndex == cursor else { throw FMError.discontinuity }
        guard !iq.i.isEmpty else { return [] }
        var i = iq.i, q = iq.q
        let step = -2 * Double.pi * settings.tuningOffsetHz/settings.iqSampleRate
        for n in i.indices {
            let a = Double(i[n]), b = Double(q[n]), c = cos(phase), s = sin(phase)
            i[n] = Float(a*c-b*s); q[n] = Float(a*s+b*c)
            phase = (phase+step).remainder(dividingBy: 2 * .pi)
        }
        i = ifI.process(i); q = ifQ.process(q)
        let dcPole = Float(exp(-2 * Double.pi * 20/settings.iqSampleRate))
        for n in i.indices {
            let envelope = (hypot(i[n], q[n])-1)/Float(settings.modulationIndex)
            dcOutput = envelope-dcInput+dcPole*dcOutput
            dcInput = envelope; i[n] = dcOutput
        }
        let filtered = audioFilter.process(i)
        var output: [Float] = []
        for n in filtered.indices where (cursor+Int64(n)) % Int64(settings.oversampling) == 0 {
            output.append(filtered[n])
        }
        cursor += Int64(i.count)
        return output
    }
}

public struct AMEngine: Sendable {
    public private(set) var transmitter: AMTransmitter
    public private(set) var receiver: AMReceiver
    private var seed: UInt64
    public init(settings: AMSettings = AMSettings(), seed: UInt64 = 42) throws {
        transmitter = try AMTransmitter(settings: settings)
        receiver = try AMReceiver(settings: settings); self.seed = seed
    }
    public mutating func process(_ pcm: [Float]) throws -> [Float] {
        var iq = try transmitter.transmit(pcm)
        if transmitter.settings.noiseAmplitude > 0 {
            for n in iq.i.indices {
                seed = seed &* 6364136223846793005 &+ 1
                iq.i[n] += (Float(seed >> 40)/Float(1 << 24)*2-1)*transmitter.settings.noiseAmplitude
                seed = seed &* 6364136223846793005 &+ 1
                iq.q[n] += (Float(seed >> 40)/Float(1 << 24)*2-1)*transmitter.settings.noiseAmplitude
            }
        }
        return try receiver.receive(iq)
    }
}

public enum RadioMode: String, CaseIterable, Codable, Sendable { case am = "AM", fm = "FM", ssb = "SSB", cw = "CW", pm = "PM" }

/// A streaming radio session. Settings changes and seeks start a new session;
/// each session preserves all DSP histories across audio blocks.
public enum RadioEngine: Sendable {
    case am(AMEngine)
    case fm(FMEngine)
    case ssb(SSBEngine)
    case cw(CWEngine)
    case pm(PMEngine)
    public init(mode: RadioMode, am: AMSettings = AMSettings(), fm: FMSettings = FMSettings(),
                ssb: SSBSettings = SSBSettings(), cw: CWSettings = CWSettings(), pm: PMSettings = PMSettings()) throws {
        switch mode {
        case .am: self = .am(try AMEngine(settings: am))
        case .fm: self = .fm(try FMEngine(settings: fm))
        case .ssb: self = .ssb(try SSBEngine(settings: ssb))
        case .cw: self = .cw(try CWEngine(settings: cw))
        case .pm: self = .pm(try PMEngine(settings: pm))
        }
    }
    public mutating func process(_ pcm: [Float]) throws -> [Float] {
        switch self {
        case .am(var engine):
            let output = try engine.process(pcm); self = .am(engine); return output
        case .fm(var engine):
            let output = try engine.process(pcm); self = .fm(engine); return output
        case .ssb(var engine):
            let output = try engine.process(pcm); self = .ssb(engine); return output
        case .cw(var engine):
            let output = try engine.process(pcm); self = .cw(engine); return output
        case .pm(var engine):
            let output = try engine.process(pcm); self = .pm(engine); return output
        }
    }
}
