import Foundation

public struct SSTVSettings: Hashable, Sendable {
    public var mode: SSTVMode = .robot36
    public var noise: Float = 0
    public var frequencyOffset: Float = 0
    /// Total frequency change across the transmission, in Hz.
    public var drift: Float = 0
    public var clockPPM: Float = 0
    public var dropout: Float = 0
    public var interference: Float = 0
    public var interferenceHz: Float = 1900
    /// Zero gives the calibrated stationary baseline. Nonzero adds correlated wandering/fades/bursts.
    public var variation: Float = 0
    public var variationSeconds: Float = 2
    public var mix: Float = 1
    public var trackSync = false
    public var seed: UInt32 = 42
    public init() {}
    public var validated: Self {
        func clamp(_ x: Float,_ a: Float,_ b: Float,_ fallback: Float = 0) -> Float {
            x.isFinite ? min(b,max(a,x)) : fallback
        }
        var s = self
        s.noise = clamp(s.noise,0,1); s.frequencyOffset = clamp(s.frequencyOffset,-400,400)
        s.drift = clamp(s.drift,-400,400); s.clockPPM = clamp(s.clockPPM,-3000,3000)
        s.dropout = clamp(s.dropout,0,0.6); s.interference = clamp(s.interference,0,1)
        s.interferenceHz = clamp(s.interferenceHz,1000,2800,1900); s.mix = clamp(s.mix,0,1,1)
        s.variation = clamp(s.variation,0,1)
        s.variationSeconds = clamp(s.variationSeconds,0.2,8,2)
        return s
    }
}

/// Opaque encoded sRGB, top row first, at the selected mode's dimensions.
public struct SSTVFrame: Sendable {
    public static let width = 320, height = 240
    public let mode: SSTVMode
    public var rgb: [SIMD3<Float>]
    public init(rgb: [SIMD3<Float>], mode: SSTVMode = .robot36) {
        precondition(rgb.count == mode.width*mode.height)
        self.mode = mode; self.rgb = rgb
    }
}

public struct SSTVTransmission: Sendable {
    /// Complex envelope around 1900 Hz, mathematically equivalent to analytic audio.
    public let samples: [SIMD2<Float>]
    public let original: SSTVFrame
    public var duration: Double { Double(samples.count)/Double(SSTVEngine.sampleRate) }
}

public enum SSTVEngine {
    public static let sampleRate = 12000
    public static let headerSeconds = 0.91
    public static let lineSeconds = 0.15
    private static func clamp(_ x: Float) -> Float { min(1,max(0,x)) }
    static func hash(_ value: UInt32) -> Float {
        var v = value
        v = (v ^ (v >> 16)) &* 0x7feb352d
        v = (v ^ (v >> 15)) &* 0x846ca68b
        return Float((v ^ (v >> 16)) >> 8)/16777216
    }
    private static func ycc(_ rgb: SIMD3<Float>) -> SIMD3<Float> {
        let y = rgb.x*0.299+rgb.y*0.587+rgb.z*0.114
        return SIMD3(y,0.5+(rgb.z-y)*0.564334,0.5+(rgb.x-y)*0.713267)
    }
    /// Selected-mode VIS, component scans and synchronization segments.
    /// Continuous phase and cumulative timing prevent per-pixel rounding drift.
    public static func encode(_ frame: SSTVFrame) throws -> SSTVTransmission {
        var samples = [SIMD2<Float>](); samples.reserveCapacity(Int(frame.mode.duration*12000))
        var end: Double = 0, phase: Double = 0
        let scale = 2*Double.pi/Double(sampleRate)
        func tone(_ frequency: Float,_ seconds: Double) {
            end += seconds*Double(sampleRate)
            let target = Int(end.rounded()), step = Double(frequency-1900)*scale
            while samples.count < target {
                phase += step
                samples.append(SIMD2(Float(cos(phase)),Float(sin(phase))))
            }
            phase.formTruncatingRemainder(dividingBy: 2*Double.pi)
        }
        tone(1900,0.3); tone(1200,0.01); tone(1900,0.3); tone(1200,0.03)
        var ones = 0
        for bit in 0..<7 {
            let one = (frame.mode.vis >> bit)&1; ones += one
            tone(one == 1 ? 1100 : 1300,0.03)
        }
        tone(ones%2 == 1 ? 1100 : 1300,0.03); tone(1200,0.03)
        let mode = frame.mode, width = mode.width
        let values = frame.rgb.map(ycc)
        for row in stride(from: 0,to: mode.height,by: mode.rowsPerLine) {
            try Task.checkCancellation()
            for segment in mode.segments(row: row) {
                if let component = segment.component {
                    for x in 0..<width {
                        let index = row*width+x
                        let value: Float
                        switch component {
                        case .red: value = frame.rgb[index].x
                        case .green: value = frame.rgb[index].y
                        case .blue: value = frame.rgb[index].z
                        case .y: value = values[index].x
                        case .yNext: value = values[index+width].x
                        case .cr: value = mode == .pd120 ? (values[index].z+values[index+width].z)/2 : values[index].z
                        case .cb: value = mode == .pd120 ? (values[index].y+values[index+width].y)/2 : values[index].y
                        }
                        tone(1500+800*clamp(value),segment.seconds/Double(width))
                    }
                } else { tone(segment.frequency,segment.seconds) }
            }
        }
        return SSTVTransmission(samples: samples,original: frame)
    }

    /// Offline complex-baseband channel: no sound device, WAV I/O, or wall-clock pacing.
    public static func receive(_ tx: SSTVTransmission,settings: SSTVSettings) throws -> SSTVFrame {
        if settings.validated.mix == 0 { return tx.original }
        var receiver = SSTVReceiver(transmission: tx)
        try receiver.advance(to: tx.samples.count,settings: settings)
        return receiver.snapshot(settings: settings)
    }

    /// Exposed for independent encoder fixtures and protocol timing tests.
    public static func decodeFrequencies(_ frequency: [Float],original: SSTVFrame,settings: SSTVSettings) -> SSTVFrame {
        let s = settings.validated, rate = Double(sampleRate)
        func average(_ start: Double,_ duration: Double) -> Float {
            // Average frequency over each pixel's dwell with fractional sample coverage.
            let lo = start*rate, hi = (start+duration)*rate
            var total: Float = 0, weight: Float = 0
            for i in Int(floor(lo))..<Int(ceil(hi)) where i >= 0 && i < frequency.count {
                let w = Float(max(0,min(hi,Double(i+1))-max(lo,Double(i))))
                total += frequency[i]*w; weight += w
            }
            return weight > 0 ? clamp((total/weight-1500)/800) : 0.5
        }
        let mode = original.mode, width = mode.width
        var rgb = original.rgb
        var y = [Float](repeating: 0,count: rgb.count), cr = y, cb = y
        for row in stride(from: 0,to: mode.height,by: mode.rowsPerLine) {
            let segments = mode.segments(row: row)
            var start = headerSeconds+Double(row/mode.rowsPerLine)*mode.lineSeconds
            if s.trackSync {
                let expected = start+mode.syncOffset
                let center = Int(expected*rate), radius = 540
                let lo = max(0,center-radius), hi = min(frequency.count,center+radius+Int(mode.syncSeconds*rate)+2)
                var run = 0, bestDistance = Int.max, found: Int?
                if lo < hi {
                    for i in lo..<hi {
                        if abs(frequency[i]-1200) < 90 { run += 1 } else {
                            if Double(run) >= mode.syncSeconds*rate*0.6 && Double(run) <= mode.syncSeconds*rate*1.4 {
                                let candidate = i-run, distance = abs(candidate-center)
                                if distance < bestDistance { bestDistance = distance; found = candidate }
                            }
                            run = 0
                        }
                    }
                }
                if let found { start = Double(found)/rate-mode.syncOffset }
            }
            for segment in segments {
                if let component = segment.component {
                    for x in 0..<width {
                        let value = average(start+Double(x)*segment.seconds/Double(width),segment.seconds/Double(width))
                        let i = row*width+x
                        switch component {
                        case .red: rgb[i].x = value
                        case .green: rgb[i].y = value
                        case .blue: rgb[i].z = value
                        case .y: y[i] = value
                        case .yNext: y[i+width] = value
                        case .cr: cr[i] = value; if mode == .pd120 { cr[i+width] = value }
                        case .cb: cb[i] = value; if mode == .pd120 { cb[i+width] = value }
                        }
                    }
                }
                start += segment.seconds
            }
        }
        if mode == .robot36 || mode == .pd120 {
            for row in 0..<mode.height { for x in 0..<width {
                let i = row*width+x
                let redChroma = cr[(mode == .robot36 ? row & ~1 : row)*width+x]-0.5
                let blueChroma = cb[(mode == .robot36 ? (row & ~1)+1 : row)*width+x]-0.5
                rgb[i] = SIMD3(clamp(y[i]+1.402*redChroma),clamp(y[i]-0.714136*redChroma-0.344136*blueChroma),clamp(y[i]+1.772*blueChroma))
            } }
        }
        for i in rgb.indices { rgb[i] = original.rgb[i]+(rgb[i]-original.rgb[i])*s.mix }
        return SSTVFrame(rgb: rgb,mode: mode)
    }
}
