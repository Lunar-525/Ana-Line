import SwiftUI
import AppKit
import MetalKit

/// Display-stage CRT simulation. Input remains the receiver's SDR signal;
/// emitted phosphor light is linear and may exceed reference white on EDR screens.
struct TVCRTDisplay: NSViewRepresentable {
    static let isAvailable = Renderer().available
    let image: NSImage
    let hdr: Bool
    let brightness: Double
    var maskPitch: Double = 9
    var maskStrength: Double = 0.8
    var scanlines: Double = 0

    func makeNSView(context: Context) -> MTKView {
        let view = DisplayView(frame: .zero, device: context.coordinator.device)
        view.colorPixelFormat = .rgba16Float
        view.colorspace = CGColorSpace(name: CGColorSpace.extendedLinearSRGB)
        (view.layer as? CAMetalLayer)?.wantsExtendedDynamicRangeContent = true
        view.clearColor = MTLClearColorMake(0, 0, 0, 1)
        view.isPaused = true
        view.enableSetNeedsDisplay = true
        view.delegate = context.coordinator
        return view
    }
    func makeCoordinator() -> Renderer { Renderer() }
    func updateNSView(_ view: MTKView, context: Context) {
        context.coordinator.update(image: image, hdr: hdr, brightness: brightness, scanlines: scanlines, maskPitch: maskPitch, maskStrength: maskStrength)
        view.needsDisplay = true
    }

    /// A paused frame must also adapt when brightness changes or the window moves.
    final class DisplayView: MTKView {
        private var headroomTimer: Timer?
        private var lastHeadroom: CGFloat = -1
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            headroomTimer?.invalidate(); headroomTimer = nil
            needsDisplay = true
            guard window != nil else { return }
            headroomTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    let value = self.window?.screen?.maximumExtendedDynamicRangeColorComponentValue ?? 1
                    if value != self.lastHeadroom {
                        self.lastHeadroom = value; self.needsDisplay = true
                    }
                }
            }
        }
        override func viewDidChangeBackingProperties() {
            super.viewDidChangeBackingProperties(); needsDisplay = true
        }
    }

    @MainActor
    final class Renderer: NSObject, MTKViewDelegate {
        let device = MTLCreateSystemDefaultDevice()
        private var queue: MTLCommandQueue?
        private var pipeline: MTLRenderPipelineState?
        private var texture: MTLTexture?
        private var previous: NSImage?
        private var hdr = true
        private var brightness = 2.0
        private var scanlines = 0.0
        private var maskPitch = 9.0
        private var maskStrength = 0.8
        private(set) var error: Error?

        override init() {
            super.init()
            guard let device else { return }
            queue = device.makeCommandQueue()
            do {
                let library = try device.makeLibrary(source: Self.shader, options: nil)
                let descriptor = MTLRenderPipelineDescriptor()
                descriptor.vertexFunction = library.makeFunction(name: "crtVertex")
                descriptor.fragmentFunction = library.makeFunction(name: "crtFragment")
                descriptor.colorAttachments[0].pixelFormat = .rgba16Float
                pipeline = try device.makeRenderPipelineState(descriptor: descriptor)
            } catch { self.error = error }
        }
        var available: Bool { pipeline != nil }
        func update(image: NSImage, hdr: Bool, brightness: Double, scanlines: Double, maskPitch: Double, maskStrength: Double) {
            self.hdr = hdr; self.brightness = brightness; self.scanlines = scanlines
            self.maskPitch = maskPitch; self.maskStrength = maskStrength
            guard previous !== image, let device,
                  let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return }
            // Normalize embedded source profiles into sRGB before GPU sRGB decoding.
            let space = CGColorSpace(name: CGColorSpace.sRGB)!
            guard let bitmap = CGContext(data: nil, width: cg.width, height: cg.height,
                bitsPerComponent: 8, bytesPerRow: cg.width * 4, space: space,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return }
            bitmap.draw(cg, in: CGRect(x: 0, y: 0, width: cg.width, height: cg.height))
            guard let normalized = bitmap.makeImage() else { return }
            do {
                texture = try MTKTextureLoader(device: device).newTexture(cgImage: normalized,
                    options: [.SRGB: true, .origin: MTKTextureLoader.Origin.topLeft])
                previous = image
            } catch { self.error = error }
        }
        func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}
        func draw(in view: MTKView) {
            guard let pipeline, let texture, let pass = view.currentRenderPassDescriptor,
                  let drawable = view.currentDrawable, let command = queue?.makeCommandBuffer(),
                  let encoder = command.makeRenderCommandEncoder(descriptor: pass) else { return }
            let headroom = view.window?.screen?.maximumExtendedDynamicRangeColorComponentValue ?? 1
            var uniforms = SIMD4<Float>(Float(view.drawableSize.width), Float(view.drawableSize.height),
                Float(Self.peak(hdr: hdr, brightness: brightness, headroom: Double(headroom))),
                Float(Self.lineCount(scanlines, sourceHeight: texture.height)))
            let pitch = Int(maskPitch.isFinite ? min(18, max(6, maskPitch.rounded())) : 9)
            var mean = Self.maskMeans[pitch - 6]
            var mask = SIMD4<Float>(Float(pitch),
                Float(maskStrength.isFinite ? min(1, max(0, maskStrength)) : 0.8), 0, 0)
            encoder.setFragmentBytes(&mean, length: MemoryLayout<SIMD4<Float>>.stride, index: 2)
            encoder.setFragmentBytes(&mask, length: MemoryLayout<SIMD4<Float>>.stride, index: 1)
            encoder.setRenderPipelineState(pipeline)
            encoder.setFragmentTexture(texture, index: 0)
            encoder.setFragmentBytes(&uniforms, length: MemoryLayout<SIMD4<Float>>.stride, index: 0)
            encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
            encoder.endEncoding()
            command.present(drawable); command.commit()
        }
        // Measure the actual pixel-sampled mask, including odd pitches. An
        // analytic continuous average would bias brightness and RGB balance.
        static let maskMeans: [SIMD4<Float>] = (6...18).map { pitch in
            var sum = SIMD3<Double>(repeating: 0)
            func edge(_ lo: Double, _ hi: Double, _ x: Double) -> Double {
                let t = min(1, max(0, (x-lo)/(hi-lo)))
                return 1-t*t*(3-2*t)
            }
            let width = Double(pitch)/3
            for y in 0..<(2*pitch) {
                for x in 0..<(2*pitch) {
                    let phase = (Double(x)+0.5)/width
                    let column = Int(floor(phase))
                    let row = (Double(y)+0.5)/Double(pitch) + Double((column/3)%2)*0.5
                    let h = edge(0.25,0.48,abs(phase-floor(phase)-0.5))
                    let v = edge(0.32,0.49,abs(row-floor(row)-0.5))
                    sum += SIMD3<Double>(repeating: 0.06)
                    sum[column%3] += 0.94*h*v
                }
            }
            let average = sum/Double(4*pitch*pitch)
            return SIMD4(Float(average.x),Float(average.y),Float(average.z),0)
        }
        static func lineCount(_ requested: Double, sourceHeight: Int) -> Double {
            guard requested.isFinite, requested > 0 else { return Double(max(1, sourceHeight)) }
            return min(1080, max(120, requested.rounded()))
        }
        static func peak(hdr: Bool, brightness: Double, headroom: Double) -> Double {
            guard hdr, brightness.isFinite, headroom.isFinite else { return 1 }
            return min(max(1, headroom), min(4, max(1, brightness)))
        }
        static let shader = """
        #include <metal_stdlib>
        using namespace metal;
        struct Vertex { float4 position [[position]]; float2 uv; };
        vertex Vertex crtVertex(uint id [[vertex_id]]) {
            float2 p = float2((id << 1) & 2, id & 2);
            return {float4(p * float2(2,-2) + float2(-1,1),0,1),p};
        }
        fragment float4 crtFragment(Vertex v [[stage_in]], texture2d<float> image [[texture(0)]],
            constant float4 &u [[buffer(0)]], constant float4 &m [[buffer(1)]], constant float4 &mean [[buffer(2)]]) {
            constexpr sampler s(coord::normalized, address::clamp_to_edge, filter::linear);
            float2 p = v.uv * 2 - 1;
            float2 uv = (p * (1 + 0.018 * dot(p,p)) + 1) * 0.5;
            if (any(uv < 0) || any(uv > 1)) return float4(0,0,0,1);
            float2 texel = 1.0 / float2(image.get_width(), image.get_height());
            float3 color = image.sample(s,uv).rgb;
            float3 glow = (image.sample(s,uv+float2(texel.x,0)).rgb
                + image.sample(s,uv-float2(texel.x,0)).rgb
                + image.sample(s,uv+float2(0,texel.y)).rgb
                + image.sample(s,uv-float2(0,texel.y)).rgb) * 0.25;
            // Fade unresolved lines using the local curved-screen pixel footprint.
            float lines = max(1.0, u.w);
            float footprint = max(fwidth(uv.y) * lines, 0.0001);
            float resolved = 1 - smoothstep(0.5, 1.0, footprint);
            float scan = 1 - resolved * 0.28 * (0.5 + 0.5*cos(uv.y*lines*6.283185));
            // RGB phosphor slots with dark matrix gaps. Pitch is in physical
            // output pixels, large enough to remain visible on Retina panels.
            float pitch = max(6.0, m.x);
            float cellWidth = pitch / 3;
            float cellHeight = cellWidth * 3;
            float x = v.position.x / cellWidth;
            uint column = uint(floor(x));
            uint stripe = column % 3;
            float horizontal = 1 - smoothstep(0.25, 0.48, abs(fract(x)-0.5));
            // Stagger adjacent RGB triads like a slot-mask television tube.
            float y = v.position.y / cellHeight + float((column / 3) % 2) * 0.5;
            float vertical = 1 - smoothstep(0.32, 0.49, abs(fract(y)-0.5));
            float3 phosphor = float3(0.06);
            phosphor[stripe] = 0.06 + 0.94 * horizontal * vertical;
            color = (color*0.94 + glow*0.06) * scan;
            color *= 1 - 0.12 * pow(clamp(dot(p,p)*0.5,0.0,1.0),2.0);
            // Lift bright phosphors while preserving black and restrained midtones.
            color *= 1 + (u.z-1)*smoothstep(0.15,0.85,max(color.r,max(color.g,color.b)));
            // Redistribute emitted light into slots instead of removing it.
            // Bound contrast BEFORE masking: clipping boosted slots would lose
            // energy and shift saturated colours when the display runs out of EDR.
            float3 available = max(float3(1), u.z / max(color,float3(0.000001)));
            float3 limit = (1 - 1/available) / max(float3(0.000001),1-mean.rgb);
            float strength = min(clamp(m.y,0.0,1.0), min(limit.r,min(limit.g,limit.b)));
            float3 mask = mix(float3(1),phosphor,strength)
                / mix(float3(1),mean.rgb,strength);
            return float4(min(color*mask,float3(u.z)),1);
        }
        """
    }
}

struct TVCRTControls: View {
    @AppStorage("tvCRTEnabled") private var enabled = false
    @AppStorage("tvCRTHDR") private var hdr = true
    @AppStorage("tvCRTBrightness") private var brightness = 2.0
    @AppStorage("tvCRTAutomaticLines") private var automaticLines = true
    @AppStorage("tvCRTScanlines") private var scanlines = 480.0
    @AppStorage("tvCRTMaskPitch") private var maskPitch = 9.0
    @AppStorage("tvCRTMaskStrength") private var maskStrength = 0.8
    @State private var showingPanel = false

    var body: some View {
        Button { showingPanel.toggle() } label: {
            HStack(spacing: 6) {
                Circle().fill(enabled ? EditingTool.tv.logoAccentColor : Color.black.opacity(0.18))
                    .frame(width: 6, height: 6)
                Text("CRT").font(.system(size: 13, weight: .medium))
            }
            .frame(maxWidth: .infinity).frame(height: 48)
            .background(Rectangle().fill(.white)
                .shadow(color: .black.opacity(0.35), radius: 5, y: 2))
        }
        .buttonStyle(ToolModeButtonStyle())
        .help(L("CRT display and HDR phosphor brightness"))
        .popover(isPresented: $showingPanel) {
            TVServicePanel(title: "CRT display") {
                HStack(spacing: 24) {
                    displaySwitch($enabled, title: "CRT display")
                    displaySwitch($hdr, title: "HDR phosphor brightness").disabled(!enabled)
                    displaySwitch($automaticLines, title: "Automatic scanlines").disabled(!enabled)
                }.frame(maxWidth: .infinity)
                HStack(spacing: 16) {
                    TVRotaryParameter(name: "Scanline count", value: Binding(
                        get: { Float(scanlines) }, set: { scanlines = Double($0.rounded()) }),
                        range: 120...1080, initial: 480, step: 1, digits: 0,
                        active: enabled && !automaticLines)
                    TVRotaryParameter(name: "Phosphor peak", value: Binding(
                        get: { Float(brightness) }, set: { brightness = Double($0) }),
                        range: 1...4, initial: 2, step: 0.1, unit: "×", digits: 1,
                        active: enabled && hdr)
                }
                HStack(spacing: 16) {
                    TVRotaryParameter(name: "Phosphor pitch", value: Binding(
                        get: { Float(maskPitch) }, set: { maskPitch = Double($0.rounded()) }),
                        range: 6...18, initial: 9, step: 1, unit: "px", digits: 0, active: enabled)
                    TVRotaryParameter(name: "Phosphor mask", value: Binding(
                        get: { Float(maskStrength) }, set: { maskStrength = Double($0) }),
                        range: 0...1, initial: 0.8, step: 0.01, digits: 0, percent: true, active: enabled)
                }
                Text(L("Automatic scanlines follow the source height. Manual range: 120–1080."))
                    .font(.system(size: 10)).foregroundStyle(.white.opacity(0.6))
                Text(L("HDR uses available display headroom. Preview only."))
                    .font(.system(size: 10)).foregroundStyle(.white.opacity(0.6))
            }
        }
    }
    private func displaySwitch(_ binding: Binding<Bool>, title: String) -> some View {
        VStack(spacing: 5) {
            TVRackSwitch(enabled: binding, label: title)
            Text(L(title)).font(.system(size: 8, weight: .medium))
                .lineLimit(2).multilineTextAlignment(.center)
        }.frame(maxWidth: .infinity)
    }
}
