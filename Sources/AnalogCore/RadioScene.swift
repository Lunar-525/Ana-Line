import Foundation
import Accelerate

public enum RadioSceneMode: String, CaseIterable, Codable, Sendable {
    case am = "AM", fm = "FM", usb = "USB", lsb = "LSB", cw = "CW", pm = "PM"
}
public struct RadioStationParameters: Codable, Equatable, Sendable {
    public var am = AMSettings()
    public var fm = FMSettings()
    public var ssb = SSBSettings()
    public var cw = CWSettings()
    public var pm = PMSettings()
    public init() {}
    public func sampleRate(_ mode: RadioSceneMode) -> Double {
        switch mode {
        case .am: am.iqSampleRate
        case .fm: fm.iqSampleRate
        case .usb, .lsb: ssb.iqSampleRate
        case .cw: cw.iqSampleRate
        case .pm: pm.iqSampleRate
        }
    }
    public func bandwidth(_ mode: RadioSceneMode) -> Double {
        switch mode {
        case .am: am.audioBandwidthHz*3
        case .fm: (fm.deviationHz+fm.audioBandwidthHz)*2
        case .usb, .lsb: ssb.audioBandwidthHz
        case .cw: cw.receiveBandwidthHz
        case .pm: (pm.phaseDeviationRadians+1)*pm.audioBandwidthHz*2
        }
    }
    func validate(_ mode: RadioSceneMode) throws {
        let audioRate: Int
        switch mode {
        case .am: try am.validate(); audioRate = am.audioSampleRate
        case .fm: try fm.validate(); audioRate = fm.audioSampleRate
        case .usb, .lsb: try ssb.validate(); audioRate = ssb.audioSampleRate
        case .cw: try cw.validate(); audioRate = cw.audioSampleRate
        case .pm: try pm.validate(); audioRate = pm.audioSampleRate
        }
        guard audioRate == 48_000, [96_000.0,192_000,384_000].contains(sampleRate(mode)) else { throw FMError.invalidSettings }
    }
}
public struct RadioSceneTX: Identifiable, Codable, Equatable, Sendable {
    public var id: UUID
    public var enabled = true
    public var mode: RadioSceneMode = .am
    public var carrierHz = 0.0
    /// Relative carrier drive; 0 dB is unit amplitude before propagation.
    public var powerDB: Float = 0
    public var positionKm = 1.0
    public var toneHz = 440.0
    public var morseText = "CQ DE ANA LINE"
    public var wordsPerMinute = 20.0
    public var parameters = RadioStationParameters()
    public init(id: UUID = UUID()) { self.id = id }
}
public struct RadioSceneRX: Identifiable, Codable, Equatable, Sendable {
    public var id: UUID
    public var enabled = true
    public var mode: RadioSceneMode = .am
    public var tuningHz = 0.0
    public var gainDB: Float = 0
    public var positionKm = 0.0
    public var overloadEnabled = false
    public var parameters = RadioStationParameters()
    public init(id: UUID = UUID()) { self.id = id }
}
public struct RadioSceneSettings: Codable, Equatable, Sendable {
    public static let sampleRate = 768_000.0
    /// The rack is full from the start and nothing is added or removed: each
    /// station carries its own power switch, which is what takes it off air.
    public static let transmitterSlots = 8
    public static let receiverSlots = 2
    public var transmitters: [RadioSceneTX] = []
    public var receivers: [RadioSceneRX] = []
    public var noiseDB: Float = -80
    public var echoGain: Float = 0
    public var echoDelayMicroseconds = 30.0
    public var referenceCarrierMHz = 10.0
    public init() {}
    public func validate() throws {
        guard transmitters.count <= Self.transmitterSlots, receivers.count <= Self.receiverSlots,
              Set(transmitters.map(\.id)).count == transmitters.count,
              Set(receivers.map(\.id)).count == receivers.count,
              noiseDB.isFinite, (-120...(-20)).contains(noiseDB), echoGain.isFinite, (0...0.8).contains(echoGain),
              echoDelayMicroseconds.isFinite, (0...1000).contains(echoDelayMicroseconds),
              referenceCarrierMHz.isFinite, (1...1000).contains(referenceCarrierMHz) else { throw FMError.invalidSettings }
        for tx in transmitters {
            try tx.parameters.validate(tx.mode)
            guard tx.carrierHz.isFinite, abs(tx.carrierHz) <= 250_000,
                  abs(tx.carrierHz)+tx.parameters.bandwidth(tx.mode)/2 < Self.sampleRate/2-2000,
                  tx.powerDB.isFinite, (-60...12).contains(tx.powerDB), tx.positionKm.isFinite, (-10...10).contains(tx.positionKm),
                  tx.toneHz.isFinite, (100...5000).contains(tx.toneHz), tx.wordsPerMinute.isFinite, (5...60).contains(tx.wordsPerMinute),
                  tx.morseText.count <= 140 else { throw FMError.invalidSettings }
        }
        for rx in receivers {
            try rx.parameters.validate(rx.mode)
            guard rx.tuningHz.isFinite, abs(rx.tuningHz) <= 250_000,
                  abs(rx.tuningHz)+rx.parameters.bandwidth(rx.mode)/2 < Self.sampleRate/2-2000,
                  rx.gainDB.isFinite, (-24...24).contains(rx.gainDB), rx.positionKm.isFinite, (-10...10).contains(rx.positionKm)
            else { throw FMError.invalidSettings }
        }
    }
    /// The app's scene: every transmitter slot populated, so the per-station
    /// power switch decides what is on air instead of an add/remove list.
    /// Carriers step 60 kHz apart around the reference carrier and each station
    /// gets its own test-tone pitch, which is what makes eight stations
    /// distinguishable in the RF panorama without touching a knob.
    public static func eightStationScene() -> Self {
        var result = Self()
        result.transmitters = (0..<transmitterSlots).map { slot in
            var tx = RadioSceneTX()
            tx.carrierHz = Double(slot-3)*60_000
            tx.toneHz = 440+Double(slot)*110
            return tx
        }
        result.receivers = [RadioSceneRX(), RadioSceneRX()]
        return result
    }
}

private enum SceneModulator: Sendable {
    case am(AMTransmitter), fm(FMTransmitter), ssb(SSBTransmitter), cw(CWTransmitter), pm(PMTransmitter)
    init(_ tx: RadioSceneTX) throws {
        switch tx.mode {
        case .am: self = .am(try AMTransmitter(settings: tx.parameters.am))
        case .fm: self = .fm(try FMTransmitter(settings: tx.parameters.fm))
        case .usb, .lsb:
            var s = tx.parameters.ssb; s.sideband = tx.mode == .usb ? .usb : .lsb
            self = .ssb(try SSBTransmitter(settings: s))
        case .cw: self = .cw(try CWTransmitter(settings: tx.parameters.cw))
        case .pm: self = .pm(try PMTransmitter(settings: tx.parameters.pm))
        }
    }
    mutating func process(_ pcm: [Float]) throws -> FMIQ {
        switch self {
        case .am(var x): let result = try x.transmit(pcm); self = .am(x); return result
        case .fm(var x): let result = try x.transmit(pcm); self = .fm(x); return result
        case .ssb(var x): let result = try x.transmit(pcm); self = .ssb(x); return result
        case .cw(var x): let result = try x.transmit(pcm); self = .cw(x); return result
        case .pm(var x): let result = try x.transmit(pcm); self = .pm(x); return result
        }
    }
}
private enum SceneDemodulator: Sendable {
    case am(AMReceiver), fm(FMReceiver), ssb(SSBReceiver), cw(CWReceiver), pm(PMReceiver)
    init(_ rx: RadioSceneRX) throws {
        switch rx.mode {
        case .am: var s = rx.parameters.am; s.tuningOffsetHz = 0; self = .am(try AMReceiver(settings: s))
        case .fm: var s = rx.parameters.fm; s.tuningOffsetHz = 0; self = .fm(try FMReceiver(settings: s))
        case .usb, .lsb:
            var s = rx.parameters.ssb; s.sideband = rx.mode == .usb ? .usb : .lsb; s.tuningOffsetHz = 0
            self = .ssb(try SSBReceiver(settings: s))
        case .cw: var s = rx.parameters.cw; s.tuningOffsetHz = 0; self = .cw(try CWReceiver(settings: s))
        case .pm: var s = rx.parameters.pm; s.tuningOffsetHz = 0; self = .pm(try PMReceiver(settings: s))
        }
    }
    mutating func process(_ iq: FMIQ) throws -> [Float] {
        switch self {
        case .am(var x): let result = try x.receive(iq); self = .am(x); return result
        case .fm(var x): let result = try x.receive(iq); self = .fm(x); return result
        case .ssb(var x): let result = try x.receive(iq); self = .ssb(x); return result
        case .cw(var x): let result = try x.receive(iq); self = .cw(x); return result
        case .pm(var x): let result = try x.receive(iq); self = .pm(x); return result
        }
    }
}
private struct SceneTXState: Sendable {
    var configuration: RadioSceneTX
    var modulator: SceneModulator
    var resampler: TVComplexResampler
    var rfCursor: Int64 = 0
    var phase = 0.0
    var amplitude = 0.0
    init(_ tx: RadioSceneTX) throws {
        configuration = tx; modulator = try SceneModulator(tx)
        resampler = TVComplexResampler(inputRate: tx.parameters.sampleRate(tx.mode), outputRate: RadioSceneSettings.sampleRate, radius: 16)
    }
    mutating func process(_ pcm: [Float], tx: RadioSceneTX) throws -> ([Float],[Float]) {
        if configuration.mode != tx.mode || configuration.parameters != tx.parameters {
            let oldPhase = phase, oldAmplitude = amplitude
            self = try Self(tx); phase = oldPhase; amplitude = oldAmplitude
        }
        configuration = tx
        let iq = try modulator.process(pcm)
        let count = pcm.count*16
        var (i,q) = resampler.process(i: iq.i, q: iq.q, inputStart: iq.firstSampleIndex, outputStart: rfCursor, outputCount: count)
        let step = 2 * Double.pi*tx.carrierHz/RadioSceneSettings.sampleRate
        var x = cos(phase), y = sin(phase); let c = cos(step), s = sin(step)
        let target = tx.enabled ? pow(10,Double(tx.powerDB)/20) : 0
        let smooth = 1-exp(-1/(RadioSceneSettings.sampleRate*0.003))
        for n in i.indices {
            amplitude += smooth*(target-amplitude)
            let a = Double(i[n]), b = Double(q[n])
            i[n] = Float((a*x-b*y)*amplitude); q[n] = Float((a*y+b*x)*amplitude)
            let next = x*c-y*s; y = x*s+y*c; x = next
            if n & 1023 == 0 { let norm = hypot(x,y); x /= norm; y /= norm }
        }
        phase = atan2(y,x); rfCursor += Int64(count)
        return (i,q)
    }
}
private struct ScenePath: Sendable {
    private var historyI = [Float](repeating: 0,count: 1024)
    private var historyQ = [Float](repeating: 0,count: 1024)
    private var cachedDelay = Double.nan, cachedEchoDelay = Double.nan
    private var directKernel: [Float] = [], echoKernel: [Float] = []
    /// Windowed-sinc fractional delay avoids frequency-dependent attenuation of
    /// high-offset stations. All paths have the same extra 16-sample causal delay.
    private static func kernel(_ delay: Double) -> [Float] {
        let fraction = delay-floor(delay)
        var weights = (-16...16).map { n -> Float in
            let x = Double(n)-fraction
            let sinc = abs(x) < 1e-12 ? 1 : sin(Double.pi*x)/(Double.pi*x)
            return Float(sinc*(0.54+0.46*cos(Double.pi*Double(n)/16)))
        }
        let sum = weights.reduce(0,+)
        for n in weights.indices { weights[n] /= sum }
        return Array(weights.reversed())
    }
    private static func delayed(_ full: [Float], delay: Double, kernel: [Float], count: Int) -> [Float] {
        let offset = 1024-Int(floor(delay))-32
        var output = uninitializedFloats(count)
        full.withUnsafeBufferPointer { input in kernel.withUnsafeBufferPointer { coefficients in
            output.withUnsafeMutableBufferPointer { result in
                vDSP_conv(input.baseAddress!+offset,1,coefficients.baseAddress!,1,result.baseAddress!,1,vDSP_Length(count),33)
            }
        } }
        return output
    }
    mutating func add(i: [Float], q: [Float], tx: RadioSceneTX, rx: RadioSceneRX, settings: RadioSceneSettings,
                      to outputI: inout [Float], _ outputQ: inout [Float]) {
        let rate = RadioSceneSettings.sampleRate
        let distance = max(0.05,abs(tx.positionKm-rx.positionKm))
        let delay = distance*1000/299_792_458*rate
        let echoDelay = delay+settings.echoDelayMicroseconds*1e-6*rate
        if cachedDelay != delay { directKernel = Self.kernel(delay); cachedDelay = delay }
        if settings.echoGain > 0, cachedEchoDelay != echoDelay { echoKernel = Self.kernel(echoDelay); cachedEchoDelay = echoDelay }
        let phase = (-2 * Double.pi*settings.referenceCarrierMHz*1e6*distance*1000/299_792_458).remainder(dividingBy: 2 * .pi)
        // Calibrated at 1 km: field amplitude follows 1/r, not absolute received watts.
        let gain = 1/max(0.25,distance)
        let c = Float(cos(phase)*gain), s = Float(sin(phase)*gain)
        let fullI = historyI+i, fullQ = historyQ+q
        var a = Self.delayed(fullI,delay: delay,kernel: directKernel,count: i.count)
        var b = Self.delayed(fullQ,delay: delay,kernel: directKernel,count: i.count)
        if settings.echoGain > 0 {
            let ei = Self.delayed(fullI,delay: echoDelay,kernel: echoKernel,count: i.count)
            let eq = Self.delayed(fullQ,delay: echoDelay,kernel: echoKernel,count: i.count)
            let echoPhase = -2 * Double.pi*settings.referenceCarrierMHz*1e6*settings.echoDelayMicroseconds*1e-6
            let ec = Float(cos(echoPhase))*settings.echoGain, es = Float(sin(echoPhase))*settings.echoGain
            for n in a.indices { a[n] += ei[n]*ec-eq[n]*es; b[n] += ei[n]*es+eq[n]*ec }
        }
        for n in i.indices { outputI[n] += a[n]*c-b[n]*s; outputQ[n] += a[n]*s+b[n]*c }
        historyI = Array(fullI.suffix(1024)); historyQ = Array(fullQ.suffix(1024))
    }
}
private struct SceneRXState: Sendable {
    var configuration: RadioSceneRX
    var demodulator: SceneDemodulator
    var resampler: TVComplexResampler
    var phase = 0.0
    var rfCursor: Int64 = 0, nativeCursor: Int64 = 0
    var amplifier = TVReceiverAmplifier()
    var seed: UInt64 = 42
    init(_ rx: RadioSceneRX, seed: UInt64) throws {
        configuration = rx; demodulator = try SceneDemodulator(rx)
        let rate = rx.parameters.sampleRate(rx.mode)
        resampler = TVComplexResampler(inputRate: RadioSceneSettings.sampleRate, outputRate: rate, radius: 128)
        self.seed = seed
    }
    mutating func process(i: [Float], q: [Float], rx: RadioSceneRX, settings: RadioSceneSettings, measure: Bool,
                          analyzer: TVSpectrumAnalyzer) throws -> RadioSceneReception {
        if configuration.mode != rx.mode || configuration.parameters != rx.parameters {
            let oldPhase = phase, oldSeed = seed
            self = try Self(rx, seed: oldSeed); phase = oldPhase
        }
        configuration = rx
        var i = i, q = q
        let gain = pow(Float(10),rx.gainDB/20), noise = pow(Float(10),settings.noiseDB/20)
        for n in i.indices {
            seed = seed &* 6364136223846793005 &+ 1
            let ni = (Float(seed >> 40)/Float(1 << 24)*2-1)*noise
            seed = seed &* 6364136223846793005 &+ 1
            let nq = (Float(seed >> 40)/Float(1 << 24)*2-1)*noise
            i[n] = (i[n]+ni)*gain; q[n] = (q[n]+nq)*gain
        }
        var overloaded = false
        if rx.overloadEnabled { overloaded = amplifier.apply(i: &i,q: &q,saturationPower: 1,hardness: 0.5,amPMDegrees: 10) }
        // Wideband tap before tuning: what this receiver's front end actually
        // sees, including every co-channel station, noise, gain and overload.
        let environment = measure ? analyzer.analyze(i: i,q: q,rate: RadioSceneSettings.sampleRate,windows: 2) : nil
        let step = -2 * Double.pi*rx.tuningHz/RadioSceneSettings.sampleRate
        var x = cos(phase), y = sin(phase); let c = cos(step), s = sin(step)
        for n in i.indices {
            let a = i[n], b = q[n]
            i[n] = a*Float(x)-b*Float(y); q[n] = a*Float(y)+b*Float(x)
            let next = x*c-y*s; y = x*s+y*c; x = next
            if n & 1023 == 0 { let norm = hypot(x,y); x /= norm; y /= norm }
        }
        phase = atan2(y,x)
        let rate = rx.parameters.sampleRate(rx.mode), count = i.count/16
        let nativeCount = count*Int(rate/48_000)
        let narrow = resampler.process(i: i,q: q,inputStart: rfCursor,outputStart: nativeCursor,outputCount: nativeCount)
        let spectrum = measure ? analyzer.analyze(i: narrow.0,q: narrow.1,rate: rate,centerHz: rx.tuningHz,windows: 2) : nil
        let iq = FMIQ(sampleRate: rate,firstSampleIndex: nativeCursor,i: narrow.0,q: narrow.1)
        let pcm = try demodulator.process(iq)
        let samples = rx.enabled ? pcm : [Float](repeating: 0,count: pcm.count)
        rfCursor += Int64(i.count); nativeCursor += Int64(nativeCount)
        return RadioSceneReception(samples: samples, spectrum: spectrum, environment: environment,
            overloaded: overloaded, levelDB: RadioSceneReception.level(of: samples))
    }
}
public struct RadioSceneReception: Sendable {
    public let samples: [Float]
    /// Narrowband I/Q after tuning and decimation, before the IF filter.
    public let spectrum: TVSpectrum?
    /// Wideband RF at this receiver before tuning, for the environment waterfall.
    public let environment: TVSpectrum?
    public let overloaded: Bool
    /// Peak of the recovered audio in dBFS, floored at the display range so a
    /// muted or silent receiver never reports −inf. Interference that a listener
    /// hears as crosstalk also raises this number before any audio-level mixing.
    public let levelDB: Float
    /// True when the demodulated audio reaches the digital ceiling and would be
    /// clipped at the device boundary.
    public var isClipping: Bool { levelDB > -0.5 }
    static func level(of samples: [Float]) -> Float {
        var peak: Float = 0
        for sample in samples { peak = max(peak,abs(sample)) }
        return 20*log10(max(1e-5,peak))
    }
}
public struct RadioSceneFrame: Sendable {
    public let firstAudioSample: Int64
    public let transmitSpectra: [UUID: TVSpectrum]
    public let receptions: [UUID: RadioSceneReception]
}

/// All TX are linearly combined at each RX before tuning, IF filtering and demodulation.
/// Interference is RF superposition; recovered audio streams are never used as the channel.
public struct RadioSceneEngine: Sendable {
    private var transmitters: [UUID: SceneTXState] = [:]
    private var receivers: [UUID: SceneRXState] = [:]
    private struct PathID: Hashable, Sendable { let tx: UUID, rx: UUID }
    private var paths: [PathID: ScenePath] = [:]
    private let analyzer = TVSpectrumAnalyzer(log2Size: 11)
    public private(set) var audioCursor: Int64 = 0
    public init(audioCursor: Int64 = 0) { precondition(audioCursor >= 0); self.audioCursor = audioCursor }
    /// Missing TX input is silence. Validate the entire block before touching state.
    public mutating func process(_ inputs: [UUID:[Float]], count: Int, settings: RadioSceneSettings, measure: Bool = true) throws -> RadioSceneFrame {
        try settings.validate()
        guard (1...8192).contains(count), inputs.values.allSatisfy({ $0.count == count && $0.allSatisfy(\.isFinite) }),
              settings.transmitters.filter({ $0.mode == .cw }).allSatisfy({ tx in
                  (inputs[tx.id] ?? []).allSatisfy { (0...1).contains($0) }
              }) else { throw FMError.invalidSignal }
        let txIDs = Set(settings.transmitters.map(\.id)), rxIDs = Set(settings.receivers.map(\.id))
        transmitters = transmitters.filter { txIDs.contains($0.key) }; receivers = receivers.filter { rxIDs.contains($0.key) }
        paths = paths.filter { txIDs.contains($0.key.tx) && rxIDs.contains($0.key.rx) }
        var signals: [UUID:([Float],[Float])] = [:], spectra: [UUID:TVSpectrum] = [:]
        let silence = [Float](repeating: 0,count: count)
        for tx in settings.transmitters {
            var state = try transmitters[tx.id] ?? SceneTXState(tx)
            let signal = try state.process(inputs[tx.id] ?? silence, tx: tx)
            transmitters[tx.id] = state; signals[tx.id] = signal
            if measure, let spectrum = analyzer.analyze(i: signal.0,q: signal.1,rate: RadioSceneSettings.sampleRate,windows: 2) { spectra[tx.id] = spectrum }
        }
        var receptions: [UUID:RadioSceneReception] = [:]
        for (index, rx) in settings.receivers.enumerated() {
            var i = [Float](repeating: 0,count: count*16), q = i
            for tx in settings.transmitters {
                let id = PathID(tx: tx.id,rx: rx.id)
                var path = paths[id] ?? ScenePath()
                if let signal = signals[tx.id] { path.add(i: signal.0,q: signal.1,tx: tx,rx: rx,settings: settings,to: &i,&q) }
                paths[id] = path
            }
            var state = try receivers[rx.id] ?? SceneRXState(rx,seed: UInt64(index+1)*0x5258)
            receptions[rx.id] = try state.process(i: i,q: q,rx: rx,settings: settings,measure: measure,analyzer: analyzer)
            receivers[rx.id] = state
        }
        let result = RadioSceneFrame(firstAudioSample: audioCursor,transmitSpectra: spectra,receptions: receptions)
        audioCursor += Int64(count); return result
    }
}
