import SwiftUI
import MetalKit
import CoreVideo

struct TVCRTGlassSettings: Equatable {
    let scatter: Double
    let halo: Double
    let radius: Double
    let reflection: Double
    let curvature: Double
    init(scatter: Double = 0.12, halo: Double = 0.18, radius: Double = 12,
         reflection: Double = 0.08, curvature: Double = 0.018) {
        self.scatter = scatter.isFinite ? min(1, max(0, scatter)) : 0.12
        self.halo = halo.isFinite ? min(1, max(0, halo)) : 0.18
        self.radius = radius.isFinite ? min(40, max(2, radius)) : 12
        self.reflection = reflection.isFinite ? min(0.3, max(0, reflection)) : 0.08
        self.curvature = curvature.isFinite ? min(0.036, max(0, curvature)) : 0.018
    }
    var hasDiffusion: Bool { scatter > 0 || halo > 0 }
}

/// Owns the Core Video wrapper until the GPU finishes reading the camera frame.
private final class TVCRTCameraTexture: @unchecked Sendable {
    let frame: TVCRTCameraFrames.Frame
    let wrapper: CVMetalTexture
    let texture: MTLTexture
    init(frame: TVCRTCameraFrames.Frame, wrapper: CVMetalTexture, texture: MTLTexture) {
        self.frame = frame; self.wrapper = wrapper; self.texture = texture
    }
}

/// Optical layer runs after phosphor persistence. Neither the scattered light
/// nor the camera reflection is fed back into the phosphor history.
@MainActor
final class TVCRTGlassRenderer {
    private let device: MTLDevice
    private let highlightsPipeline: MTLRenderPipelineState
    private let glassPipeline: MTLRenderPipelineState
    private var highlights: MTLTexture?
    private var cameraCache: CVMetalTextureCache?
    private var cameraTexture: TVCRTCameraTexture?
    private let black: MTLTexture
    private(set) var scene: MTLTexture?

    init(device: MTLDevice, library: MTLLibrary) throws {
        self.device = device
        func pipeline(_ fragment: String) throws -> MTLRenderPipelineState {
            let d = MTLRenderPipelineDescriptor()
            d.vertexFunction = library.makeFunction(name: "crtVertex")
            d.fragmentFunction = library.makeFunction(name: fragment)
            d.colorAttachments[0].pixelFormat = .rgba16Float
            return try device.makeRenderPipelineState(descriptor: d)
        }
        highlightsPipeline = try pipeline("crtGlassHighlights")
        glassPipeline = try pipeline("crtGlassComposite")
        let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm_srgb, width: 1, height: 1, mipmapped: false)
        d.storageMode = .shared; d.usage = [.shaderRead]
        guard let black = device.makeTexture(descriptor: d) else { throw NSError(domain: "AnaLine.CRTGlass", code: 1) }
        self.black = black
        var bytes: UInt32 = 0
        black.replace(region: MTLRegionMake2D(0,0,1,1), mipmapLevel: 0, withBytes: &bytes, bytesPerRow: 4)
        CVMetalTextureCacheCreate(kCFAllocatorDefault, nil, device, nil, &cameraCache)
    }
    func release() { scene = nil; highlights = nil; cameraTexture = nil }
    func clearCamera() { cameraTexture = nil }
    func prepare(width: Int, height: Int) throws {
        guard scene?.width != width || scene?.height != height else { return }
        func texture(_ w: Int, _ h: Int) throws -> MTLTexture {
            let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba16Float,
                width: max(1,w), height: max(1,h), mipmapped: true)
            d.storageMode = .private; d.usage = [.renderTarget, .shaderRead]
            guard let t = device.makeTexture(descriptor: d) else { throw NSError(domain: "AnaLine.CRTGlass", code: 2) }
            return t
        }
        let full = try texture(width, height), half = try texture((width+1)/2, (height+1)/2)
        scene = full; highlights = half
    }
    private func camera(_ frame: TVCRTCameraFrames.Frame?) -> MTLTexture? {
        guard let frame else { cameraTexture = nil; return nil }
        if cameraTexture?.frame.serial == frame.serial { return cameraTexture?.texture }
        guard let cameraCache else { cameraTexture = nil; return nil }
        var wrapper: CVMetalTexture?
        let result = CVMetalTextureCacheCreateTextureFromImage(kCFAllocatorDefault, cameraCache, frame.buffer,
            nil, .bgra8Unorm_srgb, CVPixelBufferGetWidth(frame.buffer), CVPixelBufferGetHeight(frame.buffer), 0, &wrapper)
        guard result == kCVReturnSuccess, let wrapper, let texture = CVMetalTextureGetTexture(wrapper) else {
            cameraTexture = nil; return nil
        }
        cameraTexture = TVCRTCameraTexture(frame: frame, wrapper: wrapper, texture: texture)
        return texture
    }
    func encode(command: MTLCommandBuffer, target: MTLTexture, settings: TVCRTGlassSettings,
                peak: Double, cameraFrame: TVCRTCameraFrames.Frame? = nil) throws {
        guard let scene, let highlights else { return }
        func encoder(target: MTLTexture) throws -> MTLRenderCommandEncoder {
            let pass = MTLRenderPassDescriptor()
            pass.colorAttachments[0].texture = target
            pass.colorAttachments[0].loadAction = .dontCare
            pass.colorAttachments[0].storeAction = .store
            guard let result = command.makeRenderCommandEncoder(descriptor: pass) else { throw NSError(domain: "AnaLine.CRTGlass", code: 3) }
            return result
        }
        if settings.hasDiffusion {
            if settings.halo > 0 {
                let e = try encoder(target: highlights)
                var p = Float(peak)
                e.setRenderPipelineState(highlightsPipeline)
                e.setFragmentTexture(scene, index: 0)
                e.setFragmentBytes(&p, length: 4, index: 0)
                e.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3); e.endEncoding()
            }
            guard let blit = command.makeBlitCommandEncoder() else { throw NSError(domain: "AnaLine.CRTGlass", code: 4) }
            blit.generateMipmaps(for: scene)
            if settings.halo > 0 { blit.generateMipmaps(for: highlights) }
            blit.endEncoding()
        }
        let reflected = settings.reflection > 0 ? camera(cameraFrame) : nil
        let e = try encoder(target: target)
        var u = SIMD4<Float>(Float(settings.scatter), Float(settings.halo), Float(settings.radius), Float(peak))
        var r = SIMD4<Float>(Float(settings.reflection), reflected == nil ? 0 : 1,
            Float(settings.curvature), 0)
        e.setRenderPipelineState(glassPipeline)
        e.setFragmentTexture(scene, index: 0)
        e.setFragmentTexture(settings.halo > 0 ? highlights : black, index: 1)
        e.setFragmentTexture(reflected ?? black, index: 2)
        e.setFragmentBytes(&u, length: 16, index: 0)
        e.setFragmentBytes(&r, length: 16, index: 1)
        e.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3); e.endEncoding()
        if let cameraTexture, reflected != nil {
            command.addCompletedHandler { [cameraTexture] _ in _ = cameraTexture }
        }
    }
}

struct TVCRTGlassControls: View {
    let enabled: Bool
    @ObservedObject private var camera = TVCRTCameraReflection.shared
    @AppStorage("tvCRTGlassScatter") private var scatter = 0.12
    @AppStorage("tvCRTGlassHalo") private var halo = 0.18
    @AppStorage("tvCRTGlassRadius") private var radius = 12.0
    @AppStorage("tvCRTCameraReflection") private var reflected = false
    @AppStorage("tvCRTCameraReflectionStrength") private var strength = 0.08
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(L("Glass scattering and reflection"))
                .font(.system(size: 10, weight: .medium)).foregroundStyle(.white.opacity(0.7))
            HStack(spacing: 16) {
                TVRotaryParameter(name: "Glass scatter", value: Binding(
                    get: { Float(TVCRTGlassSettings(scatter: scatter).scatter) }, set: { scatter = Double($0) }),
                    range: 0...1, initial: 0.12, step: 0.01, percent: true, active: enabled)
                TVRotaryParameter(name: "Highlight halo", value: Binding(
                    get: { Float(TVCRTGlassSettings(halo: halo).halo) }, set: { halo = Double($0) }),
                    range: 0...1, initial: 0.18, step: 0.01, percent: true, active: enabled)
            }
            HStack(spacing: 16) {
                TVRotaryParameter(name: "Halo radius", value: Binding(
                    get: { Float(TVCRTGlassSettings(radius: radius).radius) }, set: { radius = Double($0) }),
                    range: 2...40, initial: 12, step: 1, unit: "px", digits: 0, active: enabled)
                TVRotaryParameter(name: "Camera reflection", value: Binding(
                    get: { Float(TVCRTGlassSettings(reflection: strength).reflection) }, set: { strength = Double($0) }),
                    range: 0...0.3, initial: 0.08, step: 0.01, percent: true, active: enabled && reflected)
            }
            Toggle(L("Live camera glass reflection"), isOn: $reflected)
                .font(.system(size: 10)).toggleStyle(.switch).disabled(!enabled)
            if reflected {
                Text(L(camera.status.text) + (camera.deviceName.isEmpty ? "" : " · " + camera.deviceName))
                    .font(.system(size: 10)).foregroundStyle(.white.opacity(0.7))
            }
            Text(L("Camera reflection is mirrored, softened and strongest in dark areas. Local only; no recording or audio capture."))
                .font(.system(size: 10)).foregroundStyle(.white.opacity(0.6))
        }
    }
}
