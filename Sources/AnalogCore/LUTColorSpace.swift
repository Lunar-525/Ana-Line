import Foundation
import simd

/// D65 RGB spaces. No silent fallback for unsupported log/HDR encodings.
public enum LUTColorSpace: String, Codable, Sendable {
    case srgb, adobeRGB1998, linearSRGB, displayP3, rec709
    public var label: String {
        switch self {
        case .srgb: "sRGB"
        case .adobeRGB1998: "Adobe RGB (1998)"
        case .linearSRGB: "Linear sRGB"
        case .displayP3: "Display P3"
        case .rec709: "Rec.709 OETF"
        }
    }
    private var matrix: simd_float3x3 {
        func rows(_ a: SIMD3<Float>,_ b: SIMD3<Float>,_ c: SIMD3<Float>) -> simd_float3x3 {
            simd_float3x3(rows: [a,b,c])
        }
        switch self {
        case .srgb,.linearSRGB,.rec709:
            return rows(SIMD3(0.4124564,0.3575761,0.1804375),SIMD3(0.2126729,0.7151522,0.0721750),SIMD3(0.0193339,0.1191920,0.9503041))
        case .adobeRGB1998:
            return rows(SIMD3(0.5767309,0.1855540,0.1881852),SIMD3(0.2973769,0.6273491,0.0752741),SIMD3(0.0270343,0.0706872,0.9911085))
        case .displayP3:
            return rows(SIMD3(0.48657095,0.26566769,0.19821729),SIMD3(0.22897456,0.69173852,0.07928691),SIMD3(0,0.04511338,1.04394437))
        }
    }
    private func decode(_ v: Float) -> Float {
        let sign: Float = v < 0 ? -1 : 1, x = abs(v)
        switch self {
        case .linearSRGB: return v
        case .srgb,.displayP3: return sign*(x <= 0.04045 ? x/12.92 : pow((x+0.055)/1.055,2.4))
        case .adobeRGB1998: return sign*pow(x,563/256)
        case .rec709: return sign*(x < 0.081 ? x/4.5 : pow((x+0.099)/1.099,1/0.45))
        }
    }
    private func encode(_ v: Float) -> Float {
        let sign: Float = v < 0 ? -1 : 1, x = abs(v)
        switch self {
        case .linearSRGB: return v
        case .srgb,.displayP3: return sign*(x <= 0.0031308 ? x*12.92 : 1.055*pow(x,1/2.4)-0.055)
        case .adobeRGB1998: return sign*pow(x,256/563)
        case .rec709: return sign*(x < 0.018 ? 4.5*x : 1.099*pow(x,0.45)-0.099)
        }
    }
    public func convert(_ rgb: SIMD3<Float>, to output: LUTColorSpace) -> SIMD3<Float> {
        if self == output { return rgb }
        let linear = SIMD3<Float>(decode(rgb.x),decode(rgb.y),decode(rgb.z))
        let value = output.matrix.inverse * (matrix * linear)
        return SIMD3<Float>(output.encode(value.x),output.encode(value.y),output.encode(value.z))
    }
}

public struct LUTTransform: Sendable {
    public let cube: CubeLUT
    public let input: LUTColorSpace
    public let output: LUTColorSpace
    public let compressOutputGamut: Bool
    public let inputExposureEV: Float
    public init(cube: CubeLUT,input: LUTColorSpace,output: LUTColorSpace,
                compressOutputGamut: Bool = false,inputExposureEV: Float = 0) {
        self.cube = cube; self.input = input; self.output = output
        self.compressOutputGamut = compressOutputGamut
        self.inputExposureEV = inputExposureEV.isFinite ? min(3,max(-3,inputExposureEV)) : 0
    }
    public func applyToSRGB(_ rgb: SIMD3<Float>) -> SIMD3<Float> {
        let encoded: SIMD3<Float>
        if inputExposureEV == 0 {
            encoded = LUTColorSpace.srgb.convert(rgb,to: input)
        } else {
            let scene = LUTColorSpace.srgb.convert(rgb,to: .linearSRGB)*pow(2,inputExposureEV)
            encoded = LUTColorSpace.linearSRGB.convert(scene,to: input)
        }
        let result = output.convert(cube.sample(encoded),to: .srgb)
        return compressOutputGamut ? Self.compressToSRGB(result) : result
    }
    /// SDR output policy, separate from the source LUT. Radial chroma compression
    /// in linear sRGB preserves luminance and the RGB direction from neutral.
    /// A soft knee at 80% of the gamut boundary avoids per-channel clipping.
    public static func compressToSRGB(_ rgb: SIMD3<Float>) -> SIMD3<Float> {
        let linear = LUTColorSpace.srgb.convert(rgb,to: .linearSRGB)
        let y = linear.x*0.2126729 + linear.y*0.7151522 + linear.z*0.0721750
        guard y > 0 else { return .zero }
        guard y < 1 else { return SIMD3(repeating: 1) }
        let delta = linear-SIMD3<Float>(repeating: y)
        var ratio: Float = 0
        for c in 0..<3 {
            ratio = max(ratio,delta[c] >= 0 ? delta[c]/(1-y) : -delta[c]/y)
        }
        guard ratio > 0.8 else { return rgb }
        let compressed = 0.8 + 0.2*(1-exp(-(ratio-0.8)/0.2))
        let mapped = SIMD3<Float>(repeating: y)+delta*(compressed/ratio)
        return LUTColorSpace.linearSRGB.convert(mapped,to: .srgb)
    }
    /// Bake conversions + domain + source LUT into one GPU-friendly sRGB cube.
    public func compiled(dimension: Int = 65) throws -> CubeLUT {
        guard (2...128).contains(dimension) else { throw CubeLUT.ParseError.invalid("Invalid compile dimension") }
        var data = [Float](); data.reserveCapacity(dimension*dimension*dimension*4)
        let divisor = Float(dimension-1)
        for b in 0..<dimension { for g in 0..<dimension { for r in 0..<dimension {
            let p = applyToSRGB(SIMD3<Float>(Float(r)/divisor,Float(g)/divisor,Float(b)/divisor))
            data.append(contentsOf: [p.x,p.y,p.z,1])
        } } }
        return try CubeLUT(dimension: dimension,rgba: data)
    }
}
