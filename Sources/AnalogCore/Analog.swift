import Foundation

/// Straight-alpha, linear-sRGB pixels. Alpha is preserved by all effects.
public struct Raster: Sendable {
    public let width: Int
    public let height: Int
    public var pixels: [SIMD4<Float>]
    public init(width: Int, height: Int, pixels: [SIMD4<Float>]) {
        precondition(width > 0 && height > 0 && pixels.count == width * height)
        self.width = width; self.height = height; self.pixels = pixels
    }
}

public struct Recipe: Codable, Sendable {
    public var seed: UInt64 = 42
    public var film: Float = 0.7
    public var grain: Float = 0.25
    public var halation: Float = 0.3
    public var vignette: Float = 0.25
    public var lightLeak: Float = 0.15
    public var dust: Float = 0.2
    public var scratches: Float = 0.15
    public init() {}
}

private func clamp(_ x: Float) -> Float { min(1, max(0, x)) }
private func random(_ x: Int, _ y: Int, _ seed: UInt64) -> Float {
    var n = UInt64(truncatingIfNeeded: x) &* 0x9E3779B97F4A7C15
    n ^= UInt64(truncatingIfNeeded: y) &* 0xBF58476D1CE4E5B9; n ^= seed
    n = (n ^ (n >> 30)) &* 0xBF58476D1CE4E5B9
    n = (n ^ (n >> 27)) &* 0x94D049BB133111EB
    return Float((n ^ (n >> 31)) >> 40) / Float(1 << 24)
}

public enum AnalogEngine {
    /// CPU reference implementation. Process full frames; resizing the result preserves damage placement.
    public static func render(_ input: Raster, recipe r: Recipe) -> Raster {
        let w = input.width, h = input.height, short = Float(min(w, h))
        let film = clamp(r.film), grain = clamp(r.grain), halo = clamp(r.halation)
        let vignette = clamp(r.vignette), leak = clamp(r.lightLeak)
        let dust = clamp(r.dust), scratches = clamp(r.scratches)
        if film + grain + halo + vignette + leak + dust + scratches == 0 { return input }
        // Highlight energy in linear light, blurred using a separable Gaussian.
        var highlights = input.pixels.map { p -> Float in
            max(0, 0.2126*p.x + 0.7152*p.y + 0.0722*p.z - 0.65) * p.w
        }
        if halo > 0 {
            let radius = max(1, Int(short * 0.008)), sigma = max(0.5, Float(radius)/2)
            var kernel = (-radius...radius).map { exp(-Float($0*$0)/(2*sigma*sigma)) }
            let sum = kernel.reduce(0,+); kernel = kernel.map { $0/sum }
            var temp = highlights
            for y in 0..<h { for x in 0..<w {
                var v: Float = 0
                for k in -radius...radius { v += highlights[y*w + min(w-1,max(0,x+k))] * kernel[k+radius] }
                temp[y*w+x] = v
            } }
            for y in 0..<h { for x in 0..<w {
                var v: Float = 0
                for k in -radius...radius { v += temp[min(h-1,max(0,y+k))*w+x] * kernel[k+radius] }
                highlights[y*w+x] = v
            } }
        }
        var output = input
        // Seeded geometry is expressed in normalized coordinates, independent of image size.
        let dustCount = Int(dust * 100), scratchCount = Int(scratches * 12)
        let specks = (0..<dustCount).map { i in
            (random(i, 10, r.seed), random(i, 11, r.seed), 0.0008 + random(i, 12, r.seed)*0.003)
        }
        let lines = (0..<scratchCount).map { i in
            (random(i, 20, r.seed), random(i, 21, r.seed), random(i, 22, r.seed))
        }
        for y in 0..<h { for x in 0..<w {
            let i = y*w+x, p = input.pixels[i]
            let u = (Float(x)+0.5)/Float(w), v = (Float(y)+0.5)/Float(h)
            var c = SIMD3<Float>(p.x,p.y,p.z)
            // Creative negative-like approximation; not a measured film-stock model.
            for channel in 0..<3 {
                let a = clamp(c[channel]), curved = a*a*(3-2*a)
                c[channel] += film * (curved-a)*0.65
            }
            c += film * SIMD3<Float>(0.025*(1-c.x), 0.006, -0.018*c.z)
            c += highlights[i] * halo * SIMD3<Float>(0.8,0.16,0.035)
            let radial = (u-0.5)*(u-0.5) + (v-0.5)*(v-0.5)
            c *= 1 - vignette * min(1,radial*2)
            let side = random(0,30,r.seed) > 0.5 ? u : 1-u
            let glow = exp(-side*12) * (0.45+0.55*pow(sin(v*Float.pi),2)) * leak
            c += glow * SIMD3<Float>(0.8,0.15,0.025)
            let luma = clamp(c.x*0.2126+c.y*0.7152+c.z*0.0722)
            let noise = (random(x,y,r.seed)-0.5) + (random(x,y,r.seed &+ 1)-0.5)
            c += SIMD3<Float>(repeating: noise * grain * 0.10 * (0.25 + sqrt(luma*(1-luma))))
            for (sx,sy,size) in specks {
                let dx = (u-sx)*Float(w)/short, dy = (v-sy)*Float(h)/short
                let coverage = clamp((size-sqrt(dx*dx+dy*dy))*short+0.5)
                c *= 1-coverage*0.7
            }
            for (sx,start,length) in lines {
                if v >= start && v <= min(1,start+0.15+length*0.7) {
                    let center = sx + (v-start)*0.003*sin(v*18)
                    let coverage = clamp(1-abs(u-center)*Float(w))
                    c += SIMD3<Float>(repeating: coverage*scratches*0.35)
                }
            }
            output.pixels[i] = SIMD4<Float>(clamp(c.x),clamp(c.y),clamp(c.z),p.w)
        } }
        return output
    }
}
