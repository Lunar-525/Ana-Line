import SwiftUI
import AppKit
import MetalKit

/// Display-stage CRT simulation. The receiver still produces an SDR frame;
/// the display layer resamples it onto a simulated phosphor grid, emits one
/// primary per dot, and lets the display's EDR headroom carry the peaks.
struct TVCRTDisplay: NSViewRepresentable {
    static let isAvailable = Renderer().available
    @AppStorage("tvCRTAutoBrightness") private var automaticBrightness = true
    @AppStorage("tvCRTBeamSpot") private var beamSpot = 0.35
    @AppStorage("tvCRTPhosphorDecayMS") private var phosphorDecayMS = 18.0
    @AppStorage("tvCRTConvergence") private var convergence = 0.25
    @AppStorage("tvCRTGlassScatter") private var glassScatter = 0.12
    @AppStorage("tvCRTGlassHalo") private var glassHalo = 0.18
    @AppStorage("tvCRTGlassRadius") private var glassRadius = 12.0
    @AppStorage("tvCRTCameraReflection") private var cameraReflection = false
    @AppStorage("tvCRTCameraReflectionStrength") private var reflectionStrength = 0.08
    @AppStorage("tvCRTCurvature") private var curvature = 0.5
    @AppStorage("tvCRTPixelPerfectStripes") private var pixelPerfectStripes = true
    static let maximumCurvature = 0.036
    static func curvatureCoefficient(_ value: Double) -> Double {
        let v = value.isFinite ? min(1, max(0, value)) : 0.5
        return v * maximumCurvature
    }
    let image: NSImage
    let hdr: Bool
    let brightness: Double
    var crtLines: Double = 240
    var maskStrength: Double = 0.8
    var scanlines: Double = 0
    var maxLines: Double = 576
    var maskType: Int = TVCRTMaskType.apertureGrille.rawValue

    var historyID: UInt64 = 0
    var onBrightness: ((TVCRTBrightnessReading) -> Void)? = nil
    var onDrawableSize: ((CGSize) -> Void)? = nil

    func makeNSView(context: Context) -> MTKView {
        let view = DisplayView(frame: .zero, device: context.coordinator.device)
        view.colorPixelFormat = .rgba16Float
        view.colorspace = CGColorSpace(name: CGColorSpace.extendedLinearSRGB)
        (view.layer as? CAMetalLayer)?.wantsExtendedDynamicRangeContent = true
        view.clearColor = MTLClearColorMake(0, 0, 0, 1)
        view.isPaused = true
        view.enableSetNeedsDisplay = true
        context.coordinator.onBrightness = onBrightness
        context.coordinator.onDrawableSize = onDrawableSize
        view.delegate = context.coordinator
        return view
    }
    func makeCoordinator() -> Renderer { Renderer() }
    func updateNSView(_ view: MTKView, context: Context) {
        context.coordinator.onBrightness = onBrightness
        context.coordinator.onDrawableSize = onDrawableSize
        context.coordinator.update(image: image, hdr: hdr, brightness: brightness, automaticBrightness: automaticBrightness,
            scanlines: scanlines, crtLines: crtLines, maskStrength: maskStrength,
            maxLines: maxLines, maskType: maskType,
            curvature: Self.curvatureCoefficient(curvature),
            pixelPerfectStripes: pixelPerfectStripes,
            beam: TVCRTBeamSettings(spot: beamSpot, decayMS: phosphorDecayMS, convergence: convergence),
            historyID: historyID,
            glass: TVCRTGlassSettings(scatter: glassScatter, halo: glassHalo, radius: glassRadius,
                reflection: reflectionStrength, curvature: Self.curvatureCoefficient(curvature)),
            cameraEnabled: cameraReflection)
        (view as? DisplayView)?.refreshCameraDemand()
        view.preferredFramesPerSecond = 60
        view.isPaused = !context.coordinator.needsAnimation
        view.enableSetNeedsDisplay = view.isPaused
        view.needsDisplay = true
    }

    static func dismantleNSView(_ view: MTKView, coordinator: Renderer) {
        coordinator.stopCamera()
        (view as? DisplayView)?.shutdown()
        view.isPaused = true
    }

    /// A paused frame must also adapt when brightness changes or the window moves.
    final class DisplayView: MTKView {
        private var headroomTimer: Timer?
        private var observers: [NSObjectProtocol] = []
        func shutdown() {
            headroomTimer?.invalidate(); headroomTimer = nil
            for observer in observers { NotificationCenter.default.removeObserver(observer) }
            observers = []
        }
        func refreshCameraDemand() {
            (delegate as? Renderer)?.setCameraVisible(window?.isVisible == true && window?.isMiniaturized == false
                && window?.occlusionState.contains(.visible) == true && !isHiddenOrHasHiddenAncestor)
        }
        private var lastHeadroom: CGFloat = -1
        private var lastPotential: CGFloat = -1
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            shutdown(); refreshCameraDemand()
            (delegate as? Renderer)?.resetHistory()
            isPaused = true; enableSetNeedsDisplay = true
            needsDisplay = true
            guard let window else { return }
            for name in [NSWindow.didChangeOcclusionStateNotification, NSWindow.didMiniaturizeNotification, NSWindow.didDeminiaturizeNotification] {
                observers.append(NotificationCenter.default.addObserver(forName: name, object: window, queue: .main) { [weak self] _ in
                    Task { @MainActor [weak self] in self?.refreshCameraDemand(); self?.needsDisplay = true }
                })
            }
            observers.append(NotificationCenter.default.addObserver(forName: .crtCameraFrameReady, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor [weak self] in self?.needsDisplay = true }
            })
            headroomTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    self.refreshCameraDemand()
                    if (self.delegate as? Renderer)?.cameraRequested == true { self.needsDisplay = true }
                    let value = self.window?.screen?.maximumExtendedDynamicRangeColorComponentValue ?? 1
                    let potential = self.window?.screen?.maximumPotentialExtendedDynamicRangeColorComponentValue ?? 1
                    if value != self.lastHeadroom || potential != self.lastPotential {
                        self.lastPotential = potential
                        self.lastHeadroom = value; self.needsDisplay = true
                    }
                }
            }
            if let headroomTimer { RunLoop.main.add(headroomTimer, forMode: .common) }
        }
        override func viewDidChangeBackingProperties() {
            super.viewDidChangeBackingProperties(); needsDisplay = true
        }
    }

    @MainActor
    final class Renderer: NSObject, MTKViewDelegate {
        let device = MTLCreateSystemDefaultDevice()
        var onBrightness: ((TVCRTBrightnessReading) -> Void)?
        private var lastReading: TVCRTBrightnessReading?
        var onDrawableSize: ((CGSize) -> Void)?
        private var reportedSize: CGSize = .zero
        private var queue: MTLCommandQueue?
        private var pipeline: MTLRenderPipelineState?
        private var phosphorHistory: TVCRTPhosphorHistory?
        private var glassRenderer: TVCRTGlassRenderer?
        private var glassSettings = TVCRTGlassSettings()
        private var cameraEnabled = false
        private var cameraVisible = false
        private let cameraConsumer = UUID()
        var cameraRequested: Bool { cameraEnabled && cameraVisible && glassSettings.reflection > 0 }
        func setCameraVisible(_ visible: Bool) {
            cameraVisible = visible
            TVCRTCameraReflection.shared.setConsumer(cameraConsumer, active: cameraRequested)
            if !cameraRequested { glassRenderer?.clearCamera() }
        }
        func stopCamera() {
            cameraVisible = false
            TVCRTCameraReflection.shared.setConsumer(cameraConsumer, active: false)
            glassRenderer?.clearCamera()
        }
        private var beam = TVCRTBeamSettings()
        private var historyID: UInt64 = 0
        private var settleUntil = 0.0
        private var waitingForNewFrame = false
        var needsAnimation: Bool { beam.decayMS > 0 && ProcessInfo.processInfo.systemUptime < settleUntil }
        func resetHistory() { phosphorHistory?.reset() }

        private var texture: MTLTexture?
        private var previous: NSImage?
        private var hdr = true
        private var brightness = 2.0
        private var automaticBrightness = true
        private var scanlines = 0.0
        private var crtLines = 240.0
        private var maskStrength = 0.8
        private var maxLines = 576.0
        private var maskType = TVCRTMaskType.apertureGrille.rawValue
        private var curvature = 0.018
        private var pixelPerfectStripes = true
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
                phosphorHistory = try TVCRTPhosphorHistory(device: device, library: library)
                glassRenderer = try TVCRTGlassRenderer(device: device, library: library)
            } catch { self.error = error }
        }
        var available: Bool { pipeline != nil }
        func update(image: NSImage, hdr: Bool, brightness: Double, automaticBrightness: Bool, scanlines: Double,
                    crtLines: Double, maskStrength: Double, maxLines: Double, maskType: Int,
                    curvature: Double = 0.018, pixelPerfectStripes: Bool = true,
                    beam: TVCRTBeamSettings = TVCRTBeamSettings(), historyID: UInt64 = 0,
                    glass: TVCRTGlassSettings = TVCRTGlassSettings(), cameraEnabled: Bool = false) {
            self.glassSettings = glass; self.cameraEnabled = cameraEnabled
            if !glass.hasDiffusion && !cameraEnabled { glassRenderer?.release() }
            if self.historyID != historyID { waitingForNewFrame = previous === image }
            if waitingForNewFrame, previous !== image { waitingForNewFrame = false; resetHistory() }
            let changed = self.hdr != hdr || self.brightness != brightness || self.automaticBrightness != automaticBrightness
                || self.scanlines != scanlines || self.crtLines != crtLines || self.maskStrength != maskStrength
                || self.maxLines != maxLines || self.maskType != maskType || self.curvature != curvature
                || self.pixelPerfectStripes != pixelPerfectStripes
                || self.beam != beam || self.historyID != historyID
            if changed { resetHistory() }
            if changed || previous !== image {
                settleUntil = ProcessInfo.processInfo.systemUptime + beam.decayMS / 1000 * 8
            }
            self.beam = beam; self.historyID = historyID
            if beam.decayMS == 0 { phosphorHistory?.release() }
            self.automaticBrightness = automaticBrightness
            self.hdr = hdr; self.brightness = brightness; self.scanlines = scanlines
            self.crtLines = crtLines; self.maskStrength = maskStrength
            self.maxLines = maxLines; self.maskType = maskType; self.curvature = curvature
            self.pixelPerfectStripes = pixelPerfectStripes
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
                // Mipmaps let each phosphor dot average the source area it
                // covers instead of point-sampling a moving video frame.
                texture = try MTKTextureLoader(device: device).newTexture(cgImage: normalized,
                    options: [.SRGB: true, .origin: MTKTextureLoader.Origin.topLeft,
                              .generateMipmaps: true])
                if previous?.size != image.size { resetHistory() }
                previous = image
            } catch { self.error = error }
        }
        func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {
            reportSize(size)
        }
        private func reportSize(_ size: CGSize) {
            guard size != reportedSize else { return }
            reportedSize = size
            let callback = onDrawableSize
            DispatchQueue.main.async { callback?(size) }
        }
        func draw(in view: MTKView) {
            reportSize(view.drawableSize)
            guard let pipeline, let texture, let pass = view.currentRenderPassDescriptor,
                  let drawable = view.currentDrawable, let command = queue?.makeCommandBuffer() else { return }
            let aspect = Double(view.drawableSize.width / max(1, view.drawableSize.height))
            let displayLimit = Self.displayLineLimit(maxLines: maxLines,
                drawableHeight: Double(view.drawableSize.height))
            let requestedRows = Self.crtLineCount(crtLines, maximum: Double(displayLimit))
            let pointToPoint = TVCRTPixelPerfect.make(drawableSize: view.drawableSize,
                requestedRows: requestedRows, maximumRows: displayLimit, aspect: aspect,
                maskType: maskType, enabled: pixelPerfectStripes)
            var useGlass = false
            if pointToPoint == nil, (glassSettings.hasDiffusion || cameraEnabled), let glassRenderer {
                do { try glassRenderer.prepare(width: drawable.texture.width, height: drawable.texture.height); useGlass = true }
                catch { self.error = error }
            }
            let opticalTarget = useGlass ? (glassRenderer?.scene ?? drawable.texture) : drawable.texture
            var useHistory = false
            var spatialPass = pass
            if useGlass {
                spatialPass = MTLRenderPassDescriptor()
                spatialPass.colorAttachments[0].texture = opticalTarget
                spatialPass.colorAttachments[0].loadAction = .clear
                spatialPass.colorAttachments[0].clearColor = view.clearColor
                spatialPass.colorAttachments[0].storeAction = .store
            }
            if beam.decayMS > 0, let phosphorHistory {
                do {
                    try phosphorHistory.prepare(width: drawable.texture.width, height: drawable.texture.height)
                    useHistory = true
                    spatialPass = MTLRenderPassDescriptor()
                    spatialPass.colorAttachments[0].texture = phosphorHistory.emission
                    spatialPass.colorAttachments[0].loadAction = .clear
                    spatialPass.colorAttachments[0].clearColor = view.clearColor
                    spatialPass.colorAttachments[0].storeAction = .store
                } catch { self.error = error }
            }
            guard let encoder = command.makeRenderCommandEncoder(descriptor: spatialPass) else { return }
            let headroom = view.window?.screen?.maximumExtendedDynamicRangeColorComponentValue ?? 1
            let potential = view.window?.screen?.maximumPotentialExtendedDynamicRangeColorComponentValue ?? 1
            let reading = TVCRTBrightnessReading.make(hdr: hdr, automatic: automaticBrightness,
                brightness: brightness, headroom: Double(headroom), potential: Double(potential))
            let peak = reading.output
            if reading != lastReading {
                if reading.output != lastReading?.output { resetHistory() }
                lastReading = reading
                let callback = onBrightness
                DispatchQueue.main.async { callback?(reading) }
            }
            let rows = pointToPoint?.rows ?? requestedRows
            let scanlineCount = pointToPoint.map { Double($0.rows) } ?? Self.lineCount(scanlines, crtLines: crtLines,
                maximum: Double(displayLimit))
            let grid = Self.dotGrid(lines: rows, aspect: aspect)
            let triads = pointToPoint?.triads ?? grid.triads
            let maskStyle = TVCRTMaskStyle.make(type: maskType, mask: maskStrength)
            var uniforms = SIMD4<Float>(Float(view.drawableSize.width), Float(view.drawableSize.height),
                Float(peak), Float(scanlineCount))
            var phosphor = SIMD4<Float>(Float(triads), Float(rows),
                Float(maskStyle.fillH), Float(maskStyle.fillV))
            var style = SIMD4<Float>(Float(maskStyle.type.rawValue), Float(maskStyle.radius),
                Float(maskStyle.meanFill), Float(maskStyle.stagger))
            var beamUniform = beam.spatialUniform
            let activeCurvature = pointToPoint == nil ? curvature : 0
            var optics = SIMD4<Float>(Float(activeCurvature), pointToPoint == nil ? 0 : 1, 0, 0)
            let layout = pointToPoint?.rect ?? CGRect(x: 0, y: 0, width: 1, height: 1)
            var layoutUniform = SIMD4<Float>(Float(layout.minX), Float(layout.minY),
                Float(layout.width), Float(layout.height))
            encoder.setFragmentBytes(&beamUniform, length: 16, index: 3)
            encoder.setFragmentBytes(&optics, length: 16, index: 4)
            encoder.setFragmentBytes(&layoutUniform, length: 16, index: 5)
            encoder.setFragmentBytes(&phosphor, length: MemoryLayout<SIMD4<Float>>.stride, index: 1)
            encoder.setFragmentBytes(&style, length: MemoryLayout<SIMD4<Float>>.stride, index: 2)
            encoder.setRenderPipelineState(pipeline)
            encoder.setFragmentTexture(texture, index: 0)
            encoder.setFragmentBytes(&uniforms, length: MemoryLayout<SIMD4<Float>>.stride, index: 0)
            encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
            encoder.endEncoding()
            if useHistory {
                if waitingForNewFrame { resetHistory() }
                do {
                    try phosphorHistory?.encode(command: command, target: opticalTarget,
                        now: ProcessInfo.processInfo.systemUptime, settings: beam, peak: peak)
                } catch { self.error = error; resetHistory(); return }
            }
            if useGlass {
                do {
                    try glassRenderer?.encode(command: command, target: drawable.texture, settings: glassSettings,
                        peak: peak, cameraFrame: cameraRequested ? TVCRTCameraReflection.shared.latestFrame : nil)
                } catch { self.error = error; return }
            }
            command.present(drawable); command.commit()
            if !needsAnimation { view.isPaused = true; view.enableSetNeedsDisplay = true }
        }

        struct DotGrid {
            let triads: Int
            let dots: Int
            let rows: Int
        }

        /// One simulated pixel is one RGB triplet, so the horizontal dot count
        /// follows the displayed aspect ratio and the chosen line count.
        static func dotGrid(lines: Int, aspect: Double) -> DotGrid {
            let rows = min(1080, max(120, lines))
            let ratio = aspect.isFinite && aspect > 0 ? aspect : 4.0 / 3.0
            let triads = max(1, Int((Double(rows) * ratio).rounded()))
            return DotGrid(triads: triads, dots: triads * 3, rows: rows)
        }

        static func crtLineCount(_ requested: Double, maximum: Double = 1080) -> Int {
            let cap = min(1080, max(120, Int(maximum.isFinite ? maximum : 1080)))
            guard requested.isFinite, requested > 0 else { return min(cap, 240) }
            return min(cap, max(120, Int(requested.rounded())))
        }

        /// Automatic scanlines follow the simulated raster. Manual scanlines
        /// remain independent, as they are on a real tube.
        static func lineCount(_ requested: Double, crtLines: Double,
                              maximum: Double = 1080) -> Double {
            let cap = min(1080, max(120, maximum.isFinite ? maximum : 1080))
            guard requested.isFinite, requested > 0 else {
                return Double(crtLineCount(crtLines, maximum: cap))
            }
            return min(cap, max(120, requested.rounded()))
        }

        /// The current broadcast standard provides the visible line ceiling.
        /// The drawable height tightens it further when the window is small.
        static func displayLineLimit(maxLines: Double, drawableHeight: Double) -> Int {
            let standard = maxLines.isFinite && maxLines > 0 ? maxLines : 576
            let cap = min(1080, max(120, Int(standard.rounded())))
            let pixels = drawableHeight.isFinite && drawableHeight > 0 ? drawableHeight : 1080
            return min(cap, max(120, Int(pixels.rounded(.down))))
        }

        nonisolated static func peak(hdr: Bool, brightness: Double, headroom: Double) -> Double {
            guard hdr, brightness.isFinite, headroom.isFinite else { return 1 }
            return min(max(1, headroom), max(1, brightness))
        }

        static let shader = """
        #include <metal_stdlib>
        using namespace metal;
        struct Vertex { float4 position [[position]]; float2 uv; };
        vertex Vertex crtVertex(uint id [[vertex_id]]) {
            float2 p = float2((id << 1) & 2, id & 2);
            return {float4(p * float2(2,-2) + float2(-1,1),0,1),p};
        }

        static inline float phosphorChannel(float3 c, uint i) {
            return i == 0 ? c.x : (i == 1 ? c.y : c.z);
        }

        static inline float3 phosphorPrimary(uint i, float value) {
            float3 result = float3(0);
            if (i == 0) result.x = value;
            else if (i == 1) result.y = value;
            else result.z = value;
            return result;
        }

        // Average the source over the footprint of one phosphor cell. The
        // mip level pre-filters the narrow dimension; four taps cover the cell.
        static inline float3 cellAverage(texture2d<float> image, sampler s, float2 uv,
                                         float2 cellUV, float lod) {
            float2 o = cellUV * 0.25;
            float3 c = image.sample(s, uv + float2(-o.x,-o.y), level(lod)).rgb;
            c += image.sample(s, uv + float2( o.x,-o.y), level(lod)).rgb;
            c += image.sample(s, uv + float2(-o.x, o.y), level(lod)).rgb;
            c += image.sample(s, uv + float2( o.x, o.y), level(lod)).rgb;
            return c * 0.25;
        }

        // The phosphor screen stays fixed. Beam focus and RGB landing errors
        // change which source light excites a dot, before mask emission.
        static inline float3 beamSample(texture2d<float> image, sampler s, float2 uv,
                                        float2 cellUV, float lod, float4 beam) {
            if (beam.x <= 0 && beam.y <= 0) return cellAverage(image, s, uv, cellUV, lod);
            float2 texels = float2(image.get_width(), image.get_height());
            float2 p = uv * 2.0 - 1.0;
            float edge = clamp(dot(p,p) * 0.5, 0.0, 1.0);
            // A local average lets the bright beam widen into nearby dark pixels.
            float3 centre = image.sample(s, uv, level(max(lod, 1.0))).rgb;
            float light = clamp(dot(centre, float3(0.2126,0.7152,0.0722)), 0.0, 1.0);
            // Bright beams widen; off-axis focus is a little softer.
            float sigma = beam.x * (0.3 + 1.2 * sqrt(light)) * (1.0 + 0.5 * edge);
            float2 footprint = sqrt(cellUV * cellUV + pow(4.0 * sigma / texels, float2(2)));
            float focusLOD = max(lod, log2(max(1.0, 2.0 * sigma)));
            if (beam.y <= 0) return cellAverage(image, s, uv, footprint, focusLOD);
            float2 landing = p * edge * beam.y / texels;
            float r = cellAverage(image, s, uv + landing, footprint, focusLOD).r;
            float g = cellAverage(image, s, uv, footprint, focusLOD).g;
            float b = cellAverage(image, s, uv - landing, footprint, focusLOD).b;
            return float3(r,g,b);
        }

        static inline float phosphorAperture(float distance, float fill, float edge) {
            if (fill >= 0.999) return 1.0;
            float halfWidth = 0.5 * fill;
            return 1.0 - smoothstep(halfWidth - edge, halfWidth + edge, distance);
        }

        fragment float4 crtFragment(Vertex v [[stage_in]], texture2d<float> image [[texture(0)]],
            constant float4 &u [[buffer(0)]], constant float4 &m [[buffer(1)]],
            constant float4 &cfg [[buffer(2)]], constant float4 &beam [[buffer(3)]],
            constant float4 &optics [[buffer(4)]], constant float4 &layout [[buffer(5)]]) {
            constexpr sampler s(coord::normalized, address::clamp_to_edge,
                filter::linear, mip_filter::linear);
            float2 screenUV = v.uv;
            if (optics.y > 0.5) {
                if (any(screenUV < layout.xy) || any(screenUV > layout.xy + layout.zw)) {
                    return float4(0,0,0,1);
                }
                screenUV = (screenUV - layout.xy) / layout.zw;
            }
            float2 p = screenUV * 2 - 1;
            float2 uv = (p * (1 + optics.x * dot(p,p)) + 1) * 0.5;
            if (any(uv < 0) || any(uv > 1)) return float4(0,0,0,1);

            // m.x/m.y describe the simulated pixel (RGB triad) grid.
            float2 pixelUV = float2(1.0 / max(1.0, m.x), 1.0 / max(1.0, m.y));
            float2 cellCoord = min(uv, float2(0.999999)) / pixelUV;
            float2 cell = floor(cellCoord);
            float2 local = fract(cellCoord);
            float2 pixelCenter = (cell + 0.5) * pixelUV;
            uint type = uint(cfg.x + 0.5);

            float2 texels = float2(float(image.get_width()), float(image.get_height()));
            float2 cellTexels = pixelUV * texels;
            float lod = max(0.0, log2(max(1.0, min(cellTexels.x, cellTexels.y))));

            uint primary = 0;
            float aperture = 0;
            float2 fw = fwidth(cellCoord);
            float ex = max(0.02, 0.5 * fw.x);
            float ey = max(0.02, 0.5 * fw.y);

            if (type == 1 || type == 4) {
                // RGB three-colouring of a triangular lattice, across cell
                // boundaries. Nearest centres use a staggered row spacing.
                // sqrt(3 * sqrt(3)/2): three dots per unit cell area.
                float2 point = cellCoord * 1.611854898;
                const float dy = 0.866025404;
                int baseRow = int(floor(point.y / dy));
                float best = 1e9;
                float2 delta = float2(0);
                for (int offset = -1; offset <= 1; ++offset) {
                    int row = baseRow + offset;
                    float shift = (row & 1) ? 0.5 : 0.0;
                    int col = int(round(point.x - shift));
                    float2 q = point - float2(float(col) + shift, float(row) * dy);
                    float d = dot(q,q);
                    if (d < best) {
                        best = d; delta = q;
                        primary = uint(((col + 2 * row) % 3 + 3) % 3);
                    }
                }
                // Keep the smoothed aperture inside its Voronoi region.
                // Sample at the physical dot centre, so a dot crossing the
                // old square-cell boundary cannot acquire a colour seam.
                pixelCenter = clamp((point - delta) / 1.611854898 * pixelUV, float2(0), float2(1));
                float edge = min(0.5 - cfg.y, max(0.02, 0.5 * max(fwidth(point.x), fwidth(point.y))));
                float distance = sqrt(best);
                if (type == 4) {
                    float2 q = abs(delta);
                    distance = max(q.x, dot(q, float2(0.5, dy)));
                }
                aperture = 1.0 - smoothstep(max(0.0, cfg.y - edge), cfg.y + edge, distance);
            } else if (type == 5) {
                // Horizontal stripe triplets; no vertical colour partition.
                float slot = local.y * 3.0;
                primary = uint(floor(slot));
                float edge = min(0.5 * (1.0 - m.w), max(0.06, ey * 3.0));
                aperture = phosphorAperture(abs(fract(slot) - 0.5), m.w, edge);
            } else {
                float x = local.x;
                if (type == 2) {
                    // Slot mask: alternate rows shift by half a slot.
                    x = fract(x + cfg.w * float(uint(cell.y) % 2));
                }
                float slot = x * 3.0;
                primary = uint(floor(slot));
                float sx = fract(slot);
                float eh = min(0.5 * (1.0 - m.z), max(0.06, ex));
                float focus = phosphorAperture(abs(sx - 0.5), m.z, eh);
                float vertical = 1.0;
                if (type == 2 || type == 3) {
                    float ev = min(0.5 * (1.0 - m.w), max(0.06, ey));
                    vertical = phosphorAperture(abs(local.y - 0.5), m.w, ev);
                }
                aperture = focus * vertical;
            }

            // Damping wires are the visual signature of a Trinitron grille.
            if (type == 0) {
                float d = min(abs(uv.y - 1.0/3.0), abs(uv.y - 2.0/3.0));
                float halfWidth = max(fwidth(uv.y) * 0.75, 0.0008);
                float line = 1.0 - smoothstep(0.0, halfWidth, d);
                aperture *= 1.0 - 0.7 * line;
            }

            float3 I = beamSample(image, s, pixelCenter, pixelUV, lod, beam);
            float value = phosphorChannel(I, primary);
            // Same-primary halo from the four neighbouring simulated pixels.
            float3 g0 = image.sample(s, pixelCenter + float2( pixelUV.x, 0.0), level(lod)).rgb;
            float3 g1 = image.sample(s, pixelCenter + float2(-pixelUV.x, 0.0), level(lod)).rgb;
            float3 g2 = image.sample(s, pixelCenter + float2(0.0,  pixelUV.y), level(lod)).rgb;
            float3 g3 = image.sample(s, pixelCenter + float2(0.0, -pixelUV.y), level(lod)).rgb;
            float halo = (phosphorChannel(g0,primary) + phosphorChannel(g1,primary)
                + phosphorChannel(g2,primary) + phosphorChannel(g3,primary)) * 0.25;
            value = value * 0.94 + halo * 0.06;

            float lines = max(1.0, u.w);
            float footprint = max(fwidth(uv.y) * lines, 0.0001);
            float resolvedScan = 1.0 - smoothstep(0.5, 1.0, footprint);
            float light = clamp(dot(I, float3(0.2126,0.7152,0.0722)), 0.0, 1.0);
            float darkBand = 0.5 + 0.5*cos(uv.y*lines*6.283185);
            // A brighter/wider beam fills more of the gap between scanlines.
            darkBand = pow(darkBand, 1.0 + beam.x * (0.3 + 2.0 * sqrt(light)));
            float scan = 1.0 - resolvedScan * 0.28 * darkBand;
            float vignette = 1.0 - 0.12 * pow(clamp(dot(p,p)*0.5,0.0,1.0),2.0);

            // A phosphor dot smaller than a screen pixel cannot be resolved.
            // Fall back to the average colour of its triad, whose integrated
            // light is `cfg.z` (the measured aperture fraction).
            float cellPx = min(u.x * pixelUV.x, u.y * pixelUV.y);
            float dotPx = cellPx / 3.0;
            if (type == 1 || type == 4) dotPx = cellPx * max(0.001, 2.0 * cfg.y) / 1.611854898;
            float resolved = smoothstep(0.6, 1.6, dotPx);
            float3 average = beam.x > 0 || beam.y > 0 ? beamSample(image, s, uv, float2(0), 0, beam)
                : image.sample(s, uv, level(0.0)).rgb;
            float3 fallback = average * cfg.z * u.z;
            float3 emission = phosphorPrimary(primary, value * aperture * u.z);
            float3 color = mix(fallback, emission, resolved);
            color *= scan * vignette;
            return float4(min(color, float3(u.z)), 1);
        }

        static inline float3 extractGlassHighlight(float3 c, float peak) {
            float drive = max(c.r, max(c.g,c.b)) / max(1.0, peak);
            return c * smoothstep(0.35, 0.9, drive);
        }
        fragment float4 crtGlassHighlights(Vertex v [[stage_in]], texture2d<float> source [[texture(0)]],
            constant float &peak [[buffer(0)]]) {
            constexpr sampler s(coord::normalized, address::clamp_to_edge, filter::linear);
            float2 d = 0.5 / float2(source.get_width(), source.get_height());
            float3 c = extractGlassHighlight(source.sample(s, v.uv + float2(-d.x,-d.y)).rgb, peak);
            c += extractGlassHighlight(source.sample(s, v.uv + float2(d.x,-d.y)).rgb, peak);
            c += extractGlassHighlight(source.sample(s, v.uv + float2(-d.x,d.y)).rgb, peak);
            c += extractGlassHighlight(source.sample(s, v.uv + float2(d.x,d.y)).rgb, peak);
            return float4(c * 0.25, 1);
        }
        fragment float4 crtGlassComposite(Vertex v [[stage_in]], texture2d<float> source [[texture(0)]],
            texture2d<float> highlights [[texture(1)]], texture2d<float> camera [[texture(2)]],
            constant float4 &u [[buffer(0)]], constant float4 &reflection [[buffer(1)]]) {
            constexpr sampler s(coord::normalized, address::clamp_to_edge, filter::linear, mip_filter::linear);
            float2 p = v.uv * 2.0 - 1.0;
            float curve = reflection.z;
            float2 face = p * (1.0 + curve * dot(p,p));
            if (any(abs(face) > 1.0)) return float4(0,0,0,1);
            float3 sharp = source.sample(s, v.uv, level(0)).rgb;
            float3 colour = sharp;
            float scale = float(source.get_height()) / 576.0;
            float wideLOD = log2(max(1.0, u.z * scale));
            if (u.x > 0) {
                float3 narrow = source.sample(s, v.uv, level(log2(max(1.0, 2.0 * scale)))).rgb;
                float3 wide = source.sample(s, v.uv, level(wideLOD)).rgb;
                colour = mix(sharp, narrow * 0.7 + wide * 0.3, u.x);
            }
            if (u.y > 0) {
                float3 glow = highlights.sample(s, v.uv, level(max(0.0, wideLOD - 1.0))).rgb * 0.8;
                glow += highlights.sample(s, v.uv, level(max(0.0, wideLOD + 0.5))).rgb * 0.2;
                colour += glow * u.y;
            }
            if (reflection.y > 0 && reflection.x > 0) {
                float edge = clamp(dot(p,p) * 0.5, 0.0, 1.0);
                // Keep the camera reflection on the same curved face. 0.08 was
                // the old fixed reflection curvature at the old 0.018 face.
                float2 coord = (p * (1.0 + curve * (0.08 / 0.018) * dot(p,p)) + 1.0) * 0.5;
                float displayAspect = float(source.get_width()) / float(source.get_height());
                float cameraAspect = float(camera.get_width()) / float(camera.get_height());
                if (cameraAspect > displayAspect) coord.x = (coord.x - 0.5) * displayAspect / cameraAspect + 0.5;
                else coord.y = (coord.y - 0.5) * cameraAspect / displayAspect + 0.5;
                coord.x = 1.0 - coord.x;
                float2 d = 3.0 / float2(camera.get_width(), camera.get_height());
                float3 reflected = camera.sample(s, coord, level(0)).rgb * 0.4;
                reflected += camera.sample(s, coord + float2(d.x,0), level(0)).rgb * 0.15;
                reflected += camera.sample(s, coord - float2(d.x,0), level(0)).rgb * 0.15;
                reflected += camera.sample(s, coord + float2(0,d.y), level(0)).rgb * 0.15;
                reflected += camera.sample(s, coord - float2(0,d.y), level(0)).rgb * 0.15;
                float drive = max(sharp.r, max(sharp.g,sharp.b)) / max(1.0, u.w);
                float amount = reflection.x * (0.45 + 0.55 * edge) / (1.0 + 2.5 * drive);
                // Reflected room light stays in SDR; it is never scaled by EDR.
                colour += clamp(reflected, float3(0), float3(1)) * amount;
            }
            return float4(clamp(colour, float3(0), float3(u.w)),1);
        }

        struct PhosphorOutput { float4 display [[color(0)]]; float4 history [[color(1)]]; };
        fragment PhosphorOutput crtPersistence(Vertex v [[stage_in]],
            texture2d<float> current [[texture(0)]], texture2d<float> previous [[texture(1)]],
            constant float4 &u [[buffer(0)]]) {
            uint2 pixel = min(uint2(v.position.xy), uint2(current.get_width()-1, current.get_height()-1));
            float3 light = current.read(pixel).rgb;
            // Skip uninitialised history on the first draw or after a reset.
            if (any(u.xyz > 0)) light = max(light, previous.read(pixel).rgb * u.xyz);
            float4 result = float4(clamp(light, float3(0), float3(u.w)), 1);
            return { result, result };
        }
        """
    }
}

struct TVCRTBrightnessReading: Equatable {
    let requested: Double
    let output: Double
    let available: Double
    let potential: Double

    static func make(hdr: Bool, automatic: Bool, brightness: Double,
                     headroom: Double, potential: Double) -> Self {
        let available = headroom.isFinite ? max(1, headroom) : 1
        let ceiling = potential.isFinite ? max(available, max(1, potential)) : available
        let request = automatic ? available : min(ceiling, brightness.isFinite ? max(1, brightness) : 1)
        return Self(requested: request,
            output: TVCRTDisplay.Renderer.peak(hdr: hdr, brightness: request, headroom: available),
            available: available, potential: ceiling)
    }
}

struct TVCRTControls: View {
    @ObservedObject var state: TVPreviewState
    @AppStorage("tvCRTAutoBrightness") private var automaticBrightness = true
    @AppStorage("tvCRTEnabled") private var enabled = false
    @AppStorage("tvCRTHDR") private var hdr = true
    @AppStorage("tvCRTBrightness") private var brightness = 2.0
    @AppStorage("tvCRTAutomaticLines") private var automaticLines = true
    @AppStorage("tvCRTScanlines") private var scanlines = 480.0
    @AppStorage("tvCRTLines") private var crtLines = 240.0
    @AppStorage("tvCRTMaskStrength") private var maskStrength = 0.8
    @AppStorage("tvCRTMaskType") private var maskType = TVCRTMaskType.apertureGrille.rawValue
    @AppStorage("tvCRTCurvature") private var curvature = 0.5
    @AppStorage("tvCRTPixelPerfectStripes") private var pixelPerfect = true
    @State private var showingPanel = false
    var maxLines: Double = 576

    private var lineLimit: Float {
        Float(min(1080, max(120, maxLines.isFinite ? maxLines : 576)))
    }
    private var lineLimitDouble: Double { Double(lineLimit) }
    private var pointToPointActive: Bool { pixelPerfect && TVCRTPixelPerfect.isStripe(maskType) }
    private func clampLines() {
        if crtLines > lineLimitDouble { crtLines = lineLimitDouble }
        if scanlines > lineLimitDouble { scanlines = lineLimitDouble }
    }

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
        .onAppear { clampLines() }
        .onChange(of: maxLines) { _ in clampLines() }
        .popover(isPresented: $showingPanel) {
            ScrollView {
            TVServicePanel(title: "CRT display") {
                HStack(spacing: 24) {
                    displaySwitch($enabled, title: "CRT display")
                    displaySwitch($hdr, title: "HDR phosphor brightness").disabled(!enabled)
                    displaySwitch($automaticBrightness, title: "Automatic XDR brightness").disabled(!enabled || !hdr)
                    displaySwitch($automaticLines, title: "Automatic scanlines").disabled(!enabled)
                }.frame(maxWidth: .infinity)
                if enabled, let reading = state.crtBrightness {
                    Text(String(format: L("Requested %.1f× · Output ceiling %.1f× · Available %.1f× · Potential %.1f×"),
                        reading.requested, reading.output, reading.available, reading.potential))
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(.white.opacity(0.7))
                } else {
                    Text(L("Brightness readings appear while the CRT preview is rendering."))
                        .font(.system(size: 10)).foregroundStyle(.white.opacity(0.7))
                }
                HStack(spacing: 24) {
                    displaySwitch($pixelPerfect, title: "Pixel-perfect stripes").disabled(!enabled)
                }.frame(maxWidth: .infinity)
                Text(L("Stripe masks use integer subpixel scaling with black borders. Triangular masks keep free scaling; curvature, glass and manual scanlines are bypassed."))
                    .font(.system(size: 10)).foregroundStyle(.white.opacity(0.6))
                if pointToPointActive, enabled, let fit = TVCRTPixelPerfect.bestFit(
                    drawableSize: state.crtDrawableSize, maximumRows: Int(lineLimit),
                    aspect: 4.0 / 3.0) {
                    HStack(spacing: 8) {
                        Text(String(format: L("Best full-frame: %dL · %dpx stripes."),
                            fit.rows, fit.stripeScale))
                        Button(L("Use")) { crtLines = Double(fit.rows) }
                            .buttonStyle(.plain)
                            .foregroundStyle(EditingTool.tv.logoAccentColor)
                            .accessibilityLabel(String(format: L("Use %d CRT lines"), fit.rows))
                    }
                    .font(.system(size: 10)).foregroundStyle(.white.opacity(0.7))
                }
                Text(L("Phosphor arrangement"))
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.white.opacity(0.7))
                TVCRTMaskChooser(selection: $maskType).disabled(!enabled)
                HStack(spacing: 16) {
                    TVRotaryParameter(name: "Scanline count", value: Binding(
                        get: { Float(min(scanlines, lineLimitDouble)) },
                        set: { scanlines = min(lineLimitDouble, max(120, Double($0.rounded()))) }),
                        range: 120...lineLimit, initial: min(480, lineLimit), step: 1, digits: 0,
                        active: enabled && !automaticLines && !pointToPointActive)
                    TVRotaryParameter(name: "Phosphor peak", value: Binding(
                        get: { Float(min(state.crtBrightness?.potential ?? 1, brightness.isFinite ? max(1, brightness) : 1)) }, set: { brightness = Double($0) }),
                        range: 1...Float(max(1, state.crtBrightness?.potential ?? 1)), initial: 1, step: 0.1, unit: "×", digits: 1,
                        active: enabled && hdr && !automaticBrightness && (state.crtBrightness?.potential ?? 1) > 1)
                }
                HStack(spacing: 16) {
                    TVRotaryParameter(name: "CRT lines", value: Binding(
                        get: { Float(min(crtLines, lineLimitDouble)) },
                        set: { crtLines = min(lineLimitDouble, max(120, Double($0.rounded()))) }),
                        range: 120...lineLimit, initial: min(240, lineLimit), step: 1, unit: "L",
                        digits: 0, active: enabled)
                    TVRotaryParameter(name: "Phosphor mask", value: Binding(
                        get: { Float(maskStrength) }, set: { maskStrength = Double($0) }),
                        range: 0...1, initial: 0.8, step: 0.01, digits: 0, percent: true,
                        active: enabled)
                }
                HStack(spacing: 16) {
                    TVRotaryParameter(name: "Curvature", value: Binding(
                        get: { Float(curvature) }, set: { curvature = Double($0) }),
                        range: 0...1, initial: 0.5, step: 0.01, digits: 0, percent: true,
                        active: enabled && !pointToPointActive)
                }
                Text(L("0% removes barrel distortion; 50% matches the previous fixed curvature."))
                    .font(.system(size: 10)).foregroundStyle(.white.opacity(0.6))
                Divider().overlay(.white.opacity(0.2))
                TVCRTBeamControls(enabled: enabled)
                Divider().overlay(.white.opacity(0.2))
                TVCRTGlassControls(enabled: enabled && !pointToPointActive)
                Text(L("Automatic scanlines follow the simulated CRT lines. Manual range is limited by the current broadcast standard."))
                    .font(.system(size: 10)).foregroundStyle(.white.opacity(0.6))
                Text(L("Each simulated pixel is rendered as an RGB phosphor triplet."))
                    .font(.system(size: 10)).foregroundStyle(.white.opacity(0.6))
                Text(L("Phosphor gaps reduce average brightness; HDR peak compensates."))
                    .font(.system(size: 10)).foregroundStyle(.white.opacity(0.6))
                Text(L("HDR uses available display headroom. Preview only."))
                    .font(.system(size: 10)).foregroundStyle(.white.opacity(0.6))
            }
            }
            .frame(width: 340, height: min(780, max(400, (NSScreen.main?.visibleFrame.height ?? 900) - 140)))
            .background(Color(white: 0.1))
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
