import XCTest
import CoreImage
@testable import AnalogCore
@testable import AnalogImaging

final class EffectsTests: XCTestCase {
    private let bounds = CGRect(x: 0,y: 0,width: 128,height: 128)
    private var srgb: CGColorSpace { CGColorSpace(name: CGColorSpace.sRGB)! }
    private func read(_ image: CIImage) -> [Float] {
        let context = CIContext(options: [.workingColorSpace: srgb])
        var data = [Float](repeating: 0,count: 128*128*4)
        data.withUnsafeMutableBytes {
            context.render(image,toBitmap: $0.baseAddress!,rowBytes: 128*16,bounds: bounds,format: .RGBAf,colorSpace: srgb)
        }
        return data
    }
    private func image(_ value: CGFloat,alpha: CGFloat = 1) -> CIImage {
        CIImage(color: CIColor(red: value,green: value,blue: value,alpha: alpha)).cropped(to: bounds)
    }
    private func off() -> EffectSettings {
        var s = EffectSettings(); s.grain.amount = 0; s.leak.amount = 0; return s
    }
    private func difference(_ a: [Float],_ b: [Float]) -> Float {
        zip(a,b).reduce(0) { $0+abs($1.0-$1.1) }/Float(a.count)
    }
    private func variance(_ a: [Float]) -> Float {
        let values = stride(from: 0,to: a.count,by: 4).map { a[$0] }
        let mean = values.reduce(0,+)/Float(values.count)
        return values.reduce(0) { $0+($1-mean)*($1-mean) }/Float(values.count)
    }
    func testFilmProcessLegacySettingsAndValidation() throws {
        let legacy = try JSONDecoder().decode(EffectSettings.self,from: Data("{\"lutMix\":0.5}".utf8))
        XCTAssertFalse(legacy.process.enabled)
        XCTAssertEqual(legacy.lutMix,0.5)
        var settings = legacy
        settings.process.exposureEV = .infinity
        settings.process.development = -10
        settings.process.wash = 4
        XCTAssertEqual(settings.validated.process.exposureEV,0)
        XCTAssertEqual(settings.validated.process.development,0.25)
        XCTAssertEqual(settings.validated.process.wash,1)
        XCTAssertEqual(try JSONDecoder().decode(EffectSettings.self,from: JSONEncoder().encode(settings.validated)),settings.validated)
    }
    func testFilmProcessStagesDeterminismAndAlpha() throws {
        let engine = try AnalogEffects(), source = image(0.25,alpha: 0.4)
        var settings = off(); settings.process.enabled = true
        func render(_ value: EffectSettings) throws -> [Float] {
            read(try engine.apply(original: source,graded: source,settings: value))
        }
        let normal = try render(settings)
        for key in [\FilmProcessSettings.exposureEV, \FilmProcessSettings.development,
                    \FilmProcessSettings.agitation, \FilmProcessSettings.stop,
                    \FilmProcessSettings.fixation, \FilmProcessSettings.wash, \FilmProcessSettings.drying] {
            var changed = settings
            changed.process[keyPath: key] = key == \FilmProcessSettings.exposureEV ? 1 : 0.25
            let output = try render(changed)
            XCTAssertGreaterThan(difference(normal,output),0.00001,"Stage: \(key)")
            XCTAssertEqual(output,try render(changed))
            for i in stride(from: 0,to: output.count,by: 4) {
                XCTAssertEqual(output[i+3],normal[i+3],accuracy: 0.00001)
                for c in 0..<3 { XCTAssertTrue(output[i+c].isFinite && output[i+c] >= 0 && output[i+c] <= output[i+3]+0.0001) }
            }
        }
        settings.process.drying = 0; settings.process.wash = 0
        let stained = try render(settings)
        settings.process.seed += 1
        XCTAssertGreaterThan(difference(stained,try render(settings)),0.00001)
        let transparent = image(0,alpha: 0)
        XCTAssertEqual(read(try engine.apply(original: transparent,graded: transparent,settings: settings)),read(transparent))
    }
    func testMixEndpointsAndMidpoint() throws {
        let engine = try AnalogEffects(), original = image(0.25), graded = image(0.75)
        var s = off(); s.lutMix = 0
        let zero = read(try engine.apply(original: original,graded: graded,settings: s))
        XCTAssertLessThan(difference(zero,read(original)),0.00001)
        s.lutMix = 1
        let one = read(try engine.apply(original: original,graded: graded,settings: s))
        XCTAssertLessThan(difference(one,read(graded)),0.00001)
        s.lutMix = 0.5
        let half = read(try engine.apply(original: original,graded: graded,settings: s))
        for i in stride(from: 0,to: half.count,by: 4) {
            XCTAssertEqual(half[i],(zero[i]+one[i])/2,accuracy: 0.0001)
        }
    }
    func testGrainControlsAndDeterminism() throws {
        let engine = try AnalogEffects(), source = image(0.5)
        var s = off(); s.grain.amount = 0.8; s.grain.size = 6; s.grain.blur = 0
        func render(_ s: EffectSettings) throws -> [Float] { read(try engine.apply(original: source,graded: source,settings: s)) }
        let baseline = try render(s)
        XCTAssertEqual(baseline,try render(s))
        var changed = s; changed.grain.seed += 1
        XCTAssertGreaterThan(difference(baseline,try render(changed)),0.001)
        changed = s; changed.grain.size = 2
        XCTAssertGreaterThan(difference(baseline,try render(changed)),0.001)
        changed = s; changed.grain.texture = 0
        XCTAssertGreaterThan(difference(baseline,try render(changed)),0.001)
        changed = s; changed.grain.blur = 2
        XCTAssertLessThan(variance(try render(changed)),variance(baseline)*0.6)
    }
    func testGrainCoverageToneResponseAndAlpha() throws {
        let engine = try AnalogEffects()
        var settings = off(); settings.grain.amount = 1; settings.grain.size = 6
        settings.grain.blur = 0.15
        func mean(_ values: [Float]) -> Float {
            stride(from: 0,to: values.count,by: 4).reduce(0) { $0+values[$1] }/Float(values.count/4)
        }
        var variances = [Float]()
        for level: CGFloat in [0,0.1,0.5,0.9,1] {
            let source = image(level), reference = read(source)
            let output = read(try engine.apply(original: source,graded: source,settings: settings))
            XCTAssertEqual(mean(output),mean(reference),accuracy: 0.025,"Coverage should preserve a flat field's expected tone")
            variances.append(variance(output))
        }
        XCTAssertLessThan(variances[0],0.000001); XCTAssertLessThan(variances[4],0.000001)
        XCTAssertGreaterThan(variances[2],variances[1]); XCTAssertGreaterThan(variances[2],variances[3])
        let source = image(0.5,alpha: 0.4), reference = read(source)
        let output = read(try engine.apply(original: source,graded: source,settings: settings))
        for i in stride(from: 0,to: output.count,by: 4) {
            XCTAssertEqual(output[i+3],reference[i+3],accuracy: 0.00001)
            for c in 0..<3 { XCTAssertTrue(output[i+c].isFinite && output[i+c] >= 0 && output[i+c] <= output[i+3]+0.0001) }
        }
        let transparent = image(0,alpha: 0)
        XCTAssertEqual(read(try engine.apply(original: transparent,graded: transparent,settings: settings)),read(transparent))
    }
    func testGrainFullPreviewPerformance() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let source = CIImage(contentsOf: root.appendingPathComponent("Assets/bliss.jpg"),options: [.applyOrientationProperty: true])!
        let engine = try AnalogEffects(), context = CIContext(options: [.workingColorSpace: srgb])
        var settings = off(); settings.grain.amount = 0.5
        for pass in 0..<2 {
            let start = Date()
            let result = try engine.apply(original: source,graded: source,settings: settings)
            XCTAssertNotNil(context.createCGImage(result,from: source.extent))
            print(String(format: "Poisson grain %@ %dx%d %.1f ms",pass == 0 ? "first" : "warm",Int(source.extent.width),Int(source.extent.height),Date().timeIntervalSince(start)*1000))
            if pass == 1, let folder = ProcessInfo.processInfo.environment["ANALINE_GRAIN_ARTIFACTS"] {
                try FileManager.default.createDirectory(atPath: folder,withIntermediateDirectories: true)
                try context.writePNGRepresentation(of: result,to: URL(fileURLWithPath: folder+"/grain.png"),format: .RGBA8,colorSpace: srgb)
            }
        }
    }
    func testLeakGeometryAndAlpha() throws {
        let engine = try AnalogEffects(), source = image(0.3,alpha: 0.6)
        var s = off(); s.leak.amount = 0.7
        func render(_ s: EffectSettings) throws -> [Float] { read(try engine.apply(original: source,graded: source,settings: s)) }
        let baseline = try render(s), original = read(source)
        XCTAssertEqual(baseline,try render(s))
        XCTAssertGreaterThan(difference(baseline,original),0.005)
        for i in stride(from: 0,to: baseline.count,by: 4) {
            XCTAssertEqual(baseline[i+3],original[i+3],accuracy: 0.00001)
            for c in 0..<3 { XCTAssertGreaterThanOrEqual(baseline[i+c],original[i+c]-0.0001) }
        }
        let keys: [WritableKeyPath<LightLeakSettings,Float>] = [\.x,\.y,\.width,\.length,\.rotation,\.hue,\.softness,\.irregularity]
        for key in keys {
            var changed = s
            switch key {
            case \.x: changed.leak.x = 1
            case \.y: changed.leak.y = 0
            case \.width: changed.leak.width = 0.8
            case \.length: changed.leak.length = 0.2
            case \.rotation: changed.leak.rotation = 90
            case \.hue: changed.leak.hue = 200
            case \.softness: changed.leak.softness = 0
            default: changed.leak.irregularity = 1
            }
            XCTAssertGreaterThan(difference(baseline,try render(changed)),0.0001)
        }
        var changed = s; changed.leak.seed += 1
        XCTAssertGreaterThan(difference(baseline,try render(changed)),0.0001)
    }
    func testSettingsBounds() {
        var s = EffectSettings(); s.lutMix = .nan; s.grain.size = 0; s.leak.width = -1
        s = s.validated
        XCTAssertEqual(s.lutMix,1); XCTAssertEqual(s.grain.size,0.5); XCTAssertEqual(s.leak.width,0.03)
    }
}
