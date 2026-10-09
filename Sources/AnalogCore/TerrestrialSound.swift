import Foundation
import Accelerate

public extension TerrestrialSystem {
    var soundCarrierHz: Double { self == .palDK ? 6_500_000 : 4_500_000 }
    var soundDeviationHz: Double { self == .palDK ? 50_000 : 25_000 }
    var soundEmphasisSeconds: Double { self == .palDK ? 50e-6 : 75e-6 }
}

/// Integer boundaries keep 48 kHz PCM contiguous at 30000/1001 fps as well as 25 fps.
public enum TVSoundClock {
    public static let pcmRate = 48_000
    public static func offset(frame: Int64, standard: TVStandard, rate: Int = pcmRate) -> Int64 {
        standard == .pal ? frame * Int64(rate) / 25 : frame * Int64(rate) * 1001 / 30000
    }
    public static func count(frame: Int64, standard: TVStandard, rate: Int = pcmRate) -> Int {
        Int(offset(frame: frame+1,standard: standard,rate: rate)-offset(frame: frame,standard: standard,rate: rate))
    }
}

public struct TerrestrialSoundReception: Sendable {
    public let samples: [Float]
    public let carrierDB: Float
    public let seconds: Double
    public let spectrum: TVSpectrum?
    public var transmitter = TVTransmitterTelemetry()
}

/// Mono F3E companion to the vision engine. Linear RF propagation is evaluated
/// in a separate 384 kHz complex envelope around the sound carrier. This preserves
/// channel noise density and the carrier-dependent echo phase without sampling
/// the 4.5/6.5 MHz spacing. It does not model intercarrier buzz or stereo multiplexes.
public struct TerrestrialSoundEngine: Sendable {
    public let system: TerrestrialSystem
    private let spectrumAnalyzer = TVSpectrumAnalyzer(log2Size: 9)
    static let rate = 384_000
    private var channel: TerrestrialRFChannel
    private var amplifier = TVTransmitterAmplifier()
    private var sourceFilter: TelevisionFIR
    private var ifI: TelevisionFIR
    private var ifQ: TelevisionFIR
    private var audioFilter: TelevisionFIR
    private var frontI: TelevisionFIR?
    private var frontQ: TelevisionFIR?
    private var frontSettings: SIMD2<Float>?
    private var previousSource: Float = 0
    private var previousEmphasized: Float = 0
    private var phase = 0.0
    private var receiverPhase = 0.0
    private var previousIQ = SIMD2<Float>(0,0)
    private var deemphasis: Float = 0
    private var dcInput: Float = 0
    private var dcOutput: Float = 0
    private var outputTail = [Float](repeating: 0,count: 16)

    public init(system: TerrestrialSystem, seed: UInt64 = 42) {
        self.system = system
        channel = TerrestrialRFChannel(seed: seed ^ 0x534f554e44)
        sourceFilter = TelevisionFIR(Self.lowpass(15_000,rate: 48_000,radius: 16))
        let k = Self.lowpass(100_000,rate: Double(Self.rate),radius: 24)
        ifI = TelevisionFIR(k); ifQ = TelevisionFIR(k)
        audioFilter = TelevisionFIR(Self.lowpass(15_000,rate: Double(Self.rate),radius: 48))
    }

    private static func lowpass(_ cutoff: Double, rate: Double, radius: Int) -> [Float] {
        let fc = cutoff/rate
        var k = (-radius...radius).map { n in
            Float((n == 0 ? 2*fc : sin(2 * .pi * fc * Double(n))/(.pi * Double(n))) *
                  (0.54+0.46*cos(.pi * Double(n)/Double(radius))))
        }
        let sum = k.reduce(0,+)
        for n in k.indices { k[n] /= sum }
        return k
    }

    public mutating func process(_ pcm: [Float], frameIndex: Int64, settings: TerrestrialSettings,
                                 visionCorrectionHz: Double = 0, receiverGain: Float = 1, visionPower: [Float] = []) throws -> TerrestrialSoundReception {
        let started = ContinuousClock.now
        guard frameIndex >= 0, frameIndex < 1_000_000_000,
              pcm.count == TVSoundClock.count(frame: frameIndex,standard: system.video),
              pcm.allSatisfy(\.isFinite), visionCorrectionHz.isFinite, receiverGain.isFinite, receiverGain > 0,
              visionPower.allSatisfy({ $0.isFinite && $0 >= 0 }) else { throw TVError.invalidSignal }
        try settings.validate(rate: system.video.sampleRate)
        let pcmStart = TVSoundClock.offset(frame: frameIndex,standard: system.video)
        let rfStart = TVSoundClock.offset(frame: frameIndex,standard: system.video,rate: Self.rate)
        let count = TVSoundClock.count(frame: frameIndex,standard: system.video,rate: Self.rate)
        let rate = Double(Self.rate)
        let source = sourceFilter.process(pcm)
        var emphasized = source
        let drive = pow(Float(10),settings.transmitter.audioDriveDB/20)
        let tau = Float(system.soundEmphasisSeconds * Double(TVSoundClock.pcmRate))
        var limited = false
        for n in source.indices {
            // Modulation limiter prevents over-deviation after pre-emphasis.
            let input = (source[n]+tau*(source[n]-previousSource))*drive
            if abs(input) > 1 { limited = true }
            emphasized[n] = max(-1,min(1,input))
            previousSource = source[n]
        }
        var angles = [Float](repeating: 0,count: count)
        let modulationStep = 2 * Double.pi * system.soundDeviationHz/rate
        for n in angles.indices {
            let position = Double(rfStart+Int64(n))/8-Double(pcmStart)
            let j = Int(floor(position)), fraction = Float(position-Double(j))
            let a = j <= 0 ? previousEmphasized : emphasized[min(j-1,emphasized.count-1)]
            let b = j < 0 ? previousEmphasized : emphasized[min(j,emphasized.count-1)]
            phase += modulationStep * Double(a+(b-a)*fraction)
            angles[n] = Float(phase)
            if n & 1023 == 0 { phase = phase.remainder(dividingBy: 2 * .pi) }
        }
        previousEmphasized = emphasized.last ?? previousEmphasized
        var i = angles, q = angles
        var length = Int32(count)
        angles.withUnsafeBufferPointer { p in
            i.withUnsafeMutableBufferPointer { cosine in
                q.withUnsafeMutableBufferPointer { sine in
                    vvsincosf(sine.baseAddress!,cosine.baseAddress!,p.baseAddress!,&length)
                }
            }
        }
        // 10:1 vision sync-carrier / sound-carrier power, within both profiles' range.
        let amplitude = Float(1/sqrt(10.0))*pow(10,settings.transmitter.powerDB/20)
        for n in i.indices { i[n] *= amplitude; q[n] *= amplitude }
        (i,q) = amplifier.apply(i: i,q: q,settings: settings.transmitter,execution: settings.execution,otherPower: visionPower)
        var meter = TVTransmitterTelemetry()
        meter.forwardPower = amplifier.meanOutputPower
        meter.reflectedPower = meter.forwardPower*settings.transmitter.reflectedFraction
        meter.saturated = settings.transmitter.enabled && amplifier.peakDrivePower >= pow(10,settings.transmitter.backoffDB/10)
        meter.overmodulated = limited
        TVTransmitterSettings.deliver(i: &i,q: &q,settings: settings.transmitter)
        (i,q) = channel.transmit(i: i,q: q,rate: rate,carrierOffsetHz: system.soundCarrierHz,
                                noiseReferenceRate: system.video.sampleRate,time: Double(rfStart)/rate,settings: settings)

        // Project the common RF front-end passband onto this carrier's narrow band.
        // Tuning changes the sound carrier's position relative to the channel edges.
        let front = SIMD2(settings.rfBandwidthMHz,settings.tuningOffsetKHz)
        if frontSettings != front {
            let low = -1.25e6, high = Double(settings.rfBandwidthMHz)*1e6-1.25e6
            let center = (low+high)/2, half = (high-low)/2
            let sound = system.soundCarrierHz-Double(settings.tuningOffsetKHz)*1000
            let (a,b) = TelevisionFIR.complexKernel(rate: rate,radius: 32,normalize: false) {
                TelevisionFIR.taper($0+sound-center,cutoff: half)
            }
            frontI = TelevisionFIR(a); frontQ = TelevisionFIR(b)
            frontQI = TelevisionFIR(a); frontQQ = TelevisionFIR(b); frontSettings = front
        }
        // Four separate causal histories for a complex FIR, saved across frames.
        let ai = frontI!.process(i), bi = frontQ!.process(i)
        // Apply the identical histories to Q via the independently retained branch below.
        let filteredQ = filterFrontQ(q)
        for n in i.indices { i[n] = ai[n]-filteredQ.1[n]; q[n] = bi[n]+filteredQ.0[n] }
        // Calibrated RX reference stays ahead of AGC / ADC overload, like vision.
        let spectrum = spectrumAnalyzer.analyze(i: i, q: q, rate: rate,
            centerHz: system.soundCarrierHz - Double(settings.tuningOffsetKHz)*1000)
        // Common slow front-end AGC ahead of the FM limiter. Fixed ADC noise and
        // overload make gain excursions audible; linear gain alone cancels in FM.
        if settings.receiverDamage.agcEnabled && settings.automaticGain {
            for n in i.indices {
                let index = UInt64(rfStart+Int64(n))
                let z = (index &* 6364136223846793005 &+ settings.seed) ^ (index >> 7)
                let noise = (Float((z >> 40) & 0xffff)/32768-1)*0.001
                i[n] = max(-0.8,min(0.8,i[n]*receiverGain+noise))
                let zq = z &* 2862933555777941757 &+ 3037000493
                let noiseQ = (Float((zq >> 40) & 0xffff)/32768-1)*0.001
                q[n] = max(-0.8,min(0.8,q[n]*receiverGain+noiseQ))
            }
        }
        let residual = -Double(settings.tuningOffsetKHz)*1000-visionCorrectionHz
        let tuneStep = 2 * Double.pi * residual/rate
        let canCapture = abs(residual) < rate/2-100_000
        var x = cos(receiverPhase), y = sin(receiverPhase)
        let c = cos(tuneStep), s = sin(tuneStep)
        for n in i.indices {
            let a = i[n], b = q[n]
            i[n] = canCapture ? a*Float(x)-b*Float(y) : 0
            q[n] = canCapture ? a*Float(y)+b*Float(x) : 0
            let next = x*c-y*s; y = x*s+y*c; x = next
            if n & 1023 == 0 { let norm = hypot(x,y); x /= norm; y /= norm }
        }
        receiverPhase = atan2(y,x)
        i = ifI.process(i); q = ifQ.process(q)
        let power = zip(i,q).reduce(Float(0)) { $0+$1.0*$1.0+$1.1*$1.1 }/Float(count)
        let deemphasisGain = Float(1/(1+system.soundEmphasisSeconds*rate))
        var demod = i
        for n in demod.indices {
            let current = SIMD2(i[n],q[n])
            // Limiting is implicit: the discriminator uses only the phase difference.
            let cross = current.y*previousIQ.x-current.x*previousIQ.y
            let dot = current.x*previousIQ.x+current.y*previousIQ.y
            let sample = Float(atan2(Double(cross),Double(dot))/modulationStep)
            previousIQ = current
            deemphasis += deemphasisGain*(sample-deemphasis)
            demod[n] = deemphasis
        }
        demod = audioFilter.process(demod)
        let joined = outputTail+demod, prefix = outputTail.count
        var output = [Float](repeating: 0,count: pcm.count)
        let dcPole = Float(exp(-2 * Double.pi * 20/Double(TVSoundClock.pcmRate)))
        for n in output.indices {
            let position = Double((pcmStart+Int64(n))*8-rfStart)+Double(prefix)
            let j = max(0,min(joined.count-2,Int(floor(position))))
            let f = Float(position-floor(position))
            let sample = joined[j]+(joined[j+1]-joined[j])*f
            let highpassed = sample-dcInput+dcPole*dcOutput
            dcInput = sample; dcOutput = highpassed
            output[n] = max(-1,min(1,highpassed))
        }
        outputTail = Array(joined.suffix(16))
        return TerrestrialSoundReception(samples: output,carrierDB: 10*log10(max(1e-12,power)),
            seconds: TerrestrialTimings.seconds(started.duration(to: .now)), spectrum: spectrum,transmitter: meter)
    }

    private var frontQI: TelevisionFIR?
    private var frontQQ: TelevisionFIR?
    private mutating func filterFrontQ(_ q: [Float]) -> ([Float],[Float]) {
        return (frontQI!.process(q),frontQQ!.process(q))
    }
}
