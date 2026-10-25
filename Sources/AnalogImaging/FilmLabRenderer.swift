import CoreImage
import Metal
import AnalogCore

public enum FilmLabDisplay: Int, CaseIterable, Sendable {
    case appearance, latent, silver, halide, chemistry, water
    public var title: String { ["胶片外观", "潜影", "金属银", "卤化银", "化学残留", "水膜"][rawValue] }
}

/// Per-pixel two-cell emulsion integration on Metal. No display filter substitutes for reactions.
public final class FilmLabRenderer {
    private let device: MTLDevice
    private let queue: MTLCommandQueue
    private let pipeline: MTLComputePipelineState
    private let context: CIContext
    private let srgb = CGColorSpace(name: CGColorSpace.sRGB)!
    public init() throws {
        guard let device = MTLCreateSystemDefaultDevice(),let queue = device.makeCommandQueue() else {
            throw CubeLUT.ParseError.invalid("Metal is unavailable for the film laboratory")
        }
        self.device = device; self.queue = queue
        let library = try device.makeLibrary(source: Self.shader,options: nil)
        guard let function = library.makeFunction(name: "filmLab") else { throw CubeLUT.ParseError.invalid("Cannot compile film laboratory") }
        pipeline = try device.makeComputePipelineState(function: function)
        context = CIContext(mtlDevice: device,options: [.workingColorSpace: srgb,.outputColorSpace: srgb])
    }
    public func render(_ image: CIImage,session: FilmLabSession,display: FilmLabDisplay = .appearance) throws -> CIImage {
        let e = image.extent, width = Int(e.width),height = Int(e.height)
        func texture() -> MTLTexture? {
            let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba32Float,width: width,height: height,mipmapped: false)
            d.usage = [.shaderRead,.shaderWrite,.renderTarget]
            return device.makeTexture(descriptor: d)
        }
        guard let input = texture(),let output = texture(),let command = queue.makeCommandBuffer() else {
            throw CubeLUT.ParseError.invalid("Cannot allocate laboratory textures")
        }
        let local = image.transformed(by: CGAffineTransform(translationX: -e.minX,y: -e.minY))
        context.render(local,to: input,commandBuffer: command,bounds: CGRect(x: 0,y: 0,width: width,height: height),colorSpace: srgb)
        // Five float4 vectors per operation. Explicit packing avoids Swift/Metal layout ambiguity.
        var packed = [SIMD4<Float>]()
        for op in session.operations {
            let r = op.recipe.validated, weights = FilmLabPhysics.spectralWeights(kelvin: r.kelvin)
            packed.append(SIMD4(Float(op.stage.rawValue),min(7200,max(0,op.seconds)),r.exposureEV,r.lightLeak))
            packed.append(SIMD4(weights.x,weights.y,weights.z,r.temperature))
            packed.append(SIMD4(r.agitation,r.strength,r.freshness,r.flow))
            packed.append(SIMD4(r.humidity,r.airflow,r.minerals,r.dust))
            packed.append(SIMD4(r.developer.activity,r.developer.sensitivity,r.developer == .ddx ? 1 : 1/Float(1+r.dilution),r.developer.grain))
        }
        if packed.isEmpty { packed.append(.zero) }
        guard let buffer = device.makeBuffer(bytes: packed,length: packed.count*MemoryLayout<SIMD4<Float>>.stride),
              let encoder = command.makeComputeCommandEncoder() else { throw CubeLUT.ParseError.invalid("Cannot encode laboratory") }
        var options = SIMD4<UInt32>(UInt32(session.operations.count),UInt32(session.stage.rawValue),UInt32(display.rawValue),session.seed)
        var scan = SIMD2<Float>(session.scanEV.isFinite ? min(4,max(-4,session.scanEV)) : 0,
                                session.scanContrast.isFinite ? min(2,max(0.5,session.scanContrast)) : 1)
        encoder.setComputePipelineState(pipeline)
        encoder.setTexture(input,index: 0); encoder.setTexture(output,index: 1)
        encoder.setBuffer(buffer,offset: 0,index: 0)
        encoder.setBytes(&options,length: MemoryLayout<SIMD4<UInt32>>.stride,index: 1)
        encoder.setBytes(&scan,length: MemoryLayout<SIMD2<Float>>.stride,index: 2)
        encoder.dispatchThreads(MTLSize(width: width,height: height,depth: 1),threadsPerThreadgroup: MTLSize(width: 8,height: 8,depth: 1))
        encoder.endEncoding(); command.commit(); command.waitUntilCompleted()
        if let error = command.error { throw error }
        guard let result = CIImage(mtlTexture: output,options: [.colorSpace: srgb]) else { throw CubeLUT.ParseError.invalid("Cannot read laboratory output") }
        return result.transformed(by: CGAffineTransform(translationX: e.minX,y: e.minY)).cropped(to: e)
    }
    private static let shader = """
    #include <metal_stdlib>
    using namespace metal;
    float labHash(float2 p, uint seed) {
        uint v=as_type<uint>(int(floor(p.x)))*0x9e3779b9u;
        v^=as_type<uint>(int(floor(p.y)))*0x85ebca6bu; v^=seed;
        v^=v>>16; v*=0x7feb352du; v^=v>>15; v*=0x846ca68bu; v^=v>>16;
        return float(v>>8)/16777216.0;
    }
    void diffuse(thread float2 &v, float bath, float rate, float dt, float q) {
        v.x += (bath-v.x)*(1-exp(-rate*dt));
        float transfer = (v.x-v.y)*0.5*(1-exp(-0.025*q*dt));
        v += float2(-transfer,transfer);
    }
    kernel void filmLab(texture2d<float,access::read> input [[texture(0)]],
        texture2d<float,access::write> output [[texture(1)]],
        device const float4 *ops [[buffer(0)]],constant uint4 &options [[buffer(1)]],constant float2 &scan [[buffer(2)]],uint2 gid [[thread_position_in_grid]]) {
        if (gid.x>=output.get_width() || gid.y>=output.get_height()) return;
        float4 source = input.read(gid);
        float3 rgb = source.a>0 ? clamp(source.rgb/source.a,0.0,1.0) : float3(0);
        rgb = select(rgb/12.92,pow((rgb+0.055)/1.055,float3(2.4)),rgb>0.04045);
        float2 uv = (float2(gid)+0.5)/float2(output.get_width(),output.get_height());
        float latent=0,water=0,deposit=0,dust=0;
        float2 silver=0,halide=1,developer=0,acid=0,fixer=0,residue=0;
        for (uint op=0;op<options.x;op++) {
            float4 a=ops[op*5],b=ops[op*5+1],c=ops[op*5+2],d=ops[op*5+3],e=ops[op*5+4];
            int stage=int(a.x);
            if (stage==0) {
                float light=max(0.0,dot(rgb*b.xyz,float3(0.28,0.52,0.2))*exp2(a.z));
                float leak=a.w*exp(-uv.x*12)*2;
                latent=1-(1-latent)*exp(-(light+leak)*a.y*2);
                continue;
            }
            int steps=max(1,int(ceil(a.y/5)));
            float dt=a.y/steps,q=exp2((b.w-20)/10);
            float streak=1-pow(1-c.x,2.0)*0.6*labHash(float2(floor(uv.x*32),0),options.w);
            float supply=(0.002+0.07*c.x)*q*streak;
            for (int step=0;step<steps;step++) {
                if (stage==1) {
                    diffuse(developer,c.y*c.z*e.z,supply,dt,q); water=1;
                } else if (stage==2) {
                    diffuse(developer,0,supply,dt,q); diffuse(acid,c.y,supply*2,dt,q);
                    float2 neutralized=developer*(1-exp(-acid*0.3*dt));
                    developer-=neutralized; acid=max(float2(0),acid-neutralized);
                } else if (stage==3) {
                    diffuse(developer,0,supply,dt,q); diffuse(acid,0,supply,dt,q);
                    diffuse(fixer,c.y*c.z,supply,dt,q);
                    float2 removed=halide*(1-exp(-0.035*q*fixer*dt));
                    halide-=removed; residue+=removed*0.7;
                    diffuse(residue,c.y*0.2,supply*0.3,dt,q);
                } else if (stage==4) {
                    float exchange=(0.001+0.09*c.w)*q;
                    diffuse(developer,0,exchange,dt,q); diffuse(acid,0,exchange,dt,q);
                    diffuse(fixer,0,exchange,dt,q); diffuse(residue,0,exchange,dt,q);
                } else if (stage==5) {
                    float lost=water*(1-exp(-0.008*q*(1-d.x)*(0.2+d.y)*dt));
                    water-=lost; deposit+=lost*(d.z*0.4+(residue.x+residue.y)*0.3);
                    dust+=(1-exp(-d.w*0.0006*dt))*(0.2+water);
                }
                if (stage<=5) {
                    float rate=0.012*q*e.x*water*(0.015+latent*e.y);
                    float2 converted=halide*(1-exp(-rate*developer*dt));
                    silver+=converted; halide-=converted; developer=max(float2(0),developer-converted*0.65);
                }
            }
        }
        float s=(silver.x+silver.y)*0.5,h=(halide.x+halide.y)*0.5,r=(residue.x+residue.y)*0.5;
        float3 color;
        if (options.z==1) color=float3(latent);
        else if (options.z==2) color=float3(s);
        else if (options.z==3) color=float3(h);
        else if (options.z==4) color=float3(clamp(r+(fixer.x+fixer.y)*0.25,0.0,1.0));
        else if (options.z==5) color=float3(water);
        else {
            float transmission=pow(10.0,-(0.12+2.3*s+0.4*h));
            float grainCell=max(0.4,min(float(output.get_width()),float(output.get_height()))/1000*1.5);
            float grain=(labHash(floor(float2(gid)/grainCell),options.w+21)-0.5)*0.06;
            float grainScale=options.x>0 ? ops[(options.x-1)*5+4].w : 1.0;
            s=clamp(s+grain*grainScale*sqrt(max(0.0,s*(1-s))),0.0,1.0);
            transmission=pow(10.0,-(0.12+2.3*s+0.4*h));
            // Fixed reference scanner characteristic, independently adjustable from chemistry.
            float estimatedLatent=clamp(-log(max(0.001,1-s))/4.0-0.015,0.0,0.995);
            float scanLinear=max(0.0,-log(1-estimatedLatent)/2.0)*exp2(scan.x);
            float scanValue=scanLinear<=0.0031308 ? scanLinear*12.92 : 1.055*pow(scanLinear,1.0/2.4)-0.055;
            scanValue=clamp((scanValue-0.5)*scan.y+0.5,0.0,1.0);
            float value=options.y==6 ? scanValue : transmission;
            color=mix(float3(value),float3(0.78,0.74,0.61),h*0.5);
            float2 grid=uv*float2(output.get_width(),output.get_height())/min(float(output.get_width()),float(output.get_height()))*22;
            float2 cell=floor(grid);
            float2 center=0.2+0.6*float2(labHash(cell,options.w+11),labHash(cell,options.w+12));
            float dist=length(fract(grid)-center),radius=0.12+0.15*labHash(cell,options.w+13);
            float ring=(1-smoothstep(0.015,0.045,abs(dist-radius)))*step(0.72,labHash(cell,options.w+14));
            float speck=(1-smoothstep(0.015,0.04,dist))*step(0.8,labHash(cell,options.w+15));
            color*=1-clamp(deposit*ring*0.3+dust*speck*0.5,0.0,0.9);
            color=mix(color,float3(0.45,0.32,0.14),clamp(r*0.25,0.0,0.3));
        }
        output.write(float4(clamp(color,0.0,1.0)*source.a,source.a),gid);
    }
    """
}
