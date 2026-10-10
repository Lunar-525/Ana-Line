import Foundation
import Accelerate

/// Second-order IIR notch at a known companion-carrier frequency. It has unity
/// DC gain, bounded state and a narrow notch, so it removes the sound beat from
/// the detected video without touching the vision passband. Bypassing it is a
/// receiver policy decision; the unified path relies on it for clean sync.
struct TVSoundNotch: Sendable {
    private var x1: Float = 0, x2: Float = 0, y1: Float = 0, y2: Float = 0
    private let b0: Float, b1: Float, b2: Float, a1: Float, a2: Float
    init(frequency: Double, rate: Double, r: Double = 0.98) {
        let w = 2*Double.pi*frequency/rate, c = cos(w)
        let gain = (1-2*r*c+r*r)/(2-2*c)
        b0 = Float(gain); b1 = Float(-2*c*gain); b2 = Float(gain)
        a1 = Float(-2*r*c); a2 = Float(r*r)
    }
    mutating func process(_ input: [Float]) -> [Float] {
        var output = input
        for n in input.indices {
            let x = input[n]
            let y = b0*x+b1*x1+b2*x2-a1*y1-a2*y2
            x2 = x1; x1 = x; y2 = y1; y1 = y
            output[n] = y
        }
        return output
    }
}

/// How the companion carrier is recovered at the detector.
public enum TVSoundDetectionMode: String, Codable, CaseIterable, Sendable {
    /// Band-select the carrier from the shared IF before video detection.
    case splitSound
    /// Recover the beat between the two carriers from the detected video.
    case intercarrier
}

/// Whether the detected video has the companion beat removed before AGC/sync.
public enum TVSoundNotchPolicy: String, Codable, CaseIterable, Sendable {
    case suppressed, bypassed
}

/// Receiver front-end configuration: common gain plus a bypassable memoryless
/// input/IF nonlinearity. It deliberately does not reuse the transmitter PA
/// settings; the receiver has its own saturation reference, state and defaults.
public struct TVFrontEndSettings: Codable, Equatable, Sendable {
    /// Master switch. Off is a clean, memoryless front end and the reference.
    public var enabled = false
    /// Common gain applied exactly once, ahead of the input stage.
    public var gainDB: Float = 0
    /// Input-stage saturation power in the receiver's relative units.
    public var inputSaturationDB: Float = 12
    public var inputHardness: Float = 0.5
    public var inputAMPMDegrees: Float = 0
    /// IF-amplifier saturation, applied after the common IF filter.
    public var ifSaturationDB: Float = 12
    public var ifHardness: Float = 0.5
    public var ifAMPMDegrees: Float = 0
    /// Companion-carrier recovery mode.
    public var soundDetection: TVSoundDetectionMode = .splitSound
    /// Video sound-notch policy; bypassing it demonstrates sound-on-vision.
    public var soundNotchPolicy: TVSoundNotchPolicy = .suppressed
    public init() {}
    public enum CodingKeys: String, CodingKey {
        case enabled, gainDB, inputSaturationDB, inputHardness, inputAMPMDegrees
        case ifSaturationDB, ifHardness, ifAMPMDegrees, soundDetection, soundNotchPolicy
    }
    /// Unknown or missing keys fall back to their defaults, so a session written
    /// before a field existed still decodes. New fields must use decodeIfPresent.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        enabled = try c.decodeIfPresent(Bool.self,forKey: .enabled) ?? false
        gainDB = try c.decodeIfPresent(Float.self,forKey: .gainDB) ?? 0
        inputSaturationDB = try c.decodeIfPresent(Float.self,forKey: .inputSaturationDB) ?? 12
        inputHardness = try c.decodeIfPresent(Float.self,forKey: .inputHardness) ?? 0.5
        inputAMPMDegrees = try c.decodeIfPresent(Float.self,forKey: .inputAMPMDegrees) ?? 0
        ifSaturationDB = try c.decodeIfPresent(Float.self,forKey: .ifSaturationDB) ?? 12
        ifHardness = try c.decodeIfPresent(Float.self,forKey: .ifHardness) ?? 0.5
        ifAMPMDegrees = try c.decodeIfPresent(Float.self,forKey: .ifAMPMDegrees) ?? 0
        soundDetection = try c.decodeIfPresent(TVSoundDetectionMode.self,forKey: .soundDetection) ?? .splitSound
        soundNotchPolicy = try c.decodeIfPresent(TVSoundNotchPolicy.self,forKey: .soundNotchPolicy) ?? .suppressed
    }
    func validate() throws {
        let checks: [(Float,ClosedRange<Float>)] = [(gainDB,-20...60),(inputSaturationDB,-40...60),
            (inputHardness,0...1),(inputAMPMDegrees,-90...90),(ifSaturationDB,-40...60),
            (ifHardness,0...1),(ifAMPMDegrees,-90...90)]
        guard checks.allSatisfy({ $0.0.isFinite && $0.1.contains($0.0) }) else { throw TVError.invalidSettings }
    }
    var gain: Float { pow(10,gainDB/20) }
    var inputSaturationPower: Float { pow(10,inputSaturationDB/10) }
    var ifSaturationPower: Float { pow(10,ifSaturationDB/10) }
}

/// Memoryless receiver overload: amplitude compression with optional AM/PM
/// conversion, evaluated from a cached LUT. It mirrors the transmitter PA's
/// shape but keeps independent coefficients and state, because the receiver's
/// saturation is referenced to the input level rather than the PA backoff.
struct TVReceiverAmplifier: Sendable {
    private var table = [SIMD2<Float>]()
    private var cachedSaturation: Float = .nan
    private var cachedHardness: Float = .nan
    private var cachedAMPM: Float = .nan
    private(set) var peakCompression: Float = 1

    static func coefficient(power: Double, saturationPower: Float, hardness: Float,
                            amPMDegrees: Float) -> SIMD2<Float> {
        let ratio = power/Double(max(1e-12,saturationPower))
        let p = 1+3*Double(hardness)
        let compression = pow(1+pow(ratio,p),-1/(2*p))
        let phase = Double(amPMDegrees)*Double.pi/180*ratio/(1+ratio)
        return SIMD2(Float(compression*cos(phase)),Float(compression*sin(phase)))
    }

    /// Returns true when the peak compression crossed the overload threshold.
    mutating func apply(i: inout [Float], q: inout [Float], saturationPower: Float,
                        hardness: Float, amPMDegrees: Float) -> Bool {
        guard !i.isEmpty, i.count == q.count else { return false }
        if cachedSaturation != saturationPower || cachedHardness != hardness || cachedAMPM != amPMDegrees {
            cachedSaturation = saturationPower; cachedHardness = hardness; cachedAMPM = amPMDegrees
            table = (0...1024).map {
                Self.coefficient(power: Double($0)/256,saturationPower: saturationPower,
                                 hardness: hardness,amPMDegrees: amPMDegrees)
            }
        }
        peakCompression = 1
        i.withUnsafeMutableBufferPointer { ip in
            q.withUnsafeMutableBufferPointer { qp in
                table.withUnsafeBufferPointer { tp in
                    let ri = ip.baseAddress!, rq = qp.baseAddress!, coefficients = tp.baseAddress!
                    for n in 0..<ip.count {
                        let power = Double(ri[n]*ri[n]+rq[n]*rq[n])
                        let position = min(1024.0,power*256)
                        let index = min(1023,Int(position)), fraction = Float(position-Double(index))
                        let coefficient = coefficients[index]+(coefficients[index+1]-coefficients[index])*fraction
                        peakCompression = min(peakCompression,hypot(coefficient.x,coefficient.y))
                        let a = ri[n], b = rq[n]
                        ri[n] = a*coefficient.x-b*coefficient.y
                        rq[n] = a*coefficient.y+b*coefficient.x
                    }
                }
            }
        }
        return peakCompression < 0.9
    }
}

/// Output of the shared receiver front end: tuned, IF-filtered complex IQ plus
/// the pre-nonlinearity RF tap used for the fixed-coordinate spectrum display,
/// and the gain/overload telemetry the service panel reports.
public struct TVFrontEndOutput: Sendable {
    public let system: TerrestrialSystem
    public let frameIndex: Int64
    public let sampleRate: Double
    public let firstSampleIndex: Int64
    public let i: [Float]
    public let q: [Float]
    public let spectrum: TVSpectrum?
    public let seconds: Double
    public let gainDB: Float
    public let inputPowerDB: Float
    public let overloaded: Bool
    public let passbandLowerHz: Double
    public let passbandUpperHz: Double
    public var count: Int { i.count }
}

/// One tuning pass and one common IF filter, shared by vision and sound. The
/// processing order is fixed and documented: fixed-coordinate RF tap, common
/// gain once, RF input nonlinearity, tuning, IF filter, IF nonlinearity. Each
/// nonlinearity stage can be bypassed and reports its overload state.
public struct TVReceiverFrontEnd: Sendable {
    public let system: TerrestrialSystem
    private let spectrumAnalyzer = TVSpectrumAnalyzer()
    private var ifII: TelevisionFIR?, ifIQ: TelevisionFIR?
    private var ifQI: TelevisionFIR?, ifQQ: TelevisionFIR?
    private var bandwidth: Float = -1
    private var tunerPhase = 0.0
    private var inputStage = TVReceiverAmplifier()
    private var ifStage = TVReceiverAmplifier()

    public init(system: TerrestrialSystem) { self.system = system }

    public mutating func process(_ input: TVChannelIQ, settings: TerrestrialSettings) throws -> TVFrontEndOutput {
        let started = ContinuousClock.now
        try input.validate()
        guard input.system == system else { throw TVError.invalidSignal }
        try settings.validate(rate: input.sampleRate)
        let rate = input.sampleRate, count = input.count, front = settings.frontEnd
        // Fixed RF coordinates, before gain or nonlinearity: the displayed
        // spectrum must not show receiver distortion that has not happened yet.
        let spectrum = spectrumAnalyzer.analyze(i: input.i, q: input.q, rate: rate)
        var re = input.i, im = input.q
        // Common front-end gain, applied exactly once ahead of the input stage.
        if front.gainDB != 0 {
            var gain = front.gain
            re.withUnsafeMutableBufferPointer { vDSP_vsmul($0.baseAddress!,1,&gain,$0.baseAddress!,1,vDSP_Length(count)) }
            im.withUnsafeMutableBufferPointer { vDSP_vsmul($0.baseAddress!,1,&gain,$0.baseAddress!,1,vDSP_Length(count)) }
        }
        var power: Float = 0, powerQ: Float = 0
        vDSP_svesq(re,1,&power,vDSP_Length(count)); vDSP_svesq(im,1,&powerQ,vDSP_Length(count))
        let inputPower = (power+powerQ)/Float(max(1,count))
        var overloaded = false
        // RF input stage sits before tuning and the IF filter.
        if front.enabled {
            overloaded = inputStage.apply(i: &re,q: &im,saturationPower: front.inputSaturationPower,
                hardness: front.inputHardness,amPMDegrees: front.inputAMPMDegrees)
        }
        // Tune the complex RF signal before the IF filter; detuning therefore changes
        // the signal's position within the passband, even when AFC can track its carrier.
        let step = -2 * Double.pi * Double(settings.tuningOffsetKHz) * 1000 / rate
        if step != 0 || tunerPhase != 0 {
            let initial = tunerPhase, c = cos(step), q = sin(step)
            let sourceI = re, sourceQ = im
            tunerPhase = sourceI.withUnsafeBufferPointer { a in sourceQ.withUnsafeBufferPointer { b in
                re.withUnsafeMutableBufferPointer { r in im.withUnsafeMutableBufferPointer { out in
                    var x = cos(initial), y = sin(initial)
                    for n in 0..<count {
                        r[n] = a[n]*Float(x)-b[n]*Float(y); out[n] = a[n]*Float(y)+b[n]*Float(x)
                        let next = x*c-y*q; y = x*q+y*c; x = next
                        if n & 1023 == 0 { let norm = hypot(x,y); x /= norm; y /= norm }
                    }
                    return atan2(y,x)
                } }
            } }
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
        let filtered = TelevisionFIR.together([ifII!,ifIQ!,ifQI!,ifQQ!],inputs: [re,re,im,im],execution: settings.execution)
        ifII = filtered.0[0]; ifIQ = filtered.0[1]; ifQI = filtered.0[2]; ifQQ = filtered.0[3]
        let ai = filtered.1[0], bi = filtered.1[1], aq = filtered.1[2], bq = filtered.1[3]
        vDSP_vsub(bq,1,ai,1,&re,1,vDSP_Length(count))
        vDSP_vadd(bi,1,aq,1,&im,1,vDSP_Length(count))
        // IF amplifier stage after the common IF filter.
        if front.enabled {
            overloaded = ifStage.apply(i: &re,q: &im,saturationPower: front.ifSaturationPower,
                hardness: front.ifHardness,amPMDegrees: front.ifAMPMDegrees) || overloaded
        }
        let low = -1.25e6, high = Double(bandwidth)*1e6-1.25e6
        return TVFrontEndOutput(system: system,frameIndex: input.frameIndex,sampleRate: rate,
            firstSampleIndex: input.firstSampleIndex,i: re,q: im,spectrum: spectrum,
            seconds: TerrestrialTimings.seconds(started.duration(to: .now)),
            gainDB: front.gainDB,inputPowerDB: 10*log10(max(1e-12,inputPower)),overloaded: overloaded,
            passbandLowerHz: low,passbandUpperHz: high)
    }
}
