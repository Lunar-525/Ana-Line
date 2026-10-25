import Foundation

public enum SSBSideband: String, Codable, CaseIterable, Sendable { case usb = "USB", lsb = "LSB" }

public struct SSBSettings: Sendable, Codable, Equatable {
    public var audioSampleRate = 48_000
    public var oversampling = 2
    public var sideband: SSBSideband = .usb
    public var audioBandwidthHz = 3_000.0
    public var tuningOffsetHz = 0.0
    public var noiseAmplitude: Float = 0
    public var iqSampleRate: Double { Double(audioSampleRate * oversampling) }
    public init() {}
    public func validate() throws {
        try validateRadioRates(audioSampleRate, oversampling, audioBandwidthHz, tuningOffsetHz, noiseAmplitude)
        guard audioBandwidthHz >= 500 else { throw FMError.invalidSettings }
    }
}
public struct PMSettings: Sendable, Codable, Equatable {
    public var audioSampleRate = 48_000
    public var oversampling = 4
    public var audioBandwidthHz = 10_000.0
    public var phaseDeviationRadians = 1.0
    public var tuningOffsetHz = 0.0
    public var noiseAmplitude: Float = 0
    public var iqSampleRate: Double { Double(audioSampleRate * oversampling) }
    public init() {}
    public func validate() throws {
        try validateRadioRates(audioSampleRate, oversampling, audioBandwidthHz, tuningOffsetHz, noiseAmplitude)
        guard phaseDeviationRadians.isFinite, (0.1...4).contains(phaseDeviationRadians),
              (phaseDeviationRadians+1)*audioBandwidthHz+abs(tuningOffsetHz) < iqSampleRate/2 else { throw FMError.invalidSettings }
    }
}
public struct CWSettings: Sendable, Codable, Equatable {
    public var audioSampleRate = 48_000
    public var oversampling = 2
    public var pitchHz = 700.0
    public var receiveBandwidthHz = 800.0
    public var riseMilliseconds = 5.0
    public var tuningOffsetHz = 0.0
    public var noiseAmplitude: Float = 0
    public var iqSampleRate: Double { Double(audioSampleRate * oversampling) }
    public init() {}
    public func validate() throws {
        try validateRadioRates(audioSampleRate, oversampling, receiveBandwidthHz, tuningOffsetHz, noiseAmplitude)
        guard pitchHz.isFinite, (100...2_000).contains(pitchHz),
              (100...2_000).contains(receiveBandwidthHz),
              riseMilliseconds.isFinite, (1...20).contains(riseMilliseconds),
              pitchHz+receiveBandwidthHz < Double(audioSampleRate)/2 else { throw FMError.invalidSettings }
    }
}

private func validateRadioRates(_ rate: Int, _ ratio: Int, _ bandwidth: Double, _ tune: Double, _ noise: Float) throws {
    guard (8_000...192_000).contains(rate), (2...32).contains(ratio),
          bandwidth.isFinite, bandwidth > 0, bandwidth < Double(rate)/2,
          tune.isFinite, abs(tune)+bandwidth < Double(rate*ratio)/2,
          noise.isFinite, (0...2).contains(noise) else { throw FMError.invalidSettings }
}
private func validateIQ(_ iq: FMIQ, rate: Double, cursor: Int64) throws {
    guard iq.sampleRate == rate, iq.i.count == iq.q.count,
          iq.i.allSatisfy(\.isFinite), iq.q.allSatisfy(\.isFinite) else { throw FMError.invalidSignal }
    guard iq.firstSampleIndex == cursor else { throw FMError.discontinuity }
}

private struct RadioComplexFilter: Sendable {
    var ii: TelevisionFIR, iq: TelevisionFIR, qi: TelevisionFIR, qq: TelevisionFIR
    init(real: [Float], imaginary: [Float]) {
        ii = TelevisionFIR(real); iq = TelevisionFIR(imaginary)
        qi = TelevisionFIR(imaginary); qq = TelevisionFIR(real)
    }
    mutating func process(_ i: [Float], _ q: [Float]) -> ([Float], [Float]) {
        let a = ii.process(i), b = iq.process(q), c = qi.process(i), d = qq.process(q)
        return (zip(a,b).map(-), zip(c,d).map(+))
    }
}
private struct RadioTuner: Sendable {
    var phase = 0.0
    mutating func process(_ iq: FMIQ, offset: Double) -> ([Float], [Float]) {
        var i = iq.i, q = iq.q
        let step = -2 * Double.pi*offset/iq.sampleRate
        for n in i.indices {
            let a = Double(i[n]), b = Double(q[n]), c = cos(phase), s = sin(phase)
            i[n] = Float(a*c-b*s); q[n] = Float(a*s+b*c)
            phase = (phase+step).remainder(dividingBy: 2 * .pi)
        }
        return (i,q)
    }
}
private struct RadioAudioOutputFilter: Sendable {
    var filter: TelevisionFIR
    let ratio: Int
    init(rate: Double, cutoff: Double, ratio: Int) {
        self.ratio = ratio
        filter = TelevisionFIR(TVSoundFilterDesign.lowpass(cutoff, rate: rate, radius: ratio*16))
    }
    mutating func process(_ pcm: [Float], start: Int64) -> [Float] {
        let values = filter.process(pcm)
        return values.indices.compactMap { (start+Int64($0)) % Int64(ratio) == 0 ? values[$0] : nil }
    }
}
private struct RadioNoise: Sendable {
    var seed: UInt64 = 42
    mutating func apply(_ signal: FMIQ, amplitude: Float) -> FMIQ {
        guard amplitude > 0 else { return signal }
        var iq = signal
        for n in iq.i.indices {
            seed = seed &* 6364136223846793005 &+ 1
            iq.i[n] += (Float(seed >> 40)/Float(1 << 24)*2-1)*amplitude
            seed = seed &* 6364136223846793005 &+ 1
            iq.q[n] += (Float(seed >> 40)/Float(1 << 24)*2-1)*amplitude
        }
        return iq
    }
}

/// Phasing-method SSB: matched delay and a causal Hilbert transformer form analytic audio.
public struct SSBTransmitter: Sendable {
    public let settings: SSBSettings
    private var source: TelevisionFIR
    private var delay: TelevisionFIR
    private var hilbert: TelevisionFIR
    private var resampler: TVComplexResampler
    private var cursor: Int64 = 0
    public init(settings: SSBSettings = SSBSettings()) throws {
        try settings.validate(); self.settings = settings
        let rate = Double(settings.audioSampleRate), radius = 256
        let upper = TVSoundFilterDesign.lowpass(settings.audioBandwidthHz, rate: rate, radius: 128)
        let lower = TVSoundFilterDesign.lowpass(200, rate: rate, radius: 128)
        source = TelevisionFIR(zip(upper,lower).map(-))
        var impulse = [Float](repeating: 0, count: 2*radius+1); impulse[radius] = 1
        delay = TelevisionFIR(impulse)
        let h = (-radius...radius).map { n -> Float in
            guard n % 2 != 0 else { return 0 }
            return Float(2/(Double.pi*Double(n))*(0.54+0.46*cos(Double.pi*Double(n)/Double(radius))))
        }
        hilbert = TelevisionFIR(h)
        resampler = TVComplexResampler(inputRate: rate, outputRate: settings.iqSampleRate, radius: 16)
    }
    public mutating func transmit(_ pcm: [Float]) throws -> FMIQ {
        guard pcm.allSatisfy(\.isFinite) else { throw FMError.invalidSignal }
        let start = cursor*Int64(settings.oversampling)
        guard !pcm.isEmpty else { return FMIQ(sampleRate: settings.iqSampleRate, firstSampleIndex: start, i: [], q: []) }
        let audio = source.process(pcm), real = delay.process(audio)
        let imaginary = hilbert.process(audio).map { settings.sideband == .usb ? $0 : -$0 }
        let (i,q) = resampler.process(i: real, q: imaginary, inputStart: cursor,
            outputStart: start, outputCount: pcm.count*settings.oversampling)
        cursor += Int64(pcm.count)
        return FMIQ(sampleRate: settings.iqSampleRate, firstSampleIndex: start, i: i, q: q)
    }
}

/// Complex sideband selection followed by coherent product detection (BFO at IQ zero).
public struct SSBReceiver: Sendable {
    public let settings: SSBSettings
    private var tuner = RadioTuner()
    private var sidebandFilter: RadioComplexFilter
    private var output: RadioAudioOutputFilter
    private var cursor: Int64 = 0
    public init(settings: SSBSettings = SSBSettings()) throws {
        try settings.validate(); self.settings = settings
        let sign = settings.sideband == .usb ? 1.0 : -1.0
        let center = sign*(settings.audioBandwidthHz+200)/2
        let lowpass = TVSoundFilterDesign.lowpass((settings.audioBandwidthHz-200)/2,
            rate: settings.iqSampleRate, radius: 256)
        let real = lowpass.enumerated().map { n, k in k*Float(cos(2 * Double.pi*center*Double(n-256)/settings.iqSampleRate)) }
        let imag = lowpass.enumerated().map { n, k in k*Float(sin(2 * Double.pi*center*Double(n-256)/settings.iqSampleRate)) }
        sidebandFilter = RadioComplexFilter(real: real, imaginary: imag)
        output = RadioAudioOutputFilter(rate: settings.iqSampleRate, cutoff: settings.audioBandwidthHz, ratio: settings.oversampling)
    }
    public mutating func receive(_ iq: FMIQ) throws -> [Float] {
        try validateIQ(iq, rate: settings.iqSampleRate, cursor: cursor)
        guard !iq.i.isEmpty else { return [] }
        let tuned = tuner.process(iq, offset: settings.tuningOffsetHz)
        let filtered = sidebandFilter.process(tuned.0, tuned.1)
        let pcm = output.process(filtered.0, start: cursor)
        cursor += Int64(iq.i.count); return pcm
    }
}
public struct SSBEngine: Sendable {
    public private(set) var transmitter: SSBTransmitter
    public private(set) var receiver: SSBReceiver
    private var noise = RadioNoise()
    public init(settings: SSBSettings = SSBSettings(), seed: UInt64 = 42) throws {
        transmitter = try SSBTransmitter(settings: settings); receiver = try SSBReceiver(settings: settings); noise.seed = seed
    }
    public mutating func process(_ pcm: [Float]) throws -> [Float] {
        let iq = try transmitter.transmit(pcm)
        return try receiver.receive(noise.apply(iq, amplitude: transmitter.settings.noiseAmplitude))
    }
}

/// PM uses audio directly as phase, rather than integrating audio as FM does.
public struct PMTransmitter: Sendable {
    public let settings: PMSettings
    private var source: TelevisionFIR
    private var resampler: TVComplexResampler
    private var cursor: Int64 = 0
    public init(settings: PMSettings = PMSettings()) throws {
        try settings.validate(); self.settings = settings
        source = TelevisionFIR(TVSoundFilterDesign.lowpass(settings.audioBandwidthHz,
            rate: Double(settings.audioSampleRate), radius: 32))
        resampler = TVComplexResampler(inputRate: Double(settings.audioSampleRate), outputRate: settings.iqSampleRate, radius: 16)
    }
    public mutating func transmit(_ pcm: [Float]) throws -> FMIQ {
        guard pcm.allSatisfy(\.isFinite) else { throw FMError.invalidSignal }
        let start = cursor*Int64(settings.oversampling)
        guard !pcm.isEmpty else { return FMIQ(sampleRate: settings.iqSampleRate, firstSampleIndex: start, i: [], q: []) }
        let audio = source.process(pcm)
        let samples = resampler.process(i: audio, q: audio, inputStart: cursor,
            outputStart: start, outputCount: pcm.count*settings.oversampling).0
        let phases = samples.map { settings.phaseDeviationRadians*Double(max(-1, min(1, $0))) }
        cursor += Int64(pcm.count)
        return FMIQ(sampleRate: settings.iqSampleRate, firstSampleIndex: start,
            i: phases.map { Float(cos($0)) }, q: phases.map { Float(sin($0)) })
    }
}
public struct PMReceiver: Sendable {
    public let settings: PMSettings
    private var tuner = RadioTuner()
    private var ifI: TelevisionFIR, ifQ: TelevisionFIR
    private var output: RadioAudioOutputFilter
    private var previous = SIMD2<Float>(1,0)
    private var phase = 0.0
    private var dcInput = 0.0, dcOutput = 0.0
    private var dcSecondInput = 0.0, dcSecondOutput = 0.0
    private var cursor: Int64 = 0
    public init(settings: PMSettings = PMSettings()) throws {
        try settings.validate(); self.settings = settings
        let k = TVSoundFilterDesign.lowpass((settings.phaseDeviationRadians+1)*settings.audioBandwidthHz,
            rate: settings.iqSampleRate, radius: 64)
        ifI = TelevisionFIR(k); ifQ = TelevisionFIR(k)
        output = RadioAudioOutputFilter(rate: settings.iqSampleRate, cutoff: settings.audioBandwidthHz, ratio: settings.oversampling)
    }
    public mutating func receive(_ iq: FMIQ) throws -> [Float] {
        try validateIQ(iq, rate: settings.iqSampleRate, cursor: cursor)
        guard !iq.i.isEmpty else { return [] }
        let tuned = tuner.process(iq, offset: settings.tuningOffsetHz)
        var i = ifI.process(tuned.0); let q = ifQ.process(tuned.1)
        let pole = exp(-2 * Double.pi*20/settings.iqSampleRate)
        for n in i.indices {
            let z = SIMD2(i[n],q[n])
            if z.x*z.x+z.y*z.y > 1e-12 {
                phase += atan2(Double(z.y*previous.x-z.x*previous.y), Double(z.x*previous.x+z.y*previous.y))
                previous = z
            }
            let value = phase/settings.phaseDeviationRadians
            dcOutput = value-dcInput+pole*dcOutput; dcInput = value
            dcSecondOutput = dcOutput-dcSecondInput+pole*dcSecondOutput; dcSecondInput = dcOutput
            i[n] = Float(dcSecondOutput)
        }
        let pcm = output.process(i, start: cursor)
        cursor += Int64(i.count); return pcm
    }
}
public struct PMEngine: Sendable {
    public private(set) var transmitter: PMTransmitter
    public private(set) var receiver: PMReceiver
    private var noise = RadioNoise()
    public init(settings: PMSettings = PMSettings(), seed: UInt64 = 42) throws {
        transmitter = try PMTransmitter(settings: settings); receiver = try PMReceiver(settings: settings); noise.seed = seed
    }
    public mutating func process(_ pcm: [Float]) throws -> [Float] {
        let iq = try transmitter.transmit(pcm)
        return try receiver.receive(noise.apply(iq, amplitude: transmitter.settings.noiseAmplitude))
    }
}

/// Input samples are key levels in [0,1], not microphone/audio modulation.
public struct CWTransmitter: Sendable {
    public let settings: CWSettings
    private var envelope = 0.0
    private var cursor: Int64 = 0
    public init(settings: CWSettings = CWSettings()) throws { try settings.validate(); self.settings = settings }
    public mutating func transmit(_ key: [Float]) throws -> FMIQ {
        guard key.allSatisfy({ $0.isFinite && (0...1).contains($0) }) else { throw FMError.invalidSignal }
        let start = cursor*Int64(settings.oversampling)
        var i = [Float](); i.reserveCapacity(key.count*settings.oversampling)
        let alpha = 1-exp(-1/(settings.riseMilliseconds*0.001*settings.iqSampleRate))
        for sample in key {
            for _ in 0..<settings.oversampling {
                envelope += alpha*(Double(sample)-envelope); i.append(Float(envelope))
            }
        }
        cursor += Int64(key.count)
        return FMIQ(sampleRate: settings.iqSampleRate, firstSampleIndex: start, i: i, q: [Float](repeating: 0, count: i.count))
    }
}
public struct CWReceiver: Sendable {
    public let settings: CWSettings
    private var tuner = RadioTuner()
    private var ifI: TelevisionFIR, ifQ: TelevisionFIR
    private var output: RadioAudioOutputFilter
    private var phase = 0.0
    private var cursor: Int64 = 0
    public init(settings: CWSettings = CWSettings()) throws {
        try settings.validate(); self.settings = settings
        let k = TVSoundFilterDesign.lowpass(settings.receiveBandwidthHz/2, rate: settings.iqSampleRate, radius: 256)
        ifI = TelevisionFIR(k); ifQ = TelevisionFIR(k)
        output = RadioAudioOutputFilter(rate: settings.iqSampleRate, cutoff: settings.pitchHz+settings.receiveBandwidthHz,
            ratio: settings.oversampling)
    }
    public mutating func receive(_ iq: FMIQ) throws -> [Float] {
        try validateIQ(iq, rate: settings.iqSampleRate, cursor: cursor)
        guard !iq.i.isEmpty else { return [] }
        let tuned = tuner.process(iq, offset: settings.tuningOffsetHz)
        var i = ifI.process(tuned.0); let q = ifQ.process(tuned.1)
        let step = 2 * Double.pi*settings.pitchHz/settings.iqSampleRate
        for n in i.indices {
            i[n] = 0.4*(i[n]*Float(cos(phase))-q[n]*Float(sin(phase)))
            phase = (phase+step).remainder(dividingBy: 2 * .pi)
        }
        let pcm = output.process(i, start: cursor)
        cursor += Int64(i.count); return pcm
    }
}
public struct CWEngine: Sendable {
    public private(set) var transmitter: CWTransmitter
    public private(set) var receiver: CWReceiver
    private var noise = RadioNoise()
    public init(settings: CWSettings = CWSettings(), seed: UInt64 = 42) throws {
        transmitter = try CWTransmitter(settings: settings); receiver = try CWReceiver(settings: settings); noise.seed = seed
    }
    public mutating func process(_ key: [Float]) throws -> [Float] {
        let iq = try transmitter.transmit(key)
        return try receiver.receive(noise.apply(iq, amplitude: transmitter.settings.noiseAmplitude))
    }
}

public enum CWMorse {
    private static let symbols: [Character: String] = [
        "A":".-", "B":"-...", "C":"-.-.", "D":"-..", "E":".", "F":"..-.", "G":"--.", "H":"....",
        "I":"..", "J":".---", "K":"-.-", "L":".-..", "M":"--", "N":"-.", "O":"---", "P":".--.",
        "Q":"--.-", "R":".-.", "S":"...", "T":"-", "U":"..-", "V":"...-", "W":".--", "X":"-..-",
        "Y":"-.--", "Z":"--..", "0":"-----", "1":".----", "2":"..---", "3":"...--", "4":"....-",
        "5":".....", "6":"-....", "7":"--...", "8":"---..", "9":"----.", ".":".-.-.-", ",":"--..--",
        "?":"..--..", "/":"-..-.", "=":"-...-", "+":".-.-.", "-":"-....-", "@":".--.-."
    ]
    public static func encode(_ text: String, wordsPerMinute: Double = 20, sampleRate: Int = 48_000) throws -> [Float] {
        guard wordsPerMinute.isFinite, (5...60).contains(wordsPerMinute), (8_000...192_000).contains(sampleRate),
              !text.isEmpty, text.count <= 140 else { throw FMError.invalidSettings }
        let words = text.uppercased().split(whereSeparator: \.isWhitespace)
        guard !words.isEmpty, words.allSatisfy({ $0.allSatisfy { symbols[$0] != nil } }) else { throw FMError.invalidSignal }
        var segments: [(Float,Int)] = []
        for (w, word) in words.enumerated() {
            for (c, letter) in word.enumerated() {
                let code = Array(symbols[letter]!)
                for (n, symbol) in code.enumerated() {
                    segments.append((1,symbol == "." ? 1 : 3))
                    if n+1 < code.count { segments.append((0,1)) }
                }
                if c+1 < word.count { segments.append((0,3)) }
            }
            if w+1 < words.count { segments.append((0,7)) }
        }
        segments.append((0,3))
        let unit = Double(sampleRate)*1.2/wordsPerMinute
        var units = 0, result: [Float] = []
        for (level, length) in segments {
            units += length
            let end = Int((Double(units)*unit).rounded())
            result.append(contentsOf: repeatElement(level, count: end-result.count))
        }
        return result
    }
}
