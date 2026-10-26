import XCTest
import SwiftUI
import MetalKit
@testable import AnalogGUI

@MainActor
final class TVCRTPhosphorTests: XCTestCase {
    func testDecayIsInSecondsAndSettingsAreBounded() {
        let settings = TVCRTBeamSettings(decayMS: 20)
        let once = settings.retention(seconds: 0.04)
        let half = settings.retention(seconds: 0.02)
        for channel in 0..<3 { XCTAssertEqual(once[channel], half[channel] * half[channel], accuracy: 1e-6) }
        XCTAssertEqual(once.x, Float(exp(-2.0)), accuracy: 1e-6)
        XCTAssertGreaterThan(once.x, once.y)
        XCTAssertGreaterThan(once.y, once.z)
        XCTAssertEqual(TVCRTBeamSettings(decayMS: 0).retention(seconds: 0.02), .zero)
        XCTAssertEqual(settings.retention(seconds: .nan), .zero)
        XCTAssertEqual(settings.retention(seconds: -1), .zero)
        XCTAssertEqual(TVCRTBeamSettings(spot: 99, decayMS: 500, convergence: 99),
            TVCRTBeamSettings(spot: 2, decayMS: 80, convergence: 3))
        XCTAssertEqual(TVCRTBeamSettings(spot: .nan, decayMS: .infinity, convergence: .nan), TVCRTBeamSettings())
    }

    func testGPUHistoryUsesElapsedTimeDoesNotAccumulateAndResets() throws {
        guard let device = MTLCreateSystemDefaultDevice() else { throw XCTSkip("Metal unavailable") }
        let library = try device.makeLibrary(source: TVCRTDisplay.Renderer.shader, options: nil)
        let queue = try XCTUnwrap(device.makeCommandQueue())
        let history = try TVCRTPhosphorHistory(device: device, library: library)
        let settings = TVCRTBeamSettings(spot: 0, decayMS: 20, convergence: 0)
        try history.prepare(width: 4, height: 4)

        func texture(_ width: Int = 4) throws -> MTLTexture {
            let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba16Float, width: width, height: width, mipmapped: false)
            d.storageMode = .shared; d.usage = [.renderTarget, .shaderRead]
            return try XCTUnwrap(device.makeTexture(descriptor: d))
        }
        var target = try texture()
        func render(_ colour: SIMD3<Float>, at now: Double, peak: Double = 8) throws -> SIMD3<Float> {
            let command = try XCTUnwrap(queue.makeCommandBuffer())
            let pass = MTLRenderPassDescriptor()
            pass.colorAttachments[0].texture = history.emission
            pass.colorAttachments[0].loadAction = .clear
            pass.colorAttachments[0].storeAction = .store
            pass.colorAttachments[0].clearColor = MTLClearColorMake(Double(colour.x), Double(colour.y), Double(colour.z), 1)
            let encoder = try XCTUnwrap(command.makeRenderCommandEncoder(descriptor: pass)); encoder.endEncoding()
            try history.encode(command: command, target: target, now: now, settings: settings, peak: peak)
            command.commit(); command.waitUntilCompleted(); XCTAssertNil(command.error)
            var pixel = [Float16](repeating: 0, count: 4)
            pixel.withUnsafeMutableBytes { target.getBytes($0.baseAddress!, bytesPerRow: 8, from: MTLRegionMake2D(1,1,1,1), mipmapLevel: 0) }
            return SIMD3(Float(pixel[0]), Float(pixel[1]), Float(pixel[2]))
        }
        XCTAssertEqual(try render(SIMD3(repeating: 3), at: 0), SIMD3(repeating: 3))
        XCTAssertEqual(try render(SIMD3(repeating: 3), at: 0.02), SIMD3(repeating: 3), "A still image must not brighten by accumulating frames")
        let after40 = try render(.zero, at: 0.06)
        let expected = settings.retention(seconds: 0.04) * 3
        for c in 0..<3 { XCTAssertEqual(after40[c], expected[c], accuracy: 0.002) }
        history.reset()
        _ = try render(SIMD3(repeating: 3), at: 1)
        _ = try render(.zero, at: 1.02)
        let twoSteps = try render(.zero, at: 1.04)
        for c in 0..<3 { XCTAssertEqual(twoSteps[c], after40[c], accuracy: 0.002, "Refresh cadence must not change decay") }
        history.reset()
        XCTAssertEqual(try render(.zero, at: 2), .zero, "Seeking must discard residual light")
        _ = try render(SIMD3(repeating: 3), at: 3)
        XCTAssertLessThanOrEqual(try render(.zero, at: 3.001, peak: 1).max(), 1, "A reduction to SDR must cap old HDR light")
        try history.prepare(width: 2, height: 2); target = try texture(2)
        XCTAssertEqual(try render(.zero, at: 4), .zero, "Resizing must not reuse misaligned phosphors")
        history.release(); XCTAssertNil(history.emission)
    }

    func testTransportInvalidatesPhosphorsWithoutClearingForNormalFrames() {
        let model = PreviewModel()
        model.tool = .tv; model.tvDuration = 10
        let epoch = model.tvPreviewState.crtHistoryID
        model.tvTime = 0.04
        XCTAssertEqual(model.tvPreviewState.crtHistoryID, epoch)
        model.seekTV(to: 2)
        XCTAssertNotEqual(model.tvPreviewState.crtHistoryID, epoch)
        let sought = model.tvPreviewState.crtHistoryID
        model.tvStandard = .ntsc
        XCTAssertNotEqual(model.tvPreviewState.crtHistoryID, sought)
    }

    func testGPUBeamWidensBrightFeaturesAndSeparatesCorners() throws {
        guard let device = MTLCreateSystemDefaultDevice() else { throw XCTSkip("Metal unavailable") }
        // Exercise the production beam sampler without the mask/scanline
        // modulation, which otherwise obscures a direct spot-width measurement.
        let probe = """
        fragment float4 beamProbe(Vertex v [[stage_in]], texture2d<float> source [[texture(0)]],
            constant float4 &beam [[buffer(0)]]) {
            constexpr sampler s(coord::normalized, address::clamp_to_edge, filter::linear, mip_filter::linear);
            return float4(beamSample(source,s,v.uv,float2(0),0,beam),1);
        }
        """
        let library = try device.makeLibrary(source: TVCRTDisplay.Renderer.shader + probe, options: nil)
        let descriptor = MTLRenderPipelineDescriptor()
        descriptor.vertexFunction = library.makeFunction(name: "crtVertex")
        descriptor.fragmentFunction = library.makeFunction(name: "beamProbe")
        descriptor.colorAttachments[0].pixelFormat = .rgba16Float
        let pipeline = try device.makeRenderPipelineState(descriptor: descriptor)
        let queue = try XCTUnwrap(device.makeCommandQueue())
        let width = 256, height = 192
        let source = try XCTUnwrap(device.makeTexture(descriptor: .texture2DDescriptor(
            pixelFormat: .rgba8Unorm_srgb, width: width, height: height, mipmapped: true)))
        let targetDescriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba16Float,
            width: width, height: height, mipmapped: false)
        targetDescriptor.storageMode = .shared; targetDescriptor.usage = [.renderTarget]
        let target = try XCTUnwrap(device.makeTexture(descriptor: targetDescriptor))

        func render(value: UInt8 = 255, spot: Double, convergence: Double = 0) throws -> [Float16] {
            var bytes = [UInt8](repeating: 0, count: width * height * 4)
            for y in 0..<height {
                for x in [31,32,127,128] {
                    for c in 0..<3 { bytes[(y * width + x) * 4 + c] = value }
                }
            }
            bytes.withUnsafeBytes { source.replace(region: MTLRegionMake2D(0,0,width,height), mipmapLevel: 0,
                withBytes: $0.baseAddress!, bytesPerRow: width * 4) }
            let command = try XCTUnwrap(queue.makeCommandBuffer())
            let blit = try XCTUnwrap(command.makeBlitCommandEncoder())
            blit.generateMipmaps(for: source); blit.endEncoding()
            let pass = MTLRenderPassDescriptor()
            pass.colorAttachments[0].texture = target; pass.colorAttachments[0].storeAction = .store
            let encoder = try XCTUnwrap(command.makeRenderCommandEncoder(descriptor: pass))
            var beam = TVCRTBeamSettings(spot: spot, convergence: convergence).spatialUniform
            encoder.setRenderPipelineState(pipeline); encoder.setFragmentTexture(source, index: 0)
            encoder.setFragmentBytes(&beam, length: 16, index: 0)
            encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
            encoder.endEncoding(); command.commit(); command.waitUntilCompleted(); XCTAssertNil(command.error)
            var result = [Float16](repeating: 0, count: width * height * 4)
            result.withUnsafeMutableBytes { target.getBytes($0.baseAddress!, bytesPerRow: width * 8,
                from: MTLRegionMake2D(0,0,width,height), mipmapLevel: 0) }
            return result
        }
        func widthSquared(_ pixels: [Float16], y: Int = 96) -> Double {
            var sum = 0.0, moment = 0.0
            for x in 116..<140 {
                let light = Double(pixels[(y * width + x) * 4])
                sum += light; moment += light * pow(Double(x) - 127.5, 2)
            }
            return moment / max(1e-9, sum)
        }
        let sharp = try render(spot: 0)
        let bright = try render(spot: 1.5)
        let dim = try render(value: 80, spot: 1.5)
        XCTAssertGreaterThan(widthSquared(bright), widthSquared(sharp) + 0.2)
        XCTAssertGreaterThan(widthSquared(bright), widthSquared(dim) + 0.1, "Bright beams should be wider than dim ones")
        XCTAssertGreaterThan(widthSquared(bright, y: 12), widthSquared(bright), "Off-axis focus should be softer")
        let misaligned = try render(spot: 0, convergence: 3)
        func separation(_ y: Int, _ range: Range<Int>) -> Double {
            func centre(_ channel: Int) -> Double {
                var sum = 0.0, moment = 0.0
                for x in range {
                    let light = Double(misaligned[(y * width + x) * 4 + channel])
                    sum += light; moment += light * Double(x)
                }
                return moment / max(1e-9, sum)
            }
            return abs(centre(0) - centre(2))
        }
        XCTAssertLessThan(separation(96, 116..<140), 0.05, "Centre convergence stays aligned")
        XCTAssertGreaterThan(separation(12, 20..<44), 1, "Corner white lines split into red and blue")
    }

    func testBeamControlsRenderInRackStyle() throws {
        let renderer = ImageRenderer(content: TVServicePanel(title: "CRT display") {
            TVCRTBeamControls(enabled: true)
        })
        renderer.scale = 2
        let image = try XCTUnwrap(renderer.cgImage)
        XCTAssertEqual(image.width, 680)
        if let path = ProcessInfo.processInfo.environment["ANALINE_CRT_BEAM_PREVIEW"] {
            let png = try XCTUnwrap(NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]))
            try png.write(to: URL(fileURLWithPath: path))
        }
    }
}
