import CoreImage
import AnalogCore

/// A display-referred artistic model, not a calibrated emulsion simulation.
final class FilmProcessRenderer {
    private let kernel: CIColorKernel
    init() throws {
        guard let kernel = CIColorKernel(source: """
        float filmHash(vec2 p, float seed) {
            return fract(sin(dot(p,vec2(127.1,311.7))+seed*13.71)*43758.5453);
        }
        float filmNoise(vec2 p, float seed) {
            vec2 cell = floor(p); vec2 f = fract(p); f=f*f*(3.0-2.0*f);
            return mix(mix(filmHash(cell,seed),filmHash(cell+vec2(1.0,0.0),seed),f.x),
                       mix(filmHash(cell+vec2(0.0,1.0),seed),filmHash(cell+vec2(1.0),seed),f.x),f.y);
        }
        kernel vec4 filmProcess(__sample image, vec2 origin, vec2 dimensions,
            float exposure, float development, float agitation, float stop,
            float fixation, float wash, float drying, float seed) {
            vec4 c = unpremultiply(image);
            vec2 uv = (destCoord()-origin)/dimensions;
            vec2 p = (destCoord()-origin)/min(dimensions.x,dimensions.y);
            float y = clamp(dot(c.rgb,vec3(0.2126,0.7152,0.0722)),0.0,1.0);
            // Decode the display signal before exposing; encode the scanned positive.
            float linear = mix(y/12.92,pow((y+0.055)/1.055,2.4),step(0.04045,y));
            linear = clamp(linear*pow(2.0,exposure),0.0,1.0);
            y = mix(linear*12.92,1.055*pow(linear,1.0/2.4)-0.055,step(0.0031308,linear));
            float uneven = (filmNoise(p*vec2(8.0,2.0),seed)-0.5)*(1.0-agitation)*0.5;
            float residual = (1.0-stop)*(0.12+0.16*filmNoise(p*vec2(12.0,3.0),seed+3.0));
            float contrast = max(0.1,development+residual+uneven);
            y = clamp((y-0.5)*contrast+0.5+residual*0.15,0.0,1.0);
            // Incomplete fixing leaves a milky veil in this scanned representation.
            y = mix(y,0.78,(1.0-fixation)*0.5);
            float flow = filmNoise(p*vec2(45.0,2.0),seed+7.0);
            float stain = (1.0-wash)*smoothstep(0.42,0.85,flow)*0.22;
            vec3 rgb = vec3(y)*(1.0-stain)+vec3(0.08,0.045,0.01)*stain;
            // Stable, resolution-independent cell droplets with a soft mineral rim.
            vec2 grid = p*22.0; vec2 cell = floor(grid);
            vec2 center = vec2(0.2)+0.6*vec2(filmHash(cell,seed+11.0),filmHash(cell,seed+12.0));
            float radius = 0.12+0.15*filmHash(cell,seed+13.0);
            float distance = length(fract(grid)-center);
            float ring = (1.0-smoothstep(0.015,0.045,abs(distance-radius)))
                *step(0.72,filmHash(cell,seed+14.0));
            float dust = (1.0-smoothstep(0.015,0.04,distance))*step(0.8,filmHash(cell,seed+15.0));
            rgb = rgb*(1.0-(1.0-drying)*(ring*0.22+dust*0.65));
            c.rgb = clamp(rgb,0.0,1.0);
            return premultiply(c);
        }
        """) else { throw CubeLUT.ParseError.invalid("Cannot compile film processing kernel") }
        self.kernel = kernel
    }
    func render(_ image: CIImage,settings: FilmProcessSettings) throws -> CIImage {
        let e = image.extent
        guard let result = kernel.apply(extent: e,arguments: [image,
            CIVector(x: e.minX,y: e.minY),CIVector(x: e.width,y: e.height),
            settings.exposureEV,settings.development,settings.agitation,settings.stop,
            settings.fixation,settings.wash,settings.drying,Float(settings.seed % 65521)]) else {
            throw CubeLUT.ParseError.invalid("Film processing failed")
        }
        return result.cropped(to: e)
    }
}
