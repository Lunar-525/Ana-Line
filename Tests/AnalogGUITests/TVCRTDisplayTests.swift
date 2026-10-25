import XCTest
import MetalKit
@testable import AnalogGUI

@MainActor
final class TVCRTDisplayTests: XCTestCase {
    func testPeakTracksCurrentHeadroomAndSDRFallback() {
        XCTAssertEqual(TVCRTDisplay.Renderer.peak(hdr: true, brightness: 4, headroom: 1.6), 1.6)
        XCTAssertEqual(TVCRTDisplay.Renderer.peak(hdr: false, brightness: 4, headroom: 8), 1)
        XCTAssertEqual(TVCRTDisplay.Renderer.peak(hdr: true, brightness: 4, headroom: 1), 1)
        XCTAssertEqual(TVCRTDisplay.Renderer.peak(hdr: true, brightness: .nan, headroom: 8), 1)
    }

    func testScanlineCountUsesSourceOrSanitizesManualValue() {
        XCTAssertEqual(TVCRTDisplay.Renderer.lineCount(0, sourceHeight: 576), 576)
        XCTAssertEqual(TVCRTDisplay.Renderer.lineCount(.nan, sourceHeight: 480), 480)
        XCTAssertEqual(TVCRTDisplay.Renderer.lineCount(239.8, sourceHeight: 576), 240)
        XCTAssertEqual(TVCRTDisplay.Renderer.lineCount(20, sourceHeight: 576), 120)
        XCTAssertEqual(TVCRTDisplay.Renderer.lineCount(2000, sourceHeight: 576), 1080)
    }

    func testShaderEmitsExtendedLightAndPreservesBlack() throws {
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
        func render(_ value: UInt8, peak: Float, lines: Float = 4, maskStrength: Float = 0, pitch: Int = 9) throws -> [Float16] {
            let bytes = [UInt8](repeating: value, count: 4*4*4)
            bytes.withUnsafeBytes { source.replace(region: MTLRegionMake2D(0,0,4,4), mipmapLevel: 0,
                withBytes: $0.baseAddress!, bytesPerRow: 16) }
            let pass = MTLRenderPassDescriptor()
            pass.colorAttachments[0].texture = target
            pass.colorAttachments[0].loadAction = .clear
            pass.colorAttachments[0].storeAction = .store
            let command = try XCTUnwrap(queue.makeCommandBuffer())
            let encoder = try XCTUnwrap(command.makeRenderCommandEncoder(descriptor: pass))
            var uniforms = SIMD4<Float>(216,768,peak,lines)
            var mask = SIMD4<Float>(Float(pitch),maskStrength,0,0)
            var mean = TVCRTDisplay.Renderer.maskMeans[pitch-6]
            encoder.setFragmentBytes(&mean,length: 16,index: 2)
            encoder.setFragmentBytes(&mask,length: 16,index: 1)
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
        let hdr = try render(255,peak: 3)
        XCTAssertGreaterThan(Float(hdr[384*4]),1, "HDR must survive the floating point target")
        let sdr = try render(255,peak: 1)
        XCTAssertLessThanOrEqual(Float(sdr[384*4]),1)
        let black = try render(0,peak: 3)
        XCTAssertEqual(Array(black.prefix(3)),[0,0,0])
        func peaks(_ column: [Float16]) -> Int {
            (100..<668).filter { y in
                column[y*4] > column[(y-1)*4] && column[y*4] >= column[(y+1)*4]
            }.count
        }
        let phosphor = try render(180, peak: 3, maskStrength: 1)
        let green = (300..<450).map { Float(phosphor[$0*4+1]) }
        let red = (300..<450).map { Float(phosphor[$0*4]) }
        XCTAssertGreaterThan(green.max()!, red.max()! * 3, "Each slot must emit its own primary")
        XCTAssertLessThan(green.min()!, green.max()! * 0.5, "Slots need visible dark matrix gaps")
        XCTAssertGreaterThan(green.max()!, 1, "Bright phosphors retain EDR output")
        func average(pitch: Int) -> [Double] {
            (0..<3).map { c in
                var sum = 0.0
                for y in (384-8*pitch)..<(384+8*pitch) {
                    for x in (108-4*pitch)..<(108+4*pitch) {
                        sum += Double(fullFrame[(y*216+x)*4+c])
                    }
                }
                return sum/Double(128*pitch*pitch)
            }
        }
        for value: UInt8 in [96,180,255] {
            for peak: Float in [1,3] {
                for pitch in [6,7,9,12,18] {
                    _ = try render(value,peak: peak)
                    let reference = average(pitch: pitch)
                    for strength: Float in [0.5,0.8,1] {
                        _ = try render(value,peak: peak,maskStrength: strength,pitch: pitch)
                        let masked = average(pitch: pitch)
                        for c in 0..<3 {
                            XCTAssertEqual(masked[c]/reference[c],1,accuracy: 0.035,
                                "Mask must preserve channel energy at strength \(strength), input \(value), peak \(peak)")
                        }
                        XCTAssertLessThanOrEqual(fullFrame.map(Float.init).max()!,peak+0.003)
                    }
                }
            }
        }
        let low = peaks(try render(255, peak: 1, lines: 120))
        let high = peaks(try render(255, peak: 1, lines: 240))
        XCTAssertGreaterThan(low, 60)
        XCTAssertGreaterThan(high, low * 3 / 2, "Increasing the count must produce more visible scanlines")
    }
}
