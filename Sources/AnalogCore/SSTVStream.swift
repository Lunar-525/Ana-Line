import Foundation

/// Stateful FM receiver. Incremental and one-shot processing share the same DSP.
public struct SSTVReceiver: Sendable {
    public let transmission: SSTVTransmission
    public private(set) var cursor = 0
    public private(set) var receivedRows = 0
    private var frequency: [Float]
    private var previous = SIMD2<Float>(1,0)
    private var phase: Float = 0, interferencePhase: Float = 0
    private var clockOffset: Double = 0
    private var rng: UInt32 = 42
    private var lastSeed: UInt32?
    private var reconstructed: SSTVFrame
    public init(transmission: SSTVTransmission) {
        self.transmission = transmission
        frequency = [Float](repeating: 1900,count: transmission.samples.count)
        reconstructed = SSTVFrame(rgb: [SIMD3<Float>](repeating: .zero,count: transmission.original.rgb.count),mode: transmission.original.mode)
    }
    public var progress: Double { Double(cursor)/Double(transmission.samples.count) }
    public var complete: Bool { cursor >= transmission.samples.count }
    private mutating func random() -> Float {
        rng ^= rng << 13; rng ^= rng >> 17; rng ^= rng << 5
        return Float(rng >> 8)/16777216
    }
    /// Microphone is actual complex downconverted audio. At accelerated speeds the
    /// most recent chunk repeats; it is never replaced by random noise/RMS values.
    public mutating func advance(to end: Int,settings: SSTVSettings,
                                 microphone: [SIMD2<Float>] = [],micGain: Float = 0) throws {
        let s = settings.validated, count = transmission.samples.count
        let target = min(count,max(cursor,end)), start = cursor
        let gain = micGain.isFinite ? min(20,max(0,micGain)) : 0
        if lastSeed != s.seed {
            rng = s.seed == 0 ? 0x12345678 : s.seed; lastSeed = s.seed
        }
        let factor = 2*Float.pi/Float(SSTVEngine.sampleRate)
        var channel = SSTVChannelState.at(sample: cursor,total: count,settings: s)
        for i in cursor..<target {
            if i%4096 == 0 { try Task.checkCancellation() }
            if i%120 == 0 { channel = SSTVChannelState.at(sample: i,total: count,settings: s) }
            // Integrate clock-rate error. Multiplying absolute time by a changing ppm
            // would introduce nonphysical jumps whenever the rate changes.
            let position = Double(i)+clockOffset
            clockOffset += Double(channel.clockPPM)/1_000_000
            let index = min(count-1,max(0,Int(position))), next = min(count-1,index+1)
            let frac = Float(min(1,max(0,position-Double(index))))
            var v = transmission.samples[index]+(transmission.samples[next]-transmission.samples[index])*frac
            phase += factor*(channel.offset+1900*channel.clockPPM/1_000_000)
            interferencePhase += factor*(channel.interferenceHz-1900)
            if i%1024 == 0 {
                phase.formTruncatingRemainder(dividingBy: 2*Float.pi)
                interferencePhase.formTruncatingRemainder(dividingBy: 2*Float.pi)
            }
            let r = SIMD2<Float>(cos(phase),sin(phase))
            v = SIMD2(v.x*r.x-v.y*r.y,v.x*r.y+v.y*r.x)
            v *= channel.gain
            let lost = SSTVEngine.hash(UInt32(i/1200) &+ s.seed &* 31) < channel.dropout && i%1200 >= 120 && i%1200 < 960
            if lost { v = .zero }
            let nr = random()+random()+random()-1.5, ni = random()+random()+random()-1.5
            v += SIMD2(nr,ni)*channel.noise
            v += SIMD2(cos(interferencePhase),sin(interferencePhase))*channel.interference
            if gain > 0 && !microphone.isEmpty { v += microphone[(i-start)%microphone.count]*gain }
            let cross = v.y*previous.x-v.x*previous.y, dot = v.x*previous.x+v.y*previous.y
            frequency[i] = (v.x*v.x+v.y*v.y < 1e-10) ? 1900 : 1900+atan2(cross,dot)/factor
            previous = v
        }
        cursor = target
    }
    /// Commit newly received line pairs. Later control changes cannot rewrite their signal history.
    public mutating func snapshot(settings: SSTVSettings) -> SSTVFrame {
        let mode = transmission.original.mode, width = mode.width
        // Segment boundaries are cumulatively rounded to the nearest PCM sample.
        // Account for that half-sample quantization when committing the last row.
        let completeLines = max(0,Int(floor(((Double(cursor)+0.500001)/12000-SSTVEngine.headerSeconds)/mode.lineSeconds)))
        let rows = min(mode.height,completeLines*mode.rowsPerLine)/mode.commitRows*mode.commitRows
        if rows > receivedRows {
            var rawSettings = settings; rawSettings.mix = 1
            let decoded = SSTVEngine.decodeFrequencies(frequency,original: transmission.original,settings: rawSettings)
            for i in receivedRows*width..<rows*width { reconstructed.rgb[i] = decoded.rgb[i] }
            receivedRows = rows
        }
        var output = reconstructed
        let mix = settings.validated.mix
        for i in 0..<receivedRows*width {
            output.rgb[i] = transmission.original.rgb[i]+(output.rgb[i]-transmission.original.rgb[i])*mix
        }
        return output
    }
    /// Audible real TX waveform; the original continuous phase is retained.
    public func txAudio(in range: Range<Int>) -> [Float] {
        let factor = 2*Double.pi*1900/Double(SSTVEngine.sampleRate)
        return range.clamped(to: 0..<transmission.samples.count).map { i in
            let phase = Double(i+1)*factor, p = transmission.samples[i]
            return 0.2*(p.x*Float(cos(phase))-p.y*Float(sin(phase)))
        }
    }
}

/// Real PCM -> complex envelope around 1900Hz, two-pole 1kHz low-pass.
/// This retains the microphone waveform's frequencies and phase, not just its level.
public struct SSTVMicrophoneMixer: Sendable {
    private var phase: Float = 0
    private var low1 = SIMD2<Float>.zero, low2 = SIMD2<Float>.zero
    public init() {}
    public mutating func convert(_ pcm: [Float]) -> [SIMD2<Float>] {
        let step = 2*Float.pi*1900/12000
        let alpha: Float = 1-exp(-2*Float.pi*1000/12000)
        return pcm.map { sample in
            let value = sample.isFinite ? min(1,max(-1,sample)) : 0
            phase += step; if phase > 2*Float.pi { phase -= 2*Float.pi }
            let mixed = SIMD2<Float>(cos(phase),-sin(phase))*(2*value)
            low1 += alpha*(mixed-low1); low2 += alpha*(low1-low2)
            return low2
        }
    }
}

/// Streaming PCM downsampler for hardware input. Two-pole anti-alias smoothing,
/// followed by rate accumulation; state survives microphone callback boundaries.
public struct SSTVPCMResampler: Sendable {
    private var accumulator: Double = 0
    private var low1: Float = 0, low2: Float = 0
    public init() {}
    public mutating func convert(_ samples: [Float],inputRate: Double) -> [Float] {
        guard inputRate.isFinite, (8000...192000).contains(inputRate) else { return [] }
        let alpha = Float(1-exp(-2*Double.pi*4000/inputRate))
        var result = [Float](); result.reserveCapacity(Int(Double(samples.count)*12000/inputRate)+1)
        for sample in samples {
            let value = sample.isFinite ? sample : 0
            low1 += alpha*(value-low1); low2 += alpha*(low1-low2)
            accumulator += 12000
            while accumulator >= inputRate { accumulator -= inputRate; result.append(low2) }
        }
        return result
    }
}
