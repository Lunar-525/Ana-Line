import Foundation
import Accelerate

/// Windowed-sinc design shared by the narrowband sound modulator and demodulator.
enum TVSoundFilterDesign {
    static func lowpass(_ cutoff: Double, rate: Double, radius: Int) -> [Float] {
        let fc = cutoff/rate
        var k = (-radius...radius).map { n in
            Float((n == 0 ? 2*fc : sin(2 * .pi * fc * Double(n))/(.pi * Double(n))) *
                  (0.54+0.46*cos(.pi * Double(n)/Double(radius))))
        }
        let sum = k.reduce(0,+)
        for n in k.indices { k[n] /= sum }
        return k
    }
}

/// Complex narrowband IQ referenced to the sound carrier. The vision carrier is
/// not sampled in this representation; a future unified channel owns that grid.
public struct TVSoundIQ: Sendable {
    public let system: TerrestrialSystem
    public let frameIndex: Int64
    public let sampleRate: Double
    public var i: [Float]
    public var q: [Float]
    public init(system: TerrestrialSystem, frameIndex: Int64, sampleRate: Double, i: [Float], q: [Float]) {
        self.system = system; self.frameIndex = frameIndex; self.sampleRate = sampleRate
        self.i = i; self.q = q
    }
}

/// Transmit half of the mono F3E companion. It owns only the modulator:
/// source band-limiting, pre-emphasis, over-deviation limiting and continuous
/// FM phase integration. Propagation, the common IF, receiver gain and
/// demodulation deliberately live elsewhere.
public struct TVSoundModulator: Sendable {
    public let system: TerrestrialSystem
    private var sourceFilter: TelevisionFIR
    private var previousSource: Float = 0
    private var previousEmphasized: Float = 0
    private var phase = 0.0
    public private(set) var overmodulated = false

    public init(system: TerrestrialSystem) {
        self.system = system
        sourceFilter = TelevisionFIR(TVSoundFilterDesign.lowpass(15_000,rate: 48_000,radius: 16))
    }

    /// Modulate one frame of 48 kHz PCM onto the narrowband carrier at the given rate.
    /// TVSoundClock supplies the absolute PCM/RF boundaries, so neither the
    /// fractional resampling phase nor the FM phase restarts per frame.
    public mutating func modulate(_ pcm: [Float], frameIndex: Int64, settings: TerrestrialSettings,
                                  rate: Double) -> TVSoundIQ {
        let ratio = rate/Double(TVSoundClock.pcmRate)
        let pcmStart = TVSoundClock.offset(frame: frameIndex,standard: system.video)
        let rfStart = TVSoundClock.offset(frame: frameIndex,standard: system.video,rate: Int(rate))
        let count = TVSoundClock.count(frame: frameIndex,standard: system.video,rate: Int(rate))
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
        // The RF/PCM rate ratio is 8 in the unified channel, so the interpolation
        // schedule is an exact integer grid. Walking it with integer state gives
        // the same sample positions and weights as the floating-point schedule
        // (dividing by a power of two is exact) without a per-sample floor and
        // index conversion. Any other ratio keeps the floating-point schedule.
        let rateRatio = Int(ratio)
        let last = emphasized.count-1
        if settings.performance.soundSynthesisIntegerSchedule, ratio.rounded() == ratio, ratio >= 1,
           rateRatio <= 4096 {
            let base = rfStart-Int64(rateRatio)*pcmStart
            let baseIndex = base >= 0 ? base/Int64(rateRatio)
                : -((-base+Int64(rateRatio)-1)/Int64(rateRatio))
            var index = Int(baseIndex), remainder = Int(base-baseIndex*Int64(rateRatio))
            let step = Float(rateRatio)
            for n in angles.indices {
                let fraction = Float(remainder)/step
                let a = index <= 0 ? previousEmphasized : emphasized[min(index-1,last)]
                let b = index < 0 ? previousEmphasized : emphasized[min(index,last)]
                phase += modulationStep * Double(a+(b-a)*fraction)
                angles[n] = Float(phase)
                if n & 1023 == 0 { phase = phase.remainder(dividingBy: 2 * .pi) }
                remainder += 1
                if remainder == rateRatio { remainder = 0; index += 1 }
            }
        } else {
            for n in angles.indices {
                let position = (Double(rfStart)+Double(n))/ratio-Double(pcmStart)
                let j = Int(floor(position)), fraction = Float(position-Double(j))
                let a = j <= 0 ? previousEmphasized : emphasized[min(j-1,last)]
                let b = j < 0 ? previousEmphasized : emphasized[min(j,last)]
                phase += modulationStep * Double(a+(b-a)*fraction)
                angles[n] = Float(phase)
                if n & 1023 == 0 { phase = phase.remainder(dividingBy: 2 * .pi) }
            }
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
        overmodulated = limited
        return TVSoundIQ(system: system,frameIndex: frameIndex,sampleRate: rate,i: i,q: q)
    }
}
