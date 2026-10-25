import Foundation

public struct GrainSettings: Codable, Hashable, Sendable {
    public var amount: Float = 0.2
    /// Diameter in pixels at a reference short edge of 1000 pixels.
    public var size: Float = 1.5
    /// Width of the approximated log-normal crystal radius distribution.
    public var texture: Float = 0.5
    /// Scanner blur as a fraction of grain size, in addition to the pixel aperture.
    public var blur: Float = 0.15
    public var seed: UInt32 = 42
    public init() {}
}

public struct LightLeakSettings: Codable, Hashable, Sendable {
    public var amount: Float = 0
    public var x: Float = 0
    public var y: Float = 0.5
    /// Width and length relative to the image's short edge.
    public var width: Float = 0.25
    public var length: Float = 1
    public var rotation: Float = 0
    public var hue: Float = 20
    public var softness: Float = 0.65
    public var irregularity: Float = 0.4
    public var seed: UInt32 = 73
    public init() {}
}

/// Artistic black-and-white negative processing, displayed as a scanned positive.
/// Values describe relative processing, not calibrated chemical times or temperatures.
public struct FilmProcessSettings: Codable, Hashable, Sendable {
    public var enabled = false
    public var exposureEV: Float = 0
    public var development: Float = 1
    public var agitation: Float = 1
    public var stop: Float = 1
    public var fixation: Float = 1
    public var wash: Float = 1
    public var drying: Float = 1
    public var seed: UInt32 = 137
    public init() {}
}

public struct EffectSettings: Codable, Hashable, Sendable {
    public var lutMix: Float = 1
    /// Scene exposure before a scene-to-display LUT (PoLUT); ignored for display looks.
    public var lutExposureEV: Float = 0
    public var laboratory: FilmLabSession?
    public var laboratoryDisplay: Int = 0
    public var process = FilmProcessSettings()
    public var grain = GrainSettings()
    public var leak = LightLeakSettings()
    public init() {}
    private enum CodingKeys: String, CodingKey { case lutMix, lutExposureEV, grain, leak, process, laboratory, laboratoryDisplay }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        lutMix = try c.decodeIfPresent(Float.self,forKey: .lutMix) ?? 1
        lutExposureEV = try c.decodeIfPresent(Float.self,forKey: .lutExposureEV) ?? 0
        grain = try c.decodeIfPresent(GrainSettings.self,forKey: .grain) ?? GrainSettings()
        leak = try c.decodeIfPresent(LightLeakSettings.self,forKey: .leak) ?? LightLeakSettings()
        laboratoryDisplay = try c.decodeIfPresent(Int.self,forKey: .laboratoryDisplay) ?? 0
        laboratory = try c.decodeIfPresent(FilmLabSession.self,forKey: .laboratory)
        process = try c.decodeIfPresent(FilmProcessSettings.self,forKey: .process) ?? FilmProcessSettings()
    }
    public var validated: Self {
        func limit(_ value: Float,_ low: Float,_ high: Float,_ fallback: Float) -> Float {
            value.isFinite ? min(high,max(low,value)) : fallback
        }
        var s = self
        s.process.exposureEV = limit(s.process.exposureEV,-4,4,0)
        s.process.development = limit(s.process.development,0.25,2,1)
        s.process.agitation = limit(s.process.agitation,0,1,1)
        s.process.stop = limit(s.process.stop,0,1,1)
        s.process.fixation = limit(s.process.fixation,0,1,1)
        s.process.wash = limit(s.process.wash,0,1,1)
        s.process.drying = limit(s.process.drying,0,1,1)
        s.lutMix = limit(s.lutMix,0,1,1)
        s.lutExposureEV = limit(s.lutExposureEV,-3,3,0)
        s.grain.amount = limit(s.grain.amount,0,1,0)
        s.grain.size = limit(s.grain.size,0.5,8,1.5)
        s.grain.texture = limit(s.grain.texture,0,1,0.5)
        s.grain.blur = limit(s.grain.blur,0,2,0.15)
        s.leak.amount = limit(s.leak.amount,0,1,0)
        s.leak.x = limit(s.leak.x,0,1,0)
        s.leak.y = limit(s.leak.y,0,1,0.5)
        s.leak.width = limit(s.leak.width,0.03,1,0.25)
        s.leak.length = limit(s.leak.length,0.1,2,1)
        s.leak.rotation = limit(s.leak.rotation,-180,180,0)
        s.leak.hue = limit(s.leak.hue,0,360,20)
        s.leak.softness = limit(s.leak.softness,0,1,0.65)
        s.leak.irregularity = limit(s.leak.irregularity,0,1,0.4)
        return s
    }
}
