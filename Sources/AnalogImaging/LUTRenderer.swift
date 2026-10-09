import Foundation
import CoreImage
import ImageIO
import AnalogCore

public actor LUTRenderer {
    private var context: CIContext?
    private var source: CIImage?
    private var generation = 0
    private var cache: [String: Data] = [:]
    private var order: [String] = []
    private var grades: [String: CIImage] = [:]
    private var gradeOrder: [String] = []
    private var effects: AnalogEffects?
    public init() {}
    public struct SourceInfo: Sendable {
        public let original: Data
        public let width: Int
        public let height: Int
        public let profile: String
    }
    public struct Preview: Sendable {
        public let data: Data
        public let seconds: TimeInterval
        public let cached: Bool
    }
    public struct DisplayPreview: @unchecked Sendable {
        // CGImage is immutable and may safely cross to the main actor.
        public let image: CGImage
        public let seconds: TimeInterval
    }
    private var srgb: CGColorSpace { CGColorSpace(name: CGColorSpace.sRGB)! }
    private func png(_ image: CIImage) throws -> Data {
        if context == nil { context = CIContext(options: [.workingColorSpace: srgb,.outputColorSpace: srgb]) }
        guard let data = context!.pngRepresentation(of: image,format: .RGBA8,colorSpace: srgb) else { throw CocoaError(.fileWriteUnknown) }
        return data
    }
    public func loadSource(_ url: URL) throws -> SourceInfo {
        guard let file = CGImageSourceCreateWithURL(url as CFURL,nil),
              let cg = CGImageSourceCreateThumbnailAtIndex(file,0,[
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: 1400
              ] as CFDictionary) else { throw CocoaError(.fileReadCorruptFile) }
        guard cg.colorSpace?.model == .rgb || cg.colorSpace?.model == .monochrome else {
            throw CubeLUT.ParseError.invalid("Only RGB and grayscale source images are supported")
        }
        let image = CIImage(cgImage: cg) // Honors the source ICC. Conversion to working sRGB is automatic.
        let original = try png(image)
        generation += 1; source = image; cache.removeAll(); order.removeAll()
        grades.removeAll(); gradeOrder.removeAll()
        let properties = CGImageSourceCopyPropertiesAtIndex(file,0,nil) as? [CFString: Any]
        let profile = properties?[kCGImagePropertyProfileName] as? String ?? "Unmarked / ImageIO default (usually sRGB)"
        return SourceInfo(original: original,width: cg.width,height: cg.height,profile: profile)
    }
    public func render(_ preset: LUTPreset,library: LUTLibrary) async throws -> Preview {
        let start = Date()
        if let data = cache[preset.id] {
            order.removeAll { $0 == preset.id }; order.append(preset.id)
            return Preview(data: data,seconds: 0,cached: true)
        }
        let output = try await grade(preset,library: library)
        let data = try png(output)
        cache[preset.id] = data; order.append(preset.id)
        while order.count > 8 { cache.removeValue(forKey: order.removeFirst()) }
        return Preview(data: data,seconds: Date().timeIntervalSince(start),cached: false)
    }
    private func grade(_ preset: LUTPreset,library: LUTLibrary,exposureEV: Float = 0) async throws -> CIImage {
        let token = generation
        let exposure: Float = preset.role == "sceneToDisplay" ? exposureEV : 0
        let key = preset.id+":\(exposure.bitPattern)"
        guard let image = source else { throw CocoaError(.fileReadUnknown) }
        if let image = grades[key] {
            gradeOrder.removeAll { $0 == key }; gradeOrder.append(key)
            return image
        }
        let bytes = try await library.data(for: preset)
        try Task.checkCancellation()
        guard token == generation else { throw CancellationError() }
        let raw = try LUTLibrary.decode(bytes,preset: preset)
        let compiled = try LUTTransform(cube: raw,input: preset.inputSpace,output: preset.outputSpace,
            compressOutputGamut: preset.compressOutputGamut,inputExposureEV: exposure).compiled()
        try Task.checkCancellation()
        guard let filter = CIFilter(name: "CIColorCube") else { throw CocoaError(.featureUnsupported) }
        filter.setValue(image,forKey: kCIInputImageKey)
        filter.setValue(compiled.dimension,forKey: "inputCubeDimension")
        filter.setValue(compiled.data,forKey: "inputCubeData")
        guard let output = filter.outputImage else { throw CocoaError(.coderInvalidValue) }
        // Materialize once: parameter changes reuse the graded pixels rather than reapplying the LUT.
        guard let cg = context!.createCGImage(output,from: image.extent,format: .RGBAh,colorSpace: srgb) else {
            throw CocoaError(.coderInvalidValue)
        }
        let materialized = CIImage(cgImage: cg)
        grades[key] = materialized; gradeOrder.append(key)
        while gradeOrder.count > 8 { grades.removeValue(forKey: gradeOrder.removeFirst()) }
        return materialized
    }
    public func renderImage(_ preset: LUTPreset?,library: LUTLibrary,settings: EffectSettings) async throws -> DisplayPreview {
        let start = Date(), token = generation
        guard let original = source else { throw CocoaError(.fileReadUnknown) }
        var graded = original
        if let preset, settings.validated.lutMix > 0 {
            graded = try await grade(preset,library: library,exposureEV: settings.validated.lutExposureEV)
        }
        try Task.checkCancellation()
        guard token == generation else { throw CancellationError() }
        if effects == nil { effects = try AnalogEffects() }
        let output = try effects!.apply(original: original,graded: graded,settings: settings)
        guard let cg = context!.createCGImage(output,from: original.extent,format: .RGBA8,colorSpace: srgb) else {
            throw CocoaError(.coderInvalidValue)
        }
        return DisplayPreview(image: cg,seconds: Date().timeIntervalSince(start))
    }
}
