import XCTest
import MetalKit
import CoreGraphics
@testable import AnalogGUI

@MainActor
final class TVCRTDisplayTests: XCTestCase {
    func testPeakTracksCurrentHeadroomAndSDRFallback() {
        XCTAssertEqual(TVCRTDisplay.Renderer.peak(hdr: true, brightness: 4, headroom: 1.6), 1.6)
        XCTAssertEqual(TVCRTDisplay.Renderer.peak(hdr: false, brightness: 4, headroom: 8), 1)
        XCTAssertEqual(TVCRTDisplay.Renderer.peak(hdr: true, brightness: 4, headroom: 1), 1)
        XCTAssertEqual(TVCRTDisplay.Renderer.peak(hdr: true, brightness: .nan, headroom: 8), 1)
    }

    func testCurvatureCoefficientIsClampedAndDefaultsToPreviousLook() {
        XCTAssertEqual(TVCRTDisplay.curvatureCoefficient(0), 0)
        XCTAssertEqual(TVCRTDisplay.curvatureCoefficient(0.5), 0.018, accuracy: 1e-12)
        XCTAssertEqual(TVCRTDisplay.curvatureCoefficient(1), 0.036, accuracy: 1e-12)
        XCTAssertEqual(TVCRTDisplay.curvatureCoefficient(-1), 0)
        XCTAssertEqual(TVCRTDisplay.curvatureCoefficient(2), 0.036, accuracy: 1e-12)
        XCTAssertEqual(TVCRTDisplay.curvatureCoefficient(.nan), 0.018, accuracy: 1e-12)
    }

    func testAutomaticBrightnessUsesAllAvailableHeadroom() {
        let automatic = TVCRTBrightnessReading.make(hdr: true, automatic: true, brightness: 2, headroom: 12, potential: 16)
        XCTAssertEqual(automatic.requested, 12)
        XCTAssertEqual(automatic.output, 12)
        XCTAssertEqual(automatic.potential, 16)
        let manual = TVCRTBrightnessReading.make(hdr: true, automatic: false, brightness: 16, headroom: 8, potential: 16)
        XCTAssertEqual(manual.requested, 16)
        XCTAssertEqual(manual.output, 8)
        XCTAssertEqual(TVCRTBrightnessReading.make(hdr: false, automatic: true, brightness: 2, headroom: 16, potential: 16).output, 1)
        XCTAssertEqual(TVCRTBrightnessReading.make(hdr: true, automatic: true, brightness: .nan, headroom: .nan, potential: .infinity).output, 1)
        XCTAssertEqual(TVCRTBrightnessReading.make(hdr: true, automatic: false, brightness: 30, headroom: 8, potential: 16).requested, 16)
    }

    func testLineCountUsesSimulatedLinesOrSanitizesManualValue() {
        XCTAssertEqual(TVCRTDisplay.Renderer.lineCount(0, crtLines: 240), 240)
        XCTAssertEqual(TVCRTDisplay.Renderer.lineCount(.nan, crtLines: 360), 360)
        XCTAssertEqual(TVCRTDisplay.Renderer.lineCount(239.8, crtLines: 240), 240)
        XCTAssertEqual(TVCRTDisplay.Renderer.lineCount(20, crtLines: 240), 120)
        XCTAssertEqual(TVCRTDisplay.Renderer.lineCount(2000, crtLines: 240), 1080)
    }

    func testLineLimitNeverExceedsCurrentDisplay() {
        XCTAssertEqual(TVCRTDisplay.Renderer.lineCount(0, crtLines: 600, maximum: 576), 576)
        XCTAssertEqual(TVCRTDisplay.Renderer.lineCount(0, crtLines: 360, maximum: 480), 360)
        XCTAssertEqual(TVCRTDisplay.Renderer.lineCount(700, crtLines: 240, maximum: 480), 480)
        XCTAssertEqual(TVCRTDisplay.Renderer.crtLineCount(600, maximum: 576), 576)
        XCTAssertEqual(TVCRTDisplay.Renderer.displayLineLimit(maxLines: 576, drawableHeight: 300), 300)
        XCTAssertEqual(TVCRTDisplay.Renderer.displayLineLimit(maxLines: 480, drawableHeight: 1000), 480)
        XCTAssertEqual(TVCRTDisplay.Renderer.displayLineLimit(maxLines: .nan, drawableHeight: 1000), 576)
    }

    func testMaskArrangementsAndFill() {
        let grid = TVCRTDisplay.Renderer.dotGrid(lines: 240, aspect: 4.0 / 3.0)
        XCTAssertEqual(grid.rows, 240)
        XCTAssertEqual(grid.triads, 320)
        XCTAssertEqual(grid.dots, 960)

        let aperture = TVCRTMaskStyle.make(type: TVCRTMaskType.apertureGrille.rawValue, mask: 0.8)
        XCTAssertEqual(aperture.fillH, 0.64, accuracy: 1e-9)
        XCTAssertEqual(aperture.fillV, 1, accuracy: 1e-9)
        XCTAssertEqual(aperture.meanFill, 0.64 * 0.997, accuracy: 1e-9)
        XCTAssertTrue(aperture.hasDamperWires)

        let inline = TVCRTMaskStyle.make(type: TVCRTMaskType.inlineShadowMask.rawValue, mask: 0.8)
        XCTAssertEqual(inline.fillH, 0.64, accuracy: 1e-9)
        XCTAssertEqual(inline.fillV, 0.88, accuracy: 1e-9)
        XCTAssertEqual(inline.meanFill, 0.5632, accuracy: 1e-9)

        let slot = TVCRTMaskStyle.make(type: TVCRTMaskType.slotMask.rawValue, mask: 0.8)
        XCTAssertEqual(slot.fillH, 0.64, accuracy: 1e-9)
        XCTAssertEqual(slot.fillV, 0.936, accuracy: 1e-9)
        XCTAssertEqual(slot.meanFill, 0.64 * 0.936, accuracy: 1e-9)
        XCTAssertEqual(slot.stagger, 1.0 / 6.0, accuracy: 1e-9)

        let shadow = TVCRTMaskStyle.make(type: TVCRTMaskType.shadowMask.rawValue, mask: 0.8)
        XCTAssertEqual(shadow.radius, 0.38, accuracy: 1e-9)
        XCTAssertEqual(shadow.meanFill, Double.pi * 0.38 * 0.38 / (sqrt(3) / 2), accuracy: 1e-9)
        XCTAssertFalse(shadow.hasDamperWires)

        let open = TVCRTMaskStyle.make(type: TVCRTMaskType.inlineShadowMask.rawValue, mask: 0)
        XCTAssertEqual(open.fillH, 1)
        XCTAssertEqual(open.fillV, 1)
        let closed = TVCRTMaskStyle.make(type: TVCRTMaskType.inlineShadowMask.rawValue, mask: 5)
        XCTAssertEqual(closed.fillH, 0.55)
        XCTAssertEqual(closed.fillV, 0.85)
        XCTAssertEqual(TVCRTMaskStyle.make(type: 99, mask: 0.8).type, .apertureGrille)
    }

    func testSourceTextureHasMipmapsForDotPrefiltering() throws {
        guard let device = MTLCreateSystemDefaultDevice() else { throw XCTSkip("Metal unavailable") }
        let side = 64
        let space = try XCTUnwrap(CGColorSpace(name: CGColorSpace.sRGB))
        let bitmap = try XCTUnwrap(CGContext(data: nil, width: side, height: side,
            bitsPerComponent: 8, bytesPerRow: side*4, space: space,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        bitmap.setFillColor(CGColor(red: 0.5, green: 0.5, blue: 0.5, alpha: 1))
        bitmap.fill(CGRect(x: 0, y: 0, width: side, height: side))
        let cg = try XCTUnwrap(bitmap.makeImage())
        let texture = try MTKTextureLoader(device: device).newTexture(cgImage: cg,
            options: [.SRGB: true, .origin: MTKTextureLoader.Origin.topLeft,
                      .generateMipmaps: true])
        XCTAssertGreaterThan(texture.mipmapLevelCount, 1,
            "Each phosphor dot needs a mip chain to average its source footprint")
    }

    func testShaderEmitsSinglePrimaryTripletsAndExtendedLight() throws {
        guard let device = MTLCreateSystemDefaultDevice() else { throw XCTSkip("Metal unavailable") }
        let library = try device.makeLibrary(source: TVCRTDisplay.Renderer.shader, options: nil)
        let descriptor = MTLRenderPipelineDescriptor()
        descriptor.vertexFunction = library.makeFunction(name: "crtVertex")
        descriptor.fragmentFunction = library.makeFunction(name: "crtFragment")
        descriptor.colorAttachments[0].pixelFormat = .rgba16Float
        let pipeline = try device.makeRenderPipelineState(descriptor: descriptor)
        let source = try XCTUnwrap(device.makeTexture(descriptor: .texture2DDescriptor(
            pixelFormat: .rgba8Unorm_srgb, width: 4, height: 4, mipmapped: false)))
        let targetDescriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .rgba16Float, width: 216, height: 768, mipmapped: false)
        targetDescriptor.usage = [.renderTarget]; targetDescriptor.storageMode = .shared
        let target = try XCTUnwrap(device.makeTexture(descriptor: targetDescriptor))
        let queue = try XCTUnwrap(device.makeCommandQueue())
        var fullFrame = [Float16]()

        func render(_ value: UInt8, peak: Float, lines: Float = 120,
                    dotLines: Float = 120, mask: Float = 0.8,
                    type: Int = TVCRTMaskType.apertureGrille.rawValue) throws -> [Float16] {
            let bytes = [UInt8](repeating: value, count: 4*4*4)
            bytes.withUnsafeBytes { source.replace(region: MTLRegionMake2D(0,0,4,4), mipmapLevel: 0,
                withBytes: $0.baseAddress!, bytesPerRow: 16) }
            let pass = MTLRenderPassDescriptor()
            pass.colorAttachments[0].texture = target
            pass.colorAttachments[0].loadAction = .clear
            pass.colorAttachments[0].storeAction = .store
            let command = try XCTUnwrap(queue.makeCommandBuffer())
            let encoder = try XCTUnwrap(command.makeRenderCommandEncoder(descriptor: pass))
            let grid = TVCRTDisplay.Renderer.dotGrid(lines: Int(dotLines.rounded()), aspect: 216.0/768.0)
            let style = TVCRTMaskStyle.make(type: type, mask: Double(mask))
            var uniforms = SIMD4<Float>(216,768,peak,lines)
            var phosphor = SIMD4<Float>(Float(grid.triads),Float(grid.rows),
                Float(style.fillH),Float(style.fillV))
            var cfg = SIMD4<Float>(Float(style.type.rawValue),Float(style.radius),
                Float(style.meanFill),Float(style.stagger))
            encoder.setFragmentBytes(&phosphor,length: 16,index: 1)
            encoder.setFragmentBytes(&cfg,length: 16,index: 2)
            var beam = SIMD4<Float>.zero
            var optics = SIMD4<Float>(0.018, 0, 0, 0)
            var layout = SIMD4<Float>(0, 0, 1, 1)
            encoder.setFragmentBytes(&beam,length: 16,index: 3)
            encoder.setFragmentBytes(&optics,length: 16,index: 4)
            encoder.setFragmentBytes(&layout,length: 16,index: 5)
            encoder.setRenderPipelineState(pipeline); encoder.setFragmentTexture(source,index: 0)
            encoder.setFragmentBytes(&uniforms,length: 16,index: 0)
            encoder.drawPrimitives(type: .triangle,vertexStart: 0,vertexCount: 3)
            encoder.endEncoding(); command.commit(); command.waitUntilCompleted()
            XCTAssertNil(command.error)
            fullFrame = [Float16](repeating: 0,count: 216*768*4)
            fullFrame.withUnsafeMutableBytes { target.getBytes($0.baseAddress!,bytesPerRow: 216*8,
                from: MTLRegionMake2D(0,0,216,768),mipmapLevel: 0) }
            var pixel = [Float16](repeating: 0,count: 768*4)
            pixel.withUnsafeMutableBytes { target.getBytes($0.baseAddress!,bytesPerRow: 8,
                from: MTLRegionMake2D(111,0,1,768),mipmapLevel: 0) }
            return pixel
        }

        // A resolved dot emits one primary. The other two channels must stay
        // at zero; this is the core difference from a colour mask overlay.
        _ = try render(255, peak: 3, mask: 0.8)
        let row = 387
        var best = [Float](repeating: 0, count: 3)
        var bestX = [Int](repeating: 0, count: 3)
        for x in 0..<216 {
            for c in 0..<3 {
                let v = Float(fullFrame[(row*216+x)*4+c])
                if v > best[c] { best[c] = v; bestX[c] = x }
            }
        }
        for c in 0..<3 {
            XCTAssertGreaterThan(best[c], 1, "Bright phosphors retain EDR output")
            for other in 0..<3 where other != c {
                XCTAssertLessThan(Float(fullFrame[(row*216+bestX[c])*4+other]), 0.01,
                    "A phosphor dot must not emit the other primaries")
            }
        }
        XCTAssertGreaterThan(fullFrame.map(Float.init).max()!, 1, "HDR must survive the floating point target")
        XCTAssertLessThanOrEqual(fullFrame.map(Float.init).max()!, 3.001)

        // Every arrangement must actually emit all three separate primaries.
        var fingerprints = Set<[Int]>()
        for type in TVCRTMaskType.allCases {
            _ = try render(255, peak: 3, mask: 0.8, type: type.rawValue)
            var lit = [Int](repeating: 0, count: 3)
            var fingerprint = [Int]()
            for y in stride(from: 100, to: 668, by: 3) {
                for x in stride(from: 20, to: 196, by: 2) {
                    let rgb = (0..<3).map { Float(fullFrame[(y * 216 + x) * 4 + $0]) }
                    let primary = rgb.indices.max { rgb[$0] < rgb[$1] }!
                    fingerprint.append(Int((rgb[primary] * 100).rounded()) * 3 + primary)
                    if rgb[primary] > 0.4 {
                        lit[primary] += 1
                        for other in 0..<3 where other != primary { XCTAssertLessThan(rgb[other], 0.01) }
                    }
                }
            }
            for count in lit { XCTAssertGreaterThan(count, 10, type.title) }
            XCTAssertTrue(fingerprints.insert(fingerprint).inserted, "Arrangements must not render identically")
        }

        func primariesAt(_ points: [(Int, Int)]) -> Set<Int> {
            Set(points.compactMap { x, y in
                let rgb = (0..<3).map { Float(fullFrame[(y * 216 + x) * 4 + $0]) }
                guard let primary = rgb.indices.max(by: { rgb[$0] < rgb[$1] }), rgb[primary] > 0.2 else { return nil }
                return primary
            })
        }
        let across = (50..<166).map { ($0, 385) }
        let down = (300..<468).map { (111, $0) }
        _ = try render(255, peak: 3, type: TVCRTMaskType.horizontalStripes.rawValue)
        XCTAssertEqual(primariesAt(across).count, 1, "Horizontal bands keep their colour across a row")
        XCTAssertEqual(primariesAt(down).count, 3)
        _ = try render(255, peak: 3, type: TVCRTMaskType.beamIndex.rawValue)
        XCTAssertEqual(primariesAt(across).count, 3)
        XCTAssertEqual(primariesAt(down).count, 1, "Beam-index stripes keep their colour down a column")

        _ = try render(255, peak: 16, mask: 0.8)
        let xdrPeak = fullFrame.map(Float.init).max()!
        XCTAssertGreaterThan(xdrPeak, 4, "XDR output must exceed the old 4× cap")
        XCTAssertLessThanOrEqual(xdrPeak, 16.01)

        _ = try render(255, peak: 1, mask: 0.8)
        XCTAssertLessThanOrEqual(fullFrame.map(Float.init).max()!, 1.001, "SDR must stay bounded")
        _ = try render(0, peak: 3, mask: 0.8)
        XCTAssertEqual(Array(fullFrame.prefix(3)), [0,0,0])

        // The mask is no longer divided out: average light equals
        // source × aperture fill × phosphor peak.
        func average() -> [Double] {
            var sum = [Double](repeating: 0, count: 3)
            // The full frame is an integer number of dot cells and raster
            // rows, so the aperture integral is not biased by a partial cell.
            for y in 0..<768 {
                for x in 0..<216 {
                    for c in 0..<3 { sum[c] += Double(fullFrame[(y*216+x)*4+c]) }
                }
            }
            return sum.map { $0 / Double(216*768) }
        }
        for value: UInt8 in [96,180,255] {
            for peak: Float in [1,3] {
                // The inline mask with no gaps is the neutral reference.
                _ = try render(value, peak: peak, lines: 1080, mask: 0,
                    type: TVCRTMaskType.inlineShadowMask.rawValue)
                let reference = average()
                for type in TVCRTMaskType.allCases {
                    for mask: Float in [0,0.8,1] {
                        _ = try render(value, peak: peak, lines: 1080,
                            mask: mask, type: type.rawValue)
                        let masked = average()
                        let expected = TVCRTMaskStyle.make(type: type.rawValue,
                            mask: Double(mask)).meanFill
                        for c in 0..<3 {
                            XCTAssertGreaterThan(reference[c], 0)
                            XCTAssertEqual(masked[c]/reference[c],expected,accuracy: 0.03,
                                "\(type.title) must dim by its aperture fill")
                        }
                    }
                }
            }
        }
        _ = try render(180, peak: 1, lines: 1080, mask: 0.8)
        let one = average()
        _ = try render(180, peak: 2, lines: 1080, mask: 0.8)
        let two = average()
        for c in 0..<3 {
            XCTAssertEqual(two[c]/one[c], 2, accuracy: 0.03, "Peak scales the dot emission linearly")
        }

        // Once simulated dots are smaller than a display pixel they fade to
        // the triplet average so the grid cannot alias into colour noise.
        _ = try render(180, peak: 2, dotLines: 1080, mask: 0.8)
        let idx = (row*216+80)*4
        let r = Float(fullFrame[idx]), g = Float(fullFrame[idx+1]), b = Float(fullFrame[idx+2])
        XCTAssertEqual(r, g, accuracy: 0.01)
        XCTAssertEqual(g, b, accuracy: 0.01)
        XCTAssertGreaterThan(r, 0)

        func peaks(_ column: [Float16]) -> Int {
            func level(_ y: Int) -> Float {
                let r = Float(column[y*4])
                let g = Float(column[y*4+1])
                let b = Float(column[y*4+2])
                return r > g ? (r > b ? r : b) : (g > b ? g : b)
            }
            return (100..<668).filter { y in
                level(y) > level(y-1) && level(y) >= level(y+1)
            }.count
        }
        let low = peaks(try render(255, peak: 1, lines: 120, mask: 0))
        let high = peaks(try render(255, peak: 1, lines: 240, mask: 0))
        XCTAssertGreaterThan(low, 60)
        XCTAssertGreaterThan(high, low * 3 / 2, "Increasing the count must produce more visible scanlines")
    }
}
