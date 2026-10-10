import Foundation
import Accelerate

/// Result of the narrowband sound receiver. Counts are PCM-clock samples, not
/// input IQ samples, so rate conversion cannot accumulate a drift.
public struct TVSoundDemodulatorOutput: Sendable {
    public let samples: [Float]
    public let carrierDB: Float
    public let seconds: Double
}

/// Receive half of the mono F3E companion. It takes the narrowband IQ that the
/// common front-end produced for this carrier and runs the sound IF, limiter /
/// discriminator, de-emphasis, 15 kHz audio filter and rate conversion to
/// 48 kHz PCM. Filter coefficients and the discriminator scale follow the
/// actual input rate rather than assuming 384 kHz.
public struct TVSoundDemodulator: Sendable {
    public let system: TerrestrialSystem
    private var configuredRate: Double = 0
    private var ifI: TelevisionFIR?
    private var ifQ: TelevisionFIR?
    private var audioFilter: TelevisionFIR?
    private var frontI: TelevisionFIR?
    private var frontQ: TelevisionFIR?
    private var frontQI: TelevisionFIR?
    private var frontQQ: TelevisionFIR?
    private var frontSettings: SIMD2<Float>?
    private var receiverPhase = 0.0
    private var previousIQ = SIMD2<Float>(0,0)
    private var deemphasis: Float = 0
    private var dcInput: Float = 0
    private var dcOutput: Float = 0
    private var outputTail = [Float](repeating: 0,count: 16)
    private let projectFrontEnd: Bool

    /// `projectFrontEnd` is true for the legacy separate-carrier path, where the
    /// narrowband input still has to be selected from the RF passband. A unified
    /// receiver extracts this carrier after the shared front end, so it passes
    /// false and the demodulator runs only IF, discriminator and audio filtering.
    public init(system: TerrestrialSystem, projectFrontEnd: Bool = true) {
        self.system = system; self.projectFrontEnd = projectFrontEnd
    }

    /// Rebuild rate-dependent filters once per rate. Histories restart only
    /// when the rate itself changes, which is a session reset event.
    private mutating func configure(rate: Double) {
        guard configuredRate != rate else { return }
        configuredRate = rate
        let k = TVSoundFilterDesign.lowpass(100_000,rate: rate,radius: 24)
        ifI = TelevisionFIR(k); ifQ = TelevisionFIR(k)
        audioFilter = TelevisionFIR(TVSoundFilterDesign.lowpass(15_000,rate: rate,radius: 48))
        frontI = nil; frontQ = nil; frontQI = nil; frontQQ = nil; frontSettings = nil
    }

    public mutating func demodulate(_ signal: TVSoundIQ, settings: TerrestrialSettings,
                                    visionCorrectionHz: Double, receiverGain: Float) -> TVSoundDemodulatorOutput {
        let started = ContinuousClock.now
        let rate = signal.sampleRate
        configure(rate: rate)
        let frameIndex = signal.frameIndex
        let count = signal.i.count
        let pcmCount = TVSoundClock.count(frame: frameIndex,standard: system.video)
        let ratio = rate/Double(TVSoundClock.pcmRate)
        let pcmStart = TVSoundClock.offset(frame: frameIndex,standard: system.video)
        let rfStart = TVSoundClock.offset(frame: frameIndex,standard: system.video,rate: Int(rate))
        var i = signal.i, q = signal.q

        // Project the common RF front-end passband onto this carrier's narrow band.
        // Tuning changes the sound carrier's position relative to the channel edges.
        // A unified receiver already selected this carrier, so it skips the stage.
        if projectFrontEnd {
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
            let filteredQ = (frontQI!.process(q),frontQQ!.process(q))
            for n in i.indices { i[n] = ai[n]-filteredQ.1[n]; q[n] = bi[n]+filteredQ.0[n] }
        }
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
        let residual = projectFrontEnd ? -Double(settings.tuningOffsetKHz)*1000-visionCorrectionHz : 0
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
        i = ifI!.process(i); q = ifQ!.process(q)
        let power = zip(i,q).reduce(Float(0)) { $0+$1.0*$1.0+$1.1*$1.1 }/Float(count)
        let modulationStep = 2 * Double.pi * system.soundDeviationHz/rate
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
        demod = audioFilter!.process(demod)
        let joined = outputTail+demod, prefix = outputTail.count
        var output = [Float](repeating: 0,count: pcmCount)
        let dcPole = Float(exp(-2 * Double.pi * 20/Double(TVSoundClock.pcmRate)))
        for n in output.indices {
            let position = Double(pcmStart+Int64(n))*ratio-Double(rfStart)+Double(prefix)
            let j = max(0,min(joined.count-2,Int(floor(position))))
            let f = Float(position-floor(position))
            let sample = joined[j]+(joined[j+1]-joined[j])*f
            let highpassed = sample-dcInput+dcPole*dcOutput
            dcInput = sample; dcOutput = highpassed
            output[n] = max(-1,min(1,highpassed))
        }
        outputTail = Array(joined.suffix(16))
        return TVSoundDemodulatorOutput(samples: output,carrierDB: 10*log10(max(1e-12,power)),
            seconds: TerrestrialTimings.seconds(started.duration(to: .now)))
    }
}
