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

/// Output of the shared receiver front end: tuned, IF-filtered complex IQ plus
/// the pre-tuner RF tap used for the fixed-coordinate spectrum display. The
/// front end is the single place tuning and the common IF filter are applied,
/// so vision and sound observe one receiver pass instead of two channels.
public struct TVFrontEndOutput: Sendable {
    public let system: TerrestrialSystem
    public let frameIndex: Int64
    public let sampleRate: Double
    public let firstSampleIndex: Int64
    public let i: [Float]
    public let q: [Float]
    public let spectrum: TVSpectrum?
    public let seconds: Double
    public var count: Int { i.count }
}

/// One tuning pass and one common IF filter. The arithmetic is the same the
/// legacy inline receiver front end used; the change is that it is now a
/// separate, reusable stage that a combined channel can feed once.
public struct TVReceiverFrontEnd: Sendable {
    public let system: TerrestrialSystem
    private let spectrumAnalyzer = TVSpectrumAnalyzer()
    private var ifII: TelevisionFIR?, ifIQ: TelevisionFIR?
    private var ifQI: TelevisionFIR?, ifQQ: TelevisionFIR?
    private var bandwidth: Float = -1
    private var tunerPhase = 0.0

    public init(system: TerrestrialSystem) { self.system = system }

    public mutating func process(_ input: TVChannelIQ, settings: TerrestrialSettings) throws -> TVFrontEndOutput {
        let started = ContinuousClock.now
        try input.validate()
        guard input.system == system else { throw TVError.invalidSignal }
        try settings.validate(rate: input.sampleRate)
        let rate = input.sampleRate, count = input.count
        // Display the received RF in fixed transmitter coordinates. Tuning and
        // IF filtering below affect reception, not the spectrum's frequency axis.
        let spectrum = spectrumAnalyzer.analyze(i: input.i, q: input.q, rate: rate)
        // Tune the complex RF signal before the IF filter; detuning therefore changes
        // the signal's position within the passband, even when AFC can track its carrier.
        let step = -2 * Double.pi * Double(settings.tuningOffsetKHz) * 1000 / rate
        var re = input.i, im = input.q
        if step != 0 || tunerPhase != 0 {
            let initial = tunerPhase, c = cos(step), q = sin(step)
            tunerPhase = input.i.withUnsafeBufferPointer { a in input.q.withUnsafeBufferPointer { b in
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
        return TVFrontEndOutput(system: system,frameIndex: input.frameIndex,sampleRate: rate,
            firstSampleIndex: input.firstSampleIndex,i: re,q: im,spectrum: spectrum,
            seconds: TerrestrialTimings.seconds(started.duration(to: .now)))
    }
}
