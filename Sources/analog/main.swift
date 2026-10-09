import AppKit
import AnalogCore

func decode(_ x: Float) -> Float { x <= 0.04045 ? x/12.92 : pow((x+0.055)/1.055,2.4) }
func encode(_ x: Float) -> Float { x <= 0.0031308 ? x*12.92 : 1.055*pow(x,1/2.4)-0.055 }

do {
    let args = Array(CommandLine.arguments.dropFirst())
    guard args.count == 2 || args.count == 3 else {
        throw NSError(domain: "Usage: analog <input-image|--demo> <output.png> [recipe.json]", code: 1)
    }
    let source: Raster
    if args[0] == "--demo" {
        let w = 768, h = 512
        source = Raster(width: w, height: h, pixels: (0..<w*h).map { i in
            let x = Float(i%w)/Float(w), y = Float(i/w)/Float(h)
            if (x-0.7)*(x-0.7)+(y-0.3)*(y-0.3) < 0.012 { return SIMD4<Float>(1,0.95,0.8,1) }
            return SIMD4<Float>(0.08+x*0.55,0.05+y*0.65,0.12+(1-x)*0.4,1)
        })
    } else {
        guard let image = NSImage(contentsOfFile: args[0]),
              let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            throw NSError(domain: "Cannot read input image", code: 2)
        }
        let w = cg.width, h = cg.height
        var bytes = [UInt8](repeating: 0, count: w*h*4)
        let ok = bytes.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(data: buffer.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w*4,
                space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            context.draw(cg, in: CGRect(x: 0,y: 0,width: w,height: h)); return true
        }
        guard ok else { throw NSError(domain: "Cannot decode pixels", code: 3) }
        source = Raster(width: w, height: h, pixels: (0..<w*h).map { i in
            let a = Float(bytes[i*4+3])/255
            func channel(_ n: Int) -> Float { a > 0 ? decode(min(1,Float(bytes[i*4+n])/255/a)) : 0 }
            return SIMD4<Float>(channel(0),channel(1),channel(2),a)
        })
    }
    let recipe = try args.count == 3 ? JSONDecoder().decode(Recipe.self, from: Data(contentsOf: URL(fileURLWithPath: args[2]))) : Recipe()
    let result = AnalogEngine.render(source, recipe: recipe)
    let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: result.width, pixelsHigh: result.height,
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
        bitmapFormat: .alphaNonpremultiplied, bytesPerRow: result.width*4, bitsPerPixel: 32)!
    bitmap.setProperty(.colorSyncProfileData, withValue: NSColorSpace.sRGB.iccProfileData!)
    for (i,p) in result.pixels.enumerated() {
        for c in 0..<3 { bitmap.bitmapData![i*4+c] = UInt8(max(0,min(255,(encode(p[c])*255).rounded()))) }
        bitmap.bitmapData![i*4+3] = UInt8(max(0,min(255,(p.w*255).rounded())))
    }
    try bitmap.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: args[1]))
    print("Saved \(args[1]) (\(result.width) × \(result.height))")
} catch {
    fputs("\(error)\n", stderr)
    exit(1)
}
