import Foundation

/// 4fsc composite timing. The clock is continuous, including between frames.
public enum TVStandard: String, CaseIterable, Codable, Sendable {
    case pal, ntsc
    public var width: Int { 720 }
    public var height: Int { self == .pal ? 576 : 480 }
    public var displayAspectRatio: Double { 4.0/3.0 }
    public var squarePixelWidth: Int { height*4/3 }
    public var pixelAspect: String { self == .pal ? "16/15" : "8/9" }
    public var totalLines: Int { self == .pal ? 625 : 525 }
    public var subcarrierHz: Double { self == .pal ? 4_433_618.75 : 3_579_545.4545454546 }
    public var sampleRate: Double { 4 * subcarrierHz }
    public var lineDuration: Double { self == .pal ? 64e-6 : 227.5 / subcarrierHz }
    public var frameDuration: Double { lineDuration * Double(totalLines) }
    public var frameRate: Double { 1 / frameDuration }
    public var ffmpegFrameRate: String { self == .pal ? "25" : "30000/1001" }
    public var samplesPerLine: Double { sampleRate * lineDuration }
    public var activeStart: Double { self == .pal ? 10.5e-6 : 9.4e-6 }
    public var activeDuration: Double { self == .pal ? 52e-6 : 52.66e-6 }
    public var syncDuration: Double { 4.7e-6 }
    public var burstStart: Double { 5.6e-6 }
    public var burstDuration: Double { self == .pal ? 10 / subcarrierHz : 9 / subcarrierHz }
    var equalizingCount: Int { self == .pal ? 5 : 6 }
    var firstActiveLine: Int { self == .pal ? 22 : 20 }
    /// Active line starts share their field's sync grid, including field 2's half-line offset.
    func activeLine(_ row: Int) -> Double {
        Double(firstActiveLine + row / 2) + (row % 2 == 0 ? 0 : Double(totalLines) / 2)
    }
    func palLineSign(_ line: Double, frameIndex: Int64) -> Float {
        let absoluteLine = frameIndex * Int64(totalLines) + Int64(line.rounded(.down))
        return absoluteLine % 2 == 0 ? 1 : -1
    }
    public func sampleOffset(frame: Int64) -> Int64 {
        Int64((Double(frame) * frameDuration * sampleRate).rounded(.down))
    }
}

/// Gamma-encoded RGB in [0,1], unlike the linear-light Raster used by film effects.
public struct TVFrame: Sendable {
    public let standard: TVStandard
    public var rgb: [SIMD3<Float>]
    public init(standard: TVStandard, rgb: [SIMD3<Float>]) throws {
        guard rgb.count == standard.width * standard.height,
              rgb.allSatisfy({ $0.x.isFinite && $0.y.isFinite && $0.z.isFinite }) else {
            throw TVError.invalidFrame
        }
        self.standard = standard; self.rgb = rgb
    }
    public static func colorBars(_ standard: TVStandard) -> TVFrame {
        let colors: [SIMD3<Float>] = [SIMD3(1,1,1), SIMD3(1,1,0), SIMD3(0,1,1), SIMD3(0,1,0),
                                    SIMD3(1,0,1), SIMD3(1,0,0), SIMD3(0,0,1), .zero]
        return try! TVFrame(standard: standard, rgb: (0..<standard.width*standard.height).map {
            colors[($0 % standard.width) * 8 / standard.width] * 0.75
        })
    }
}

public enum TVError: Error, LocalizedError {
    case invalidFrame, invalidSignal, syncLost, invalidSettings
    public var errorDescription: String? {
        switch self {
        case .invalidFrame: "Invalid TV frame dimensions or non-finite RGB pixels"
        case .invalidSignal: "Invalid or incomplete 4fsc composite frame"
        case .syncLost: "Unable to recover television synchronization"
        case .invalidSettings: "Invalid television channel settings"
        }
    }
}

/// One complete interlaced frame, sync=-0.3, blanking/black=0, white=0.7 volts.
/// NTSC uses zero setup (NTSC-J/baseband convention), not NTSC-M's 7.5 IRE pedestal.
public struct CompositeVideo: Sendable {
    public let standard: TVStandard
    public let frameIndex: Int64
    public var samples: [Float]
    public init(standard: TVStandard, frameIndex: Int64, samples: [Float]) throws {
        guard frameIndex >= 0, frameIndex < 1_000_000_000,
              samples.count == Int(standard.sampleOffset(frame: frameIndex + 1) - standard.sampleOffset(frame: frameIndex)),
              samples.allSatisfy(\.isFinite) else { throw TVError.invalidSignal }
        self.standard = standard; self.frameIndex = frameIndex; self.samples = samples
    }
}

public enum TVSeparation: String, Codable, Sendable { case notch, comb }
public struct TVChannelSettings: Codable, Sendable {
    /// RMS noise in volts, applied to composite samples before decoding.
    public var noise: Float = 0
    public var gain: Float = 1
    public var bandwidthMHz: Float = 6
    public var ghostGain: Float = 0
    public var ghostDelayMicroseconds: Float = 2
    public var seed: UInt64 = 42
    public init() {}
}
public struct TVDecoderSettings: Codable, Equatable, Sendable {
    public var separation: TVSeparation = .notch
    public var palDelayLine = true
    public var combFailure: Float = 0
    public var chromaLeakage: Float = 0
    public init() {}
    func validate() throws {
        guard combFailure.isFinite, (0...1).contains(combFailure),
              chromaLeakage.isFinite, (0...1).contains(chromaLeakage) else { throw TVError.invalidSettings }
    }
}
public struct TVDecodeResult: Sendable {
    public let frame: TVFrame
    public let recoveredLines: Int
    public let colorLockedLines: Int
    public let meanBurstAmplitude: Float
}
