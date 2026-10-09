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

public struct EffectSettings: Codable, Hashable, Sendable {
    public var lutMix: Float = 1
    /// Scene exposure before a scene-to-display LUT (PoLUT); ignored for display looks.
    public var lutExposureEV: Float = 0
    public var grain = GrainSettings()
    public var leak = LightLeakSettings()
    public init() {}
    public var validated: Self {
        func limit(_ value: Float,_ low: Float,_ high: Float,_ fallback: Float) -> Float {
            value.isFinite ? min(high,max(low,value)) : fallback
        }
        var s = self
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
