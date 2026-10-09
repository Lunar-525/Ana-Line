import CoreImage
import Metal
import AnalogCore

/// A bounded Poisson Boolean disk field, reconstructed through an optical filter.
/// This is output-referred grain, not a calibrated spectral/chemical film stock.
final class FilmGrainRenderer {
    private let device: MTLDevice
    private let queue: MTLCommandQueue
    private let pipeline: MTLComputePipelineState
    private let context: CIContext
    private let srgb = CGColorSpace(name: CGColorSpace.sRGB)!
    init() throws {
        guard let device = MTLCreateSystemDefaultDevice(), let queue = device.makeCommandQueue() else {
            throw CubeLUT.ParseError.invalid("Metal is unavailable for film grain")
        }
        self.device = device; self.queue = queue
        let library = try device.makeLibrary(source: Self.shader,options: nil)
        guard let function = library.makeFunction(name: "silverCoverage") else {
            throw CubeLUT.ParseError.invalid("Cannot compile film grain")
        }
        pipeline = try device.makeComputePipelineState(function: function)
        context = CIContext(mtlDevice: device,options: [.workingColorSpace: srgb,.outputColorSpace: srgb])
    }
    func render(_ image: CIImage,settings: GrainSettings) throws -> CIImage {
        let extent = image.extent, w = Int(extent.width), h = Int(extent.height)
        let supersampling = 2
        func texture(_ width: Int,_ height: Int) -> MTLTexture? {
            let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba16Float,width: width,height: height,mipmapped: false)
            descriptor.usage = [.shaderRead,.shaderWrite,.renderTarget]
            return device.makeTexture(descriptor: descriptor)
        }
        guard let input = texture(w,h), let output = texture(w*supersampling,h*supersampling),
              let command = queue.makeCommandBuffer() else { throw CubeLUT.ParseError.invalid("Cannot allocate film grain textures") }
        context.render(image,to: input,commandBuffer: command,bounds: extent,colorSpace: srgb)
        guard let encoder = command.makeComputeCommandEncoder() else { throw CubeLUT.ParseError.invalid("Cannot render film grain") }
        // 0.24 cell is the mean crystal radius; size is its nominal diameter at 1000px.
        let cell = max(0.1,Float(min(w,h))/1000*settings.size/0.48)
        var parameters = SIMD4<Float>(cell,settings.texture,Float(supersampling),0)
        var seed = settings.seed
        encoder.setComputePipelineState(pipeline)
        encoder.setTexture(input,index: 0); encoder.setTexture(output,index: 1)
        encoder.setBytes(&parameters,length: MemoryLayout<SIMD4<Float>>.stride,index: 0)
        encoder.setBytes(&seed,length: MemoryLayout<UInt32>.stride,index: 1)
        let side = MTLSize(width: 8,height: 8,depth: 1)
        encoder.dispatchThreads(MTLSize(width: output.width,height: output.height,depth: 1),threadsPerThreadgroup: side)
        encoder.endEncoding(); command.commit(); command.waitUntilCompleted()
        if let error = command.error { throw error }
        guard var field = CIImage(mtlTexture: output,options: [.colorSpace: srgb]) else {
            throw CubeLUT.ParseError.invalid("Cannot read film grain")
        }
        // Pixel aperture plus user-controlled scanner diffusion. Only the crystal
        // field is filtered; source color and alpha are retained by reconstruction.
        let blur = sqrt(0.35*0.35+pow(CGFloat(settings.blur*settings.size)*min(extent.width,extent.height)/1000,2))
        field = field.clampedToExtent().applyingFilter("CIGaussianBlur",parameters: [kCIInputRadiusKey: blur*CGFloat(supersampling)])
            .transformed(by: CGAffineTransform(scaleX: 1/CGFloat(supersampling),y: 1/CGFloat(supersampling)))
            .transformed(by: CGAffineTransform(translationX: extent.minX,y: extent.minY)).cropped(to: extent)
        return field
    }
    private static let shader = """
    #include <metal_stdlib>
    using namespace metal;
    uint scramble(uint x) {
        x ^= x >> 16; x *= 0x7feb352du; x ^= x >> 15; x *= 0x846ca68bu; return x ^ (x >> 16);
    }
    float random01(thread uint &state) {
        state = scramble(state+0x9e3779b9u); return (float(state >> 8)+0.5f)/16777216.0f;
    }
    float luminance(texture2d<float,access::sample> image,float2 p) {
        constexpr sampler linear(coord::pixel,address::clamp_to_edge,filter::linear);
        float4 c = image.sample(linear,p);
        return c.a > 0.00001f ? clamp(dot(c.rgb/c.a,float3(0.2126f,0.7152f,0.0722f)),0.0f,1.0f) : 0.0f;
    }
    kernel void silverCoverage(texture2d<float,access::sample> image [[texture(0)]],
        texture2d<float,access::write> output [[texture(1)]],constant float4 &parameters [[buffer(0)]],
        constant uint &seed [[buffer(1)]],uint2 gid [[thread_position_in_grid]]) {
        if (gid.x >= output.get_width() || gid.y >= output.get_height()) return;
        float cellSize = parameters.x;
        float2 p = (float2(gid)+0.5f)/parameters.z;
        float target = luminance(image,p);
        if (target <= 0.0001f || target >= 0.9999f) {
            output.write(float4(float3(target),1.0f),gid); return;
        }
        // Three-point quadrature of a log-normal radius distribution. Its second
        // moment is exact for this discrete approximation and calibrates coverage.
        float sigma = 0.08f+0.37f*parameters.y;
        float r0 = 0.24f*exp(-1.7320508f*sigma), r1 = 0.24f, r2 = 0.24f*exp(1.7320508f*sigma);
        float area = M_PI_F*(r0*r0/6.0f+r1*r1*2.0f/3.0f+r2*r2/6.0f);
        float2 q = p/cellSize;
        int2 base = int2(floor(q));
        float coverage = 0.0f;
        // Independent depth slices reduce binary contrast, representing a scanned
        // emulsion rather than a single opaque binary layer.
        for (uint layer=0;layer<3;layer++) {
            bool covered = false;
            for (int dy=-1;dy<=1;dy++) for (int dx=-1;dx<=1;dx++) {
                if (covered) continue;
                int2 tile = base+int2(dx,dy);
                uint state = scramble(as_type<uint>(tile.x)^scramble(as_type<uint>(tile.y))^scramble(seed+layer*7919u));
                float local = clamp(luminance(image,(float2(tile)+0.5f)*cellSize),0.00001f,0.9999f);
                // P(covered)=1-exp(-lambda E[pi R^2]); invert to retain local tone.
                float lambda = -log(1.0f-local)/area;
                float u = random01(state), probability = exp(-lambda), cdf = probability;
                uint count = 0;
                while (u > cdf && count < 128) {
                    count++; probability *= lambda/float(count); cdf += probability;
                }
                for (uint n=0;n<count;n++) {
                    float2 center = float2(tile)+float2(random01(state),random01(state));
                    float draw = random01(state);
                    float radius = draw < 1.0f/6.0f ? r0 : (draw > 5.0f/6.0f ? r2 : r1);
                    float2 delta = q-center;
                    if (dot(delta,delta) < radius*radius) { covered = true; break; }
                }
            }
            coverage += covered ? 1.0f/3.0f : 0.0f;
        }
        output.write(float4(float3(coverage),1.0f),gid);
    }
    """
}
