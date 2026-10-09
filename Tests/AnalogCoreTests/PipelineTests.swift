import XCTest
import AppKit
import ImageIO
@testable import AnalogCore
@testable import AnalogImaging

final class PipelineTests: XCTestCase {
    private var root: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    }
    func testColorSpaceConversion() {
        let gray = LUTColorSpace.srgb.convert(SIMD3<Float>(repeating: 0.5),to: .linearSRGB)
        XCTAssertEqual(gray.x,0.21404114,accuracy: 0.000001)
        for space in [LUTColorSpace.adobeRGB1998,.displayP3,.rec709,.linearSRGB] {
            let original = SIMD3<Float>(0.7,0.4,0.1)
            let result = space.convert(LUTColorSpace.srgb.convert(original,to: space),to: .srgb)
            for c in 0..<3 { XCTAssertEqual(result[c],original[c],accuracy: 0.00001) }
        }
    }
    func testDomainAndInterpolation() throws {
        let cube = try CubeLUT(text: "LUT_3D_SIZE 2\nDOMAIN_MIN -1 -1 -1\nDOMAIN_MAX 1 1 1\n0 0 0\n1 0 0\n0 1 0\n1 1 0\n0 0 1\n1 0 1\n0 1 1\n1 1 1")
        XCTAssertEqual(cube.sample(SIMD3<Float>(0,-1,1)),SIMD3<Float>(0.5,0,1))
        XCTAssertEqual(cube.sample(SIMD3<Float>(-2,2,0)),SIMD3<Float>(0,1,0.5))
    }
    func testHaldOrderAnd16BitPrecision() throws {
        for bits in [8,16] {
            let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil,pixelsWide: 8,pixelsHigh: 8,
                bitsPerSample: bits,samplesPerPixel: 3,hasAlpha: false,isPlanar: false,
                colorSpaceName: .deviceRGB,bytesPerRow: 8*3*(bits/8),bitsPerPixel: bits*3)!
            let maximum = (1 << bits)-1
            for i in 0..<64 {
                var pixel = [(i%4)*maximum/3,((i/4)%4)*maximum/3,(i/16)*maximum/3]
                bitmap.setPixel(&pixel,atX: i%8,y: i/8)
            }
            let png = bitmap.representation(using: .png,properties: [:])!
            let cube = try HaldLUT.load(data: png)
            XCTAssertEqual(cube.dimension,4)
            let input = SIMD3<Float>(0.25,0.5,0.75), output = cube.sample(input)
            for c in 0..<3 { XCTAssertEqual(output[c],input[c],accuracy: 0.00002) }
            if bits == 16 {
                var pixel = [12345,23456,34567]; bitmap.setPixel(&pixel,atX: 0,y: 0)
                let precise = try HaldLUT.load(data: bitmap.representation(using: .png,properties: [:])!)
                XCTAssertEqual(precise.rgba[0],Float(12345)/65535,accuracy: 0.000001)
            }
        }
    }
    func testCatalogAndBundledData() throws {
        let library = try LUTLibrary(root: root.appendingPathComponent("Assets/LUTLibrary"))
        XCTAssertEqual(library.presets.count,553)
        var found = Set<String>()
        for preset in library.presets {
            let file = library.root.appendingPathComponent(preset.file)
            guard FileManager.default.fileExists(atPath: file.path) else { continue }
            found.insert(preset.collection)
            let data = try Data(contentsOf: file)
            XCTAssertTrue(LUTLibrary.verify(data,preset: preset))
            let cube = try LUTLibrary.decode(data,preset: preset)
            if preset.collection == "film-lab" {
                XCTAssertEqual(cube.dimension,64)
                let gray = cube.sample(SIMD3<Float>(repeating: 0.5))
                XCTAssertTrue(gray.x > 0.4 && gray.x < 0.6)
            }
        }
        XCTAssertEqual(found,Set(["Film-Luts","hald-clut","PoLUT","film-lab"]))
    }
    func testCompiledAdobeIdentity() throws {
        let text = "LUT_3D_SIZE 2\n0 0 0\n1 0 0\n0 1 0\n1 1 0\n0 0 1\n1 0 1\n0 1 1\n1 1 1"
        let transform = LUTTransform(cube: try CubeLUT(text: text),input: .adobeRGB1998,output: .adobeRGB1998)
        let compiled = try transform.compiled()
        for p in [SIMD3<Float>(0.5,0.5,0.5),SIMD3<Float>(0.7,0.4,0.1),SIMD3<Float>(1,0,0)] {
            let result = compiled.sample(p)
            for c in 0..<3 { XCTAssertEqual(result[c],p[c],accuracy: 0.0001) }
        }
    }
    func testGPUAcrossAllBundledPresets() async throws {
        let library = try LUTLibrary(root: root.appendingPathComponent("Assets/LUTLibrary"))
        let renderer = LUTRenderer()
        let info = try await renderer.loadSource(root.appendingPathComponent("Assets/bliss.jpg"))
        for p in library.presets where FileManager.default.fileExists(atPath: library.root.appendingPathComponent(p.file).path) {
            let result = try await renderer.render(p,library: library)
            let source = CGImageSourceCreateWithData(result.data as CFData,nil)!
            let image = CGImageSourceCreateImageAtIndex(source,0,nil)!
            XCTAssertEqual(image.width,info.width); XCTAssertEqual(image.height,info.height)
            XCTAssertNotEqual(result.data,info.original)
            let cached = try await renderer.render(p,library: library)
            XCTAssertTrue(cached.cached)
            XCTAssertEqual(cached.data,result.data)
        }
    }
    func testSourceICCAndAlpha() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder,withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let sourceURL = folder.appendingPathComponent("p3.png")
        let bytes = Data([128,64,32,128])
        let cg = CGImage(width: 1,height: 1,bitsPerComponent: 8,bitsPerPixel: 32,bytesPerRow: 4,
            space: CGColorSpace(name: CGColorSpace.displayP3)!,
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.last.rawValue),
            provider: CGDataProvider(data: bytes as CFData)!,decode: nil,shouldInterpolate: false,intent: .defaultIntent)!
        let destination = CGImageDestinationCreateWithURL(sourceURL as CFURL,"public.png" as CFString,1,nil)!
        CGImageDestinationAddImage(destination,cg,nil); XCTAssertTrue(CGImageDestinationFinalize(destination))
        let renderer = LUTRenderer(), source = try await renderer.loadSource(sourceURL)
        let bitmap = NSBitmapImageRep(data: source.original)!
        var samples = [Int](repeating: 0,count: bitmap.samplesPerPixel)
        bitmap.getPixel(&samples,atX: 0,y: 0)
        let expected = LUTColorSpace.displayP3.convert(SIMD3<Float>(128/255.0,64/255.0,32/255.0),to: .srgb)
        // Read encoded PNG samples directly; colorAt returns calibrated NSColor and would convert twice.
        for c in 0..<3 { XCTAssertEqual(Float(samples[c])/255,expected[c],accuracy: 0.005) }
        XCTAssertEqual(samples[3],128)
        let library = try LUTLibrary(root: root.appendingPathComponent("Assets/LUTLibrary"))
        let p = library.presets.first { $0.collection == "Film-Luts" }!
        let output = try await renderer.render(p,library: library)
        let result = NSBitmapImageRep(data: output.data)!.colorAt(x: 0,y: 0)!
        XCTAssertEqual(result.alphaComponent,128/255.0,accuracy: 0.005)
    }
    func testPoLUTGPUReference() async throws {
        let colors: [SIMD3<Float>] = [SIMD3(0.5,0.5,0.5),SIMD3(0.2,0.6,0.1),SIMD3(0.1,0.4,0.9),SIMD3(0.9,0.2,0.1),SIMD3(0.9,0.9,0.9)]
        let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil,pixelsWide: colors.count,pixelsHigh: 1,bitsPerSample: 8,samplesPerPixel: 3,hasAlpha: false,isPlanar: false,colorSpaceName: .deviceRGB,bytesPerRow: colors.count*3,bitsPerPixel: 24)!
        for (i,color) in colors.enumerated() {
            var p = (0..<3).map { Int((color[$0]*255).rounded()) }; bitmap.setPixel(&p,atX: i,y: 0)
        }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("analine-polut-reference.png")
        try bitmap.representation(using: .png,properties: [:])!.write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        let library = try LUTLibrary(root: root.appendingPathComponent("Assets/LUTLibrary"))
        let renderer = LUTRenderer()
        let source = try await renderer.loadSource(url)
        let original = NSBitmapImageRep(data: source.original)!
        for preset in library.presets where preset.collection == "PoLUT" && FileManager.default.fileExists(atPath: library.root.appendingPathComponent(preset.file).path) {
            let cube = try LUTLibrary.decode(Data(contentsOf: library.root.appendingPathComponent(preset.file)),preset: preset)
            let transform = LUTTransform(cube: cube,input: preset.inputSpace,output: preset.outputSpace,
                compressOutputGamut: preset.compressOutputGamut)
            let rendered = try await renderer.render(preset,library: library)
            let result = NSBitmapImageRep(data: rendered.data)!
            for x in 0..<colors.count {
                var src = [Int](repeating: 0,count: original.samplesPerPixel), dst = [Int](repeating: 0,count: result.samplesPerPixel)
                original.getPixel(&src,atX: x,y: 0); result.getPixel(&dst,atX: x,y: 0)
                let expected = transform.applyToSRGB(SIMD3(Float(src[0])/255,Float(src[1])/255,Float(src[2])/255))
                XCTAssertTrue((0..<3).allSatisfy { expected[$0] >= -0.00001 && expected[$0] <= 1.00001 })
                for c in 0..<3 { XCTAssertEqual(Float(dst[c])/255,min(1,max(0,expected[c])),accuracy: 0.025) }
            }
        }
        let preset = library.presets.first { $0.collection == "PoLUT" && $0.name == "Portra400 Classic Normal" }!
        var settings = EffectSettings(); settings.grain.amount = 0
        func gray(_ result: LUTRenderer.DisplayPreview) -> Int {
            let bitmap = NSBitmapImageRep(cgImage: result.image)
            var pixel = [Int](repeating: 0,count: bitmap.samplesPerPixel)
            bitmap.getPixel(&pixel,atX: 0,y: 0); return pixel[0]
        }
        let normal = gray(try await renderer.renderImage(preset,library: library,settings: settings))
        settings.lutExposureEV = -1
        let dark = gray(try await renderer.renderImage(preset,library: library,settings: settings))
        settings.lutExposureEV = 1
        let bright = gray(try await renderer.renderImage(preset,library: library,settings: settings))
        XCTAssertLessThan(dark,normal); XCTAssertGreaterThan(bright,normal)
        settings.lutExposureEV = 0
        let restored = gray(try await renderer.renderImage(preset,library: library,settings: settings))
        XCTAssertEqual(restored,normal) // Exposure must participate in the grade cache key.
        settings.lutMix = 0
        let originalGray = gray(try await renderer.renderImage(preset,library: library,settings: settings))
        settings.lutExposureEV = 2
        let bypass = gray(try await renderer.renderImage(preset,library: library,settings: settings))
        XCTAssertEqual(originalGray,bypass)
    }
    func testWideGamutCompressionAndAdobeTransfer() throws {
        let gray = LUTColorSpace.linearSRGB.convert(SIMD3<Float>(repeating: 0.18),to: .adobeRGB1998)
        XCTAssertEqual(gray.x,pow(Float(0.18),256.0/563.0),accuracy: 0.0001)
        // Real problematic green output from the bundled Velvia Normal LUT.
        let raw = SIMD3<Float>(-0.5207176,0.8014659,-0.15465114)
        let mapped = LUTTransform.compressToSRGB(raw)
        XCTAssertTrue((0..<3).allSatisfy { mapped[$0] >= 0 && mapped[$0] <= 1 })
        XCTAssertGreaterThan(mapped.x,0); XCTAssertGreaterThan(mapped.z,0)
        let a = LUTColorSpace.srgb.convert(raw,to: .linearSRGB)
        let b = LUTColorSpace.srgb.convert(mapped,to: .linearSRGB)
        func luma(_ p: SIMD3<Float>) -> Float { p.x*0.2126729+p.y*0.7151522+p.z*0.0721750 }
        XCTAssertEqual(luma(a),luma(b),accuracy: 0.00001)
        let y = SIMD3<Float>(repeating: luma(a)), da = a-y, db = b-y
        XCTAssertEqual(db.x/da.x,db.y/da.y,accuracy: 0.0001)
        XCTAssertEqual(db.z/da.z,db.y/da.y,accuracy: 0.0001)
        for neutral: Float in [0,0.1,0.5,0.9,1] {
            let mapped = LUTTransform.compressToSRGB(SIMD3(repeating: neutral))
            for c in 0..<3 { XCTAssertEqual(mapped[c],neutral,accuracy: 0.00001) }
        }
        let identity = try CubeLUT(text: "LUT_3D_SIZE 2\n0 0 0\n1 0 0\n0 1 0\n1 1 0\n0 0 1\n1 0 1\n0 1 1\n1 1 1")
        let exposure = LUTTransform(cube: identity,input: .linearSRGB,output: .linearSRGB,inputExposureEV: 1)
        let result = LUTColorSpace.srgb.convert(exposure.applyToSRGB(SIMD3(repeating: 0.4)),to: .linearSRGB)
        let expected = LUTColorSpace.srgb.convert(SIMD3<Float>(repeating: 0.4),to: .linearSRGB)*2
        for c in 0..<3 { XCTAssertEqual(result[c],expected[c],accuracy: 0.00001) }
    }
}
