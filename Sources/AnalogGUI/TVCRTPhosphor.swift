import Foundation
import MetalKit
import SwiftUI

/// Display-only approximations, in source pixels and milliseconds. Zero
/// bypasses each effect, so the original spatial renderer remains available.
struct TVCRTBeamSettings: Equatable {
    let spot: Double
    let decayMS: Double
    let convergence: Double

    init(spot: Double = 0.35, decayMS: Double = 18, convergence: Double = 0.25) {
        self.spot = spot.isFinite ? min(2, max(0, spot)) : 0.35
        self.decayMS = decayMS.isFinite ? min(80, max(0, decayMS)) : 18
        self.convergence = convergence.isFinite ? min(3, max(0, convergence)) : 0.25
    }

    var spatialUniform: SIMD4<Float> { SIMD4(Float(spot), Float(convergence), 0, 0) }

    /// Modest RGB differences are an artistic short-persistence preset, not
    /// a measured phosphor formulation. Never derive decay from frame count.
    func retention(seconds: Double) -> SIMD3<Float> {
        guard decayMS > 0, seconds.isFinite, seconds >= 0 else { return .zero }
        let tau = decayMS / 1000
        return SIMD3(Float(exp(-seconds / tau)), Float(exp(-seconds / (tau * 0.85))),
            Float(exp(-seconds / (tau * 0.7))))
    }
}

/// Screen-space emission history. The second pass writes both the drawable
/// and the next history in one render pass; textures are private to each view.
@MainActor
final class TVCRTPhosphorHistory {
    private let device: MTLDevice
    private let pipeline: MTLRenderPipelineState
    private(set) var emission: MTLTexture?
    private var history: [MTLTexture] = []
    private var next = 0
    private var lastTime: Double?

    init(device: MTLDevice, library: MTLLibrary) throws {
        self.device = device
        let descriptor = MTLRenderPipelineDescriptor()
        descriptor.vertexFunction = library.makeFunction(name: "crtVertex")
        descriptor.fragmentFunction = library.makeFunction(name: "crtPersistence")
        descriptor.colorAttachments[0].pixelFormat = .rgba16Float
        descriptor.colorAttachments[1].pixelFormat = .rgba16Float
        pipeline = try device.makeRenderPipelineState(descriptor: descriptor)
    }

    func reset() { lastTime = nil }

    func release() {
        emission = nil; history = []; next = 0; reset()
    }

    func prepare(width: Int, height: Int) throws {
        guard emission?.width != width || emission?.height != height else { return }
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba16Float,
            width: max(1, width), height: max(1, height), mipmapped: false)
        descriptor.usage = [.renderTarget, .shaderRead]
        descriptor.storageMode = .private
        func texture() throws -> MTLTexture {
            guard let result = device.makeTexture(descriptor: descriptor) else {
                throw NSError(domain: "AnaLine.CRT", code: 1,
                    userInfo: [NSLocalizedDescriptionKey: "Could not allocate phosphor history"])
            }
            return result
        }
        let newEmission = try texture(), a = try texture(), b = try texture()
        emission = newEmission; history = [a, b]; next = 0; reset()
    }

    /// Must be encoded on the same serial command queue as the emission pass.
    func encode(command: MTLCommandBuffer, target: MTLTexture, now: Double,
                settings: TVCRTBeamSettings, peak: Double) throws {
        guard let emission, history.count == 2 else { return }
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = target
        pass.colorAttachments[1].texture = history[next]
        for index in 0...1 {
            pass.colorAttachments[index].loadAction = .dontCare
            pass.colorAttachments[index].storeAction = .store
        }
        guard let encoder = command.makeRenderCommandEncoder(descriptor: pass) else {
            throw NSError(domain: "AnaLine.CRT", code: 2)
        }
        let elapsed = lastTime.map { now - $0 }
        let retention = elapsed.map { settings.retention(seconds: $0) } ?? .zero
        var uniform = SIMD4<Float>(retention.x, retention.y, retention.z, Float(peak))
        encoder.setRenderPipelineState(pipeline)
        encoder.setFragmentTexture(emission, index: 0)
        encoder.setFragmentTexture(history[1 - next], index: 1)
        encoder.setFragmentBytes(&uniform, length: 16, index: 0)
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        encoder.endEncoding()
        next = 1 - next; lastTime = now
    }
}

/// Same rotary controls as the rest of the CRT rack. The settings are shared
/// by both outputs, while their emission histories remain independent.
struct TVCRTBeamControls: View {
    let enabled: Bool
    @AppStorage("tvCRTBeamSpot") private var spot = 0.35
    @AppStorage("tvCRTPhosphorDecayMS") private var decayMS = 18.0
    @AppStorage("tvCRTConvergence") private var convergence = 0.25

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(L("Beam and phosphor response"))
                .font(.system(size: 10, weight: .medium)).foregroundStyle(.white.opacity(0.7))
            HStack(spacing: 16) {
                TVRotaryParameter(name: "Beam spot", value: Binding(
                    get: { Float(TVCRTBeamSettings(spot: spot).spot) }, set: { spot = Double($0) }),
                    range: 0...2, initial: 0.35, step: 0.05, unit: "px", digits: 2, active: enabled)
                TVRotaryParameter(name: "Corner convergence", value: Binding(
                    get: { Float(TVCRTBeamSettings(convergence: convergence).convergence) },
                    set: { convergence = Double($0) }),
                    range: 0...3, initial: 0.25, step: 0.05, unit: "px", digits: 2, active: enabled)
            }
            TVRotaryParameter(name: "Phosphor decay", value: Binding(
                get: { Float(TVCRTBeamSettings(decayMS: decayMS).decayMS) }, set: { decayMS = Double($0) }),
                range: 0...80, initial: 18, step: 1, unit: "ms", digits: 0, active: enabled)
            Text(L("Bright beams widen; focus and RGB alignment soften toward the corners."))
                .font(.system(size: 10)).foregroundStyle(.white.opacity(0.6))
            Text(L("Decay uses elapsed time, with slightly different RGB tails. Set any control to 0 to bypass that effect."))
                .font(.system(size: 10)).foregroundStyle(.white.opacity(0.6))
        }
    }
}
