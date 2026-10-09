import CoreImage
import AnalogCore

/// GPU procedural effects. All color kernels preserve premultiplied source alpha.
public final class AnalogEffects {
    private let mixKernel: CIColorKernel
    private let grainRenderer: FilmGrainRenderer
    private let grainKernel: CIColorKernel
    private let leakKernel: CIColorKernel
    public init() throws {
        func compile(_ source: String) throws -> CIColorKernel {
            guard let kernel = CIColorKernel(source: source) else {
                throw CubeLUT.ParseError.invalid("Cannot compile procedural effect kernel")
            }
            return kernel
        }
        mixKernel = try compile("""
        kernel vec4 lutMix(__sample original, __sample graded, float amount) {
            return mix(original, graded, amount);
        }
        """)
        grainRenderer = try FilmGrainRenderer()
        grainKernel = try compile("""
        kernel vec4 grainReconstruction(__sample image, __sample coverage, float amount) {
            vec4 c = unpremultiply(image);
            vec3 rgb = clamp(c.rgb,0.0,1.0);
            float y = dot(rgb,vec3(0.2126,0.7152,0.0722));
            float reconstructed = clamp(coverage.r,0.0,1.0);
            // Map source luminance to scanned coverage while retaining chromatic
            // direction, with bounded black/white mixtures instead of clipping.
            vec3 darker = rgb*(reconstructed/max(y,0.00001));
            vec3 lighter = 1.0-(1.0-rgb)*((1.0-reconstructed)/max(1.0-y,0.00001));
            vec3 grain = mix(darker,lighter,step(y,reconstructed));
            c.rgb = mix(rgb,clamp(grain,0.0,1.0),amount);
            return premultiply(c);
        }
        """)
        leakKernel = try compile("""
        float hashLeak(vec2 p, float seed) {
            return fract(sin(dot(p,vec2(127.1,311.7))+seed*13.71)*43758.5453);
        }
        float noiseLeak(vec2 p, float seed) {
            vec2 cell = floor(p); vec2 f = fract(p); f=f*f*(3.0-2.0*f);
            return mix(mix(hashLeak(cell,seed),hashLeak(cell+vec2(1.0,0.0),seed),f.x),
                       mix(hashLeak(cell+vec2(0.0,1.0),seed),hashLeak(cell+vec2(1.0,1.0),seed),f.x),f.y);
        }
        vec3 decodeLeak(vec3 v) {
            vec3 low = v/12.92;
            vec3 high = pow(max((v+0.055)/1.055,vec3(0.0)),vec3(2.4));
            return mix(low,high,step(vec3(0.04045),v));
        }
        vec3 encodeLeak(vec3 v) {
            return mix(v*12.92,1.055*pow(max(v,vec3(0.0)),vec3(1.0/2.4))-0.055,step(vec3(0.0031308),v));
        }
        kernel vec4 lightLeak(__sample image, vec2 dimensions, vec2 center,
            float width, float length, float angle, float softness, float irregularity,
            float hue, float amount, float seed) {
            float shortEdge = min(dimensions.x,dimensions.y);
            vec2 p = (destCoord()-vec2(center.x*dimensions.x,(1.0-center.y)*dimensions.y))/shortEdge;
            float ca=cos(angle); float sa=sin(angle);
            vec2 q = vec2(ca*p.x+sa*p.y,-sa*p.x+ca*p.y);
            float warp = (noiseLeak(q*4.0+vec2(11.0,3.0),seed)-0.5)*irregularity;
            q.x += warp*width*1.4;
            vec2 shape = q/vec2(width,length*0.5);
            float falloff = 1.0 + 5.0*(1.0-softness);
            float mainLobe = exp(-dot(shape,shape)*falloff);
            vec2 satellite = (q-vec2(width*0.45,length*0.18))/vec2(width*0.65,length*0.32);
            float secondLobe = exp(-dot(satellite,satellite)*falloff)*irregularity*0.5;
            float streak = 0.8+0.2*noiseLeak(q*vec2(3.0,9.0),seed+7.0);
            float mask = clamp((mainLobe+secondLobe)*streak,0.0,1.0);
            vec3 tint = clamp(abs(mod(hue*6.0+vec3(0.0,4.0,2.0),6.0)-3.0)-1.0,0.0,1.0);
            tint = mix(vec3(0.04),tint,0.96);
            tint = mix(tint,vec3(1.0),pow(mask,3.0)*0.55);
            vec4 c = unpremultiply(image);
            vec3 linear = decodeLeak(clamp(c.rgb,0.0,1.0));
            // Positive light exposure / veiling fog in linear light.
            linear = 1.0-(1.0-linear)*exp(-tint*mask*amount*2.5);
            c.rgb = clamp(encodeLeak(linear),0.0,1.0);
            return premultiply(c);
        }
        """)
    }
    public func apply(original: CIImage,graded: CIImage,settings: EffectSettings) throws -> CIImage {
        let s = settings.validated, extent = original.extent
        func result(_ value: CIImage?) throws -> CIImage {
            guard let value else { throw CubeLUT.ParseError.invalid("Effect rendering failed") }
            return value.cropped(to: extent)
        }
        var image = s.lutMix == 0 ? original : s.lutMix == 1 ? graded
            : try result(mixKernel.apply(extent: extent,arguments: [original,graded,s.lutMix]))
        if s.grain.amount > 0 {
            let coverage = try grainRenderer.render(image,settings: s.grain)
            image = try result(grainKernel.apply(extent: extent,arguments: [image,coverage,s.grain.amount]))
        }
        if s.leak.amount > 0 {
            let leak = s.leak
            image = try result(leakKernel.apply(extent: extent,arguments: [image,
                CIVector(x: extent.width,y: extent.height),CIVector(x: CGFloat(leak.x),y: CGFloat(leak.y)),
                leak.width,leak.length,leak.rotation * .pi/180,leak.softness,leak.irregularity,
                leak.hue/360,leak.amount,Float(leak.seed % 65521)]))
        }
        return image
    }
}
