import XCTest
import SwiftUI
import MetalKit
import CoreVideo
@testable import AnalogGUI

@MainActor
final class TVCRTGlassTests: XCTestCase {
    private func cameraBuffer() throws -> CVPixelBuffer {
        var buffer: CVPixelBuffer?
        let attributes: [String: Any] = [kCVPixelBufferMetalCompatibilityKey as String: true,
            kCVPixelBufferIOSurfacePropertiesKey as String: [:]]
        XCTAssertEqual(CVPixelBufferCreate(kCFAllocatorDefault, 64, 48, kCVPixelFormatType_32BGRA,
            attributes as CFDictionary, &buffer), kCVReturnSuccess)
        let result = try XCTUnwrap(buffer)
        CVPixelBufferLockBaseAddress(result, [])
        defer { CVPixelBufferUnlockBaseAddress(result, []) }
        let bytes = try XCTUnwrap(CVPixelBufferGetBaseAddress(result)).assumingMemoryBound(to: UInt8.self)
        let stride = CVPixelBufferGetBytesPerRow(result)
        for y in 0..<48 { for x in 0..<64 {
            let index = y * stride + x * 4
            bytes[index] = x < 32 ? 0 : 255
            bytes[index+1] = 0
            bytes[index+2] = x < 32 ? 255 : 0
            bytes[index+3] = 255
        } }
        return result
    }

    func testCameraFrameSlotExpiresAndClearsWithoutCapturing() throws {
        let frames = TVCRTCameraFrames(), buffer = try cameraBuffer()
        XCTAssertNil(frames.latest(now: 1))
        frames.publish(buffer, now: 1)
        let first = try XCTUnwrap(frames.latest(now: 1.1))
        frames.publish(buffer, now: 1.2)
        XCTAssertGreaterThan(try XCTUnwrap(frames.latest(now: 1.3)).serial, first.serial)
        XCTAssertNil(frames.latest(now: 3), "Interrupted capture must not retain an old face indefinitely")
        frames.clear(); XCTAssertNil(frames.latest(now: 1.3))
    }

    func testSettingsAreBoundedAndMissingUsageDescriptionDoesNotRequestAccess() {
        XCTAssertEqual(TVCRTGlassSettings(scatter: -5, halo: 9, radius: 100, reflection: 1),
            TVCRTGlassSettings(scatter: 0, halo: 1, radius: 40, reflection: 0.3))
        XCTAssertEqual(TVCRTGlassSettings(scatter: .nan, halo: .infinity, radius: .nan, reflection: .infinity), TVCRTGlassSettings())
        guard Bundle.main.object(forInfoDictionaryKey: "NSCameraUsageDescription") == nil else { return }
        let camera = TVCRTCameraReflection(), a = UUID(), b = UUID()
        camera.setConsumer(a, active: true)
        XCTAssertEqual(camera.status, .packagedAppRequired)
        camera.setConsumer(b, active: true)
        camera.setConsumer(a, active: false)
        XCTAssertEqual(camera.status, .packagedAppRequired, "A second view keeps its consumer")
        camera.setConsumer(b, active: false)
        XCTAssertEqual(camera.status, .off)
        XCTAssertNil(camera.latestFrame)
    }

    func testGPUScatterHaloMirrorAndReflectionRemainOutsidePersistence() throws {
        guard let device = MTLCreateSystemDefaultDevice() else { throw XCTSkip("Metal unavailable") }
        let library = try device.makeLibrary(source: TVCRTDisplay.Renderer.shader, options: nil)
        let glass = try TVCRTGlassRenderer(device: device, library: library)
        let history = try TVCRTPhosphorHistory(device: device, library: library)
        let queue = try XCTUnwrap(device.makeCommandQueue())
        let w = 256, h = 192
        try glass.prepare(width: w, height: h)
        try history.prepare(width: w, height: h)
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba16Float, width: w, height: h, mipmapped: false)
        descriptor.storageMode = .shared; descriptor.usage = [.renderTarget]
        let target = try XCTUnwrap(device.makeTexture(descriptor: descriptor))
        let frames = TVCRTCameraFrames(); frames.publish(try cameraBuffer())
        let frame = try XCTUnwrap(frames.latest())
        var clock = 0.0

        func render(_ settings: TVCRTGlassSettings, colour: Double = 0, patch: Bool = false,
                    reflection: Bool = false, persistent: Bool = false) throws -> [Float16] {
            let command = try XCTUnwrap(queue.makeCommandBuffer())
            let pass = MTLRenderPassDescriptor()
            pass.colorAttachments[0].texture = persistent ? history.emission : glass.scene
            pass.colorAttachments[0].loadAction = .clear; pass.colorAttachments[0].storeAction = .store
            pass.colorAttachments[0].clearColor = MTLClearColorMake(colour,colour,colour,1)
            let encoder = try XCTUnwrap(command.makeRenderCommandEncoder(descriptor: pass)); encoder.endEncoding()
            if patch {
                // Copy a small lit patch into the scene, leaving its surroundings black.
                let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba16Float, width: 8, height: 8, mipmapped: false)
                d.storageMode = .shared
                let light = try XCTUnwrap(device.makeTexture(descriptor: d))
                let bytes = [Float16](repeating: 1, count: 8*8*4)
                bytes.withUnsafeBytes { light.replace(region: MTLRegionMake2D(0,0,8,8), mipmapLevel: 0,
                    withBytes: $0.baseAddress!, bytesPerRow: 64) }
                let blit = try XCTUnwrap(command.makeBlitCommandEncoder())
                blit.copy(from: light, sourceSlice: 0, sourceLevel: 0, sourceOrigin: MTLOrigin(x:0,y:0,z:0),
                    sourceSize: MTLSize(width:8,height:8,depth:1), to: try XCTUnwrap(glass.scene), destinationSlice: 0,
                    destinationLevel: 0, destinationOrigin: MTLOrigin(x:124,y:92,z:0))
                blit.endEncoding()
            }
            if persistent {
                clock += 0.02
                try history.encode(command: command, target: try XCTUnwrap(glass.scene), now: clock,
                    settings: TVCRTBeamSettings(decayMS: 40), peak: 1)
            }
            try glass.encode(command: command, target: target, settings: settings, peak: 1,
                cameraFrame: reflection ? frame : nil)
            command.commit(); command.waitUntilCompleted(); XCTAssertNil(command.error)
            var result = [Float16](repeating: 0, count: w*h*4)
            result.withUnsafeMutableBytes { target.getBytes($0.baseAddress!, bytesPerRow: w*8,
                from: MTLRegionMake2D(0,0,w,h), mipmapLevel: 0) }
            return result
        }
        func pixel(_ p: [Float16], _ x: Int, _ y: Int = 96, _ c: Int = 0) -> Double { Double(p[(y*w+x)*4+c]) }
        let off = TVCRTGlassSettings(scatter: 0, halo: 0, reflection: 0)
        let black = try render(TVCRTGlassSettings())
        XCTAssertEqual(pixel(black,128), 0)
        let flat = try render(TVCRTGlassSettings(scatter: 1, halo: 0), colour: 0.5)
        XCTAssertEqual(pixel(flat,128), 0.5, accuracy: 0.001, "Pure scatter preserves a uniform field")
        let sharp = try render(off, patch: true)
        let scattered = try render(TVCRTGlassSettings(scatter: 1, halo: 0, radius: 40), patch: true)
        XCTAssertGreaterThan(pixel(scattered,137), pixel(sharp,137), "Scatter moves light into adjacent dark glass")
        XCTAssertLessThan(pixel(scattered,128), pixel(sharp,128), "Scatter does not merely brighten the frame")
        let halo = try render(TVCRTGlassSettings(scatter: 0, halo: 1, radius: 40), patch: true)
        XCTAssertGreaterThan(pixel(halo,139), pixel(sharp,139), "A bright patch produces an extended halo")
        let dimHalo = try render(TVCRTGlassSettings(scatter: 0, halo: 1), colour: 0.1)
        XCTAssertEqual(pixel(dimHalo,128), 0.1, accuracy: 0.001, "Dim areas should not generate highlight bloom")
        XCTAssertLessThanOrEqual(halo.map(Float.init).max()!, 1)

        let reflectionSettings = TVCRTGlassSettings(scatter: 0, halo: 0, reflection: 0.3)
        let mirrored = try render(reflectionSettings, reflection: true)
        XCTAssertGreaterThan(pixel(mirrored,64,96,2), 0.01, "Camera blue on the right must reflect on the left")
        XCTAssertLessThan(pixel(mirrored,64,96,0), 0.001)
        XCTAssertGreaterThan(pixel(mirrored,192,96,0), 0.01)
        let lit = try render(reflectionSettings, colour: 0.5, reflection: true)
        XCTAssertLessThan(pixel(lit,64,96,2) - 0.5, pixel(mirrored,64,96,2), "Reflection is weaker over a lit screen")
        let missing = try render(reflectionSettings)
        XCTAssertEqual(pixel(missing,64,96,2), 0, "Removing the camera frame must clear its old texture")
        history.reset()
        let cameraOnly = try render(reflectionSettings, reflection: true, persistent: true)
        XCTAssertGreaterThan(pixel(cameraOnly,64,96,2), 0.01)
        let afterCamera = try render(reflectionSettings, persistent: true)
        XCTAssertEqual(pixel(afterCamera,64,96,2), 0, "A reflection must never leave phosphor afterglow")
        glass.release(); XCTAssertNil(glass.scene)
    }

    func testGlassControlsRenderInRackStyle() throws {
        let renderer = ImageRenderer(content: TVServicePanel(title: "CRT display") {
            TVCRTGlassControls(enabled: true)
        })
        renderer.scale = 2
        XCTAssertEqual(try XCTUnwrap(renderer.cgImage).width, 680)
    }
}
