import Foundation
import AppKit
import AnalogCore

public enum HaldLUT {
    /// Read LUT samples verbatim: an ICC profile on this PNG is not a photo profile.
    /// NSBitmapImageRep.getPixel preserves 8/16-bit sample values without NSColor conversion.
    public static func load(data: Data) throws -> CubeLUT {
        guard let bitmap = NSBitmapImageRep(data: data), bitmap.pixelsWide == bitmap.pixelsHigh,
              !bitmap.isPlanar, [8,16].contains(bitmap.bitsPerSample),
              (1...4).contains(bitmap.samplesPerPixel), !bitmap.bitmapFormat.contains(.floatingPointSamples) else {
            throw CubeLUT.ParseError.invalid("Expected square RGB/RGBA 8/16-bit Hald PNG")
        }
        let side = bitmap.pixelsWide
        let level = Int(Double(side).cubeRoot.rounded())
        guard level >= 2, level*level*level == side else { throw CubeLUT.ParseError.invalid("Invalid Hald dimensions") }
        let dimension = level*level
        guard dimension <= 256 else { throw CubeLUT.ParseError.invalid("Hald cube too large") }
        var values = [Float](); values.reserveCapacity(side*side*4)
        var samples = [Int](repeating: 0,count: bitmap.samplesPerPixel)
        let maxSample = Float((1 << bitmap.bitsPerSample)-1)
        let alphaFirst = bitmap.bitmapFormat.contains(.alphaFirst)
        let offset = bitmap.hasAlpha && alphaFirst ? 1 : 0
        let colorChannels = bitmap.samplesPerPixel - (bitmap.hasAlpha ? 1 : 0)
        guard colorChannels == 1 || colorChannels == 3 else { throw CubeLUT.ParseError.invalid("Unsupported Hald channels") }
        for y in 0..<side { for x in 0..<side {
            bitmap.getPixel(&samples,atX: x,y: y)
            if bitmap.hasAlpha, samples[alphaFirst ? 0 : bitmap.samplesPerPixel-1] != Int(maxSample) {
                throw CubeLUT.ParseError.invalid("Hald samples must be opaque")
            }
            for c in 0..<3 { values.append(Float(samples[offset + (colorChannels == 1 ? 0 : c)])/maxSample) }
            values.append(1)
        } }
        return try CubeLUT(dimension: dimension,rgba: values)
    }
}

private extension Double {
    var cubeRoot: Double { pow(self,1.0/3.0) }
}
