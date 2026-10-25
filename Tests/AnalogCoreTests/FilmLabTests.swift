import XCTest
import CoreImage
@testable import AnalogCore
@testable import AnalogImaging

final class FilmLabTests: XCTestCase {
    private func developed(_ recipe: FilmLabRecipe = FilmLabRecipe()) -> FilmLabSession {
        var s = FilmLabSession(); s.recipe = recipe
        s.advance(seconds: 1); s.complete(); s.advance(seconds: 600)
        return s
    }
    private func fixed() -> FilmLabSession {
        var s = developed(); s.complete(); s.advance(seconds: 30); s.complete(); s.advance(seconds: 180)
        return s
    }
    func testExposureSpectrumAndDeveloperCharacteristics() {
        let neutral = FilmLabPhysics.spectralWeights(kelvin: 5500)
        XCTAssertEqual(neutral,SIMD3(repeating: 1))
        let warm = FilmLabPhysics.spectralWeights(kelvin: 2850)
        XCTAssertGreaterThan(warm.x,warm.z)
        var a = FilmLabSession(), b = a
        a.recipe.kelvin = 2850; b.recipe.kelvin = 9000
        a.advance(seconds: 1); b.advance(seconds: 1)
        XCTAssertGreaterThan(FilmLabPhysics.replay(a,rgb: SIMD3(0.5,0,0)).latent,FilmLabPhysics.replay(b,rgb: SIMD3(0.5,0,0)).latent)
        var fine = FilmLabRecipe(); fine.developer = .perceptol
        var fast = FilmLabRecipe(); fast.developer = .microphen
        XCTAssertLessThan(FilmLabPhysics.replay(developed(fine)).silverMean,FilmLabPhysics.replay(developed(fast)).silverMean)
        var hot = FilmLabRecipe(); hot.temperature = 30
        XCTAssertGreaterThan(FilmLabPhysics.replay(developed(hot)).silverMean,FilmLabPhysics.replay(developed()).silverMean)
    }
    func testConservationStopFixWashAndDrying() {
        let d = FilmLabPhysics.replay(developed())
        XCTAssertGreaterThan(d.silverMean,0)
        for i in 0..<2 { XCTAssertEqual(d.silver[i]+d.halide[i],1,accuracy: 0.00001) }
        var stopped = developed(); stopped.complete(); stopped.advance(seconds: 60)
        var weak = developed(); weak.complete(); weak.recipe.strength = 0; weak.advance(seconds: 60)
        XCTAssertLessThan(FilmLabPhysics.replay(stopped).silverMean,FilmLabPhysics.replay(weak).silverMean)
        var s = fixed(); let f = FilmLabPhysics.replay(s)
        XCTAssertLessThan(f.halideMean,d.halideMean)
        XCTAssertEqual(f.silverMean,FilmLabPhysics.replay(stopped).silverMean,accuracy: 0.03)
        s.complete(); s.advance(seconds: 600)
        let washed = FilmLabPhysics.replay(s)
        XCTAssertLessThan(washed.residueMean,f.residueMean)
        s.complete(); var humid = s
        s.recipe.humidity = 0.1; humid.recipe.humidity = 0.9
        s.advance(seconds: 900); humid.advance(seconds: 900)
        let dry = FilmLabPhysics.replay(s)
        XCTAssertLessThan(dry.water,FilmLabPhysics.replay(humid).water)
        XCTAssertGreaterThan(dry.deposit,0)
        for i in 0..<2 { XCTAssertLessThanOrEqual(dry.silver[i]+dry.halide[i],1.00001); XCTAssertGreaterThanOrEqual(dry.halide[i],0) }
    }
    func testUndoRestoresStageEntryAndSerialization() throws {
        var s = FilmLabSession(); s.recipe.kelvin = 3200
        s.advance(seconds: 1); s.complete()
        let exposure = s.operations
        s.recipe.developer = .microphen; s.recipe.temperature = 30
        s.advance(seconds: 90); s.complete(); s.advance(seconds: 10)
        let data = try JSONEncoder().encode(s)
        var restored = try JSONDecoder().decode(FilmLabSession.self,from: data)
        XCTAssertEqual(s,restored)
        restored.undo()
        XCTAssertEqual(restored.stage,.development)
        XCTAssertEqual(restored.operations,exposure)
        XCTAssertEqual(restored.recipe.kelvin,3200)
        XCTAssertEqual(restored.recipe.developer,.id11)
        XCTAssertEqual(restored.recipe.temperature,20)
        restored.undo()
        XCTAssertEqual(restored.stage,.exposure)
        XCTAssertTrue(restored.operations.isEmpty)
        XCTAssertFalse(restored.canUndo)
        XCTAssertFalse(restored.canAdvance)
        restored.advance(seconds: .infinity)
        XCTAssertTrue(restored.operations.isEmpty)
    }
    func testRewindTruncatesAcrossConditionsWithoutTouchingPreviousStages() throws {
        var s = FilmLabSession()
        s.advance(seconds: 1); s.complete()
        let exposed = s.operations
        s.advance(seconds: 40)
        let baseline = s
        s.recipe.temperature = 35; s.advance(seconds: 20)
        s.rewind(seconds: 30)
        XCTAssertEqual(s.elapsed,30)
        XCTAssertEqual(s.recipe.temperature,20)
        XCTAssertEqual(Array(s.operations.prefix(exposed.count)),exposed)
        var reference = baseline; reference.rewind(seconds: 10)
        XCTAssertEqual(s,reference)
        XCTAssertEqual(FilmLabPhysics.replay(s).silverMean,FilmLabPhysics.replay(reference).silverMean)
        let restored = try JSONDecoder().decode(FilmLabSession.self,from: JSONEncoder().encode(s))
        XCTAssertEqual(restored,s)
        s.rewind(seconds: 300)
        XCTAssertEqual(s.operations,exposed)
        XCTAssertEqual(s.elapsed,0)
        XCTAssertEqual(s.stage,.development)
        XCTAssertFalse(s.canAdvance)
        s.rewind(seconds: .infinity); s.rewind(seconds: -30)
        XCTAssertEqual(s.operations,exposed)
        s.advance(seconds: 30); s.complete(); s.undo()
        XCTAssertEqual(s.operations,exposed)
        XCTAssertEqual(s.stage,.development)
    }
    func testChangesOnlyAffectFutureAndStageGating() {
        var s = developed(); let prefix = s.operations
        s.recipe.temperature = 35; s.advance(seconds: 30)
        XCTAssertEqual(Array(s.operations.prefix(prefix.count)),prefix)
        XCTAssertGreaterThan(FilmLabPhysics.replay(s).silverMean,FilmLabPhysics.replay(developed()).silverMean)
        while s.stage != .scan { s.advance(seconds: 1); s.complete() }
        let finished = s; s.advance(seconds: 100); s.complete()
        XCTAssertEqual(s,finished)
        s.undo(); XCTAssertEqual(s.stage,.drying)
    }
    func testGPUStateMatchesCPUAndAlpha() throws {
        let renderer = try FilmLabRenderer()
        let bounds = CGRect(x: 0,y: 0,width: 64,height: 48)
        let color: Float = 0.4,alpha: Float = 0.5
        let source = CIImage(color: CIColor(red: CGFloat(color),green: CGFloat(color),blue: CGFloat(color),alpha: CGFloat(alpha))).cropped(to: bounds)
        let context = CIContext(options: [.workingColorSpace: CGColorSpace(name: CGColorSpace.sRGB)!])
        var s = fixed(); s.complete(); s.advance(seconds: 180)
        for display in [FilmLabDisplay.latent,.silver,.halide,.water] {
            let image = try renderer.render(source,session: s,display: display)
            var pixels = [Float](repeating: 0,count: 64*48*4)
            context.render(image,toBitmap: &pixels,rowBytes: 64*16,bounds: bounds,format: .RGBAf,colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!)
            let linear = pow((color+0.055)/1.055,2.4)
            let state = FilmLabPhysics.replay(s,rgb: SIMD3(repeating: linear),position: SIMD2(32.5/64,24.5/48))
            let value: Float = switch display { case .latent: state.latent; case .silver: state.silverMean; case .halide: state.halideMean; default: state.water }
            let index = (24*64+32)*4
            XCTAssertEqual(pixels[index]/pixels[index+3],value,accuracy: 0.025,"\(display)")
            XCTAssertEqual(pixels[index+3],alpha,accuracy: 0.0001)
            XCTAssertTrue(pixels.allSatisfy { $0.isFinite && $0 >= 0 && $0 <= 1 })
        }
        let transparent = CIImage(color: .clear).cropped(to: bounds)
        XCTAssertNotNil(context.createCGImage(try renderer.render(transparent,session: s),from: bounds))
    }
    func testOriginalResolutionExport() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder,withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let input = folder.appendingPathComponent("input.png"),output = folder.appendingPathComponent("scan.png")
        let bounds = CGRect(x: 0,y: 0,width: 1800,height: 160)
        let image = CIImage(color: CIColor(red: 0.4,green: 0.3,blue: 0.2,alpha: 1)).cropped(to: bounds)
        try CIContext().writePNGRepresentation(of: image,to: input,format: .RGBA8,colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!)
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let library = try LUTLibrary(root: root.appendingPathComponent("Assets/LUTLibrary"))
        let renderer = LUTRenderer(),preview = try await renderer.loadSource(input)
        XCTAssertEqual(preview.width,1400)
        var s = FilmLabSession()
        while s.stage != .scan { s.advance(seconds: s.stage.defaultDuration); s.complete() }
        var settings = EffectSettings(); settings.laboratory = s
        try await renderer.exportFilmLab(source: input,to: output,preset: nil,library: library,settings: settings)
        let result = try XCTUnwrap(CIImage(contentsOf: output))
        XCTAssertEqual(result.extent.width,1800); XCTAssertEqual(result.extent.height,160)
    }
    func testRenderAllStagesAndExportArtifacts() throws {
        let renderer = try FilmLabRenderer(),context = CIContext(options: [.workingColorSpace: CGColorSpace(name: CGColorSpace.sRGB)!])
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let source = CIImage(contentsOf: root.appendingPathComponent("Assets/bliss.jpg"))!
        let scaled = source.transformed(by: CGAffineTransform(scaleX: 640/source.extent.width,y: 640/source.extent.width))
        var s = FilmLabSession()
        for stage in FilmLabStage.allCases {
            if stage != .scan { s.advance(seconds: stage.defaultDuration) }
            let output = try renderer.render(scaled,session: s)
            XCTAssertNotNil(context.createCGImage(output,from: output.extent))
            if let path = ProcessInfo.processInfo.environment["ANALINE_LAB_ARTIFACTS"] {
                let folder = URL(fileURLWithPath: path)
                try FileManager.default.createDirectory(at: folder,withIntermediateDirectories: true)
                try context.writePNGRepresentation(of: output,to: folder.appendingPathComponent("stage-\(stage.rawValue).png"),format: .RGBA8,colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!)
            }
            s.complete()
        }
    }
}
