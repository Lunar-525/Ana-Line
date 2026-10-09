import Foundation

/// Standard red-fastest 3D CUBE. Domain is applied before interpolation.
public struct CubeLUT: Sendable {
    public let dimension: Int
    public let rgba: [Float]
    public let domainMin: SIMD3<Float>
    public let domainMax: SIMD3<Float>
    public enum ParseError: Error { case invalid(String) }
    public init(text: String) throws {
        var size: Int?
        var values = [Float]()
        var low = SIMD3<Float>(repeating: 0), high = SIMD3<Float>(repeating: 1)
        for raw in text.components(separatedBy: .newlines) {
            let line = raw.components(separatedBy: "#")[0].trimmingCharacters(in: .whitespaces)
            if line.isEmpty { continue }
            let parts = line.split(whereSeparator: { $0.isWhitespace }).map(String.init)
            switch parts[0] {
            case "TITLE": continue
            case "LUT_3D_SIZE":
                guard parts.count == 2, let n = Int(parts[1]), (2...256).contains(n), size == nil else {
                    throw ParseError.invalid("Invalid LUT_3D_SIZE")
                }
                size = n
            case "DOMAIN_MIN", "DOMAIN_MAX":
                let numbers = parts.dropFirst().compactMap(Float.init)
                guard numbers.count == 3, numbers.allSatisfy(\.isFinite) else { throw ParseError.invalid("Invalid domain") }
                let vector = SIMD3<Float>(numbers[0],numbers[1],numbers[2])
                if parts[0] == "DOMAIN_MIN" { low = vector } else { high = vector }
            default:
                guard size != nil, parts.count == 3 else { throw ParseError.invalid("Unsupported CUBE entry") }
                let rgb = parts.compactMap(Float.init)
                guard rgb.count == 3, rgb.allSatisfy(\.isFinite) else { throw ParseError.invalid("Invalid RGB values") }
                values.append(contentsOf: rgb); values.append(1)
                guard values.count <= size!*size!*size!*4 else { throw ParseError.invalid("Too many entries") }
            }
        }
        guard let n = size, values.count == n*n*n*4 else { throw ParseError.invalid("Incomplete CUBE data") }
        guard high.x > low.x, high.y > low.y, high.z > low.z else { throw ParseError.invalid("Empty domain") }
        dimension = n; rgba = values; domainMin = low; domainMax = high
    }
    public init(dimension: Int, rgba: [Float]) throws {
        guard (2...256).contains(dimension), rgba.count == dimension*dimension*dimension*4,
              rgba.allSatisfy(\.isFinite) else { throw ParseError.invalid("Invalid cube buffer") }
        self.dimension = dimension; self.rgba = rgba
        domainMin = SIMD3<Float>(repeating: 0); domainMax = SIMD3<Float>(repeating: 1)
    }
    public func sample(_ rgb: SIMD3<Float>) -> SIMD3<Float> {
        let v = (rgb-domainMin)/(domainMax-domainMin)
        let x = min(1,max(0,v.x))*Float(dimension-1)
        let y = min(1,max(0,v.y))*Float(dimension-1)
        let z = min(1,max(0,v.z))*Float(dimension-1)
        let ix = min(dimension-2,Int(x)), iy = min(dimension-2,Int(y)), iz = min(dimension-2,Int(z))
        let fx = x-Float(ix), fy = y-Float(iy), fz = z-Float(iz)
        func point(_ x: Int,_ y: Int,_ z: Int) -> SIMD3<Float> {
            let i = (x+dimension*y+dimension*dimension*z)*4
            return SIMD3<Float>(rgba[i],rgba[i+1],rgba[i+2])
        }
        func mix(_ a: SIMD3<Float>,_ b: SIMD3<Float>,_ t: Float) -> SIMD3<Float> { a+(b-a)*t }
        let a = mix(point(ix,iy,iz),point(ix+1,iy,iz),fx)
        let b = mix(point(ix,iy+1,iz),point(ix+1,iy+1,iz),fx)
        let c = mix(point(ix,iy,iz+1),point(ix+1,iy,iz+1),fx)
        let d = mix(point(ix,iy+1,iz+1),point(ix+1,iy+1,iz+1),fx)
        return mix(mix(a,b,fy),mix(c,d,fy),fz)
    }
    public var data: Data { rgba.withUnsafeBytes { Data($0) } }
}
