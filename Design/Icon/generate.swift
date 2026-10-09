import AppKit

// Custom AL geometry follows the wordmark's 13-degree slant and broad strokes.
// Keep these paths as the shared source for the SVG and raster exports.
let aOutline = "M0 200 57.5 0H117.5L175 200H125L115 155H57.5L47.5 200ZM67.5 115H105L87.5 45Z"
let joinedL = "M132 0H180V155H275V200H132Z"
let openL = "M190 0H238V155H333V200H190Z"
let terminal = "M213 155H275V200H213Z"
let directory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
let ivory = CGColor(red: 0.95, green: 0.95, blue: 0.91, alpha: 1)
let lime = CGColor(red: 213/255, green: 237/255, blue: 121/255, alpha: 1)
let slant = CGAffineTransform(a: 1, b: 0, c: -0.2308681911, d: 1, tx: 0, ty: 0)

func path(_ data: String) -> CGPath {
    let regex = try! NSRegularExpression(pattern: "[MLHVZ]|-?[0-9]+(?:\\.[0-9]+)?")
    let ns = data as NSString
    let tokens = regex.matches(in: data, range: NSRange(location: 0, length: ns.length))
        .map { ns.substring(with: $0.range) }
    var i = 0, command = "", x = 0.0, y = 0.0
    let result = CGMutablePath()
    while i < tokens.count {
        if ["M", "L", "H", "V", "Z"].contains(tokens[i]) {
            command = tokens[i]; i += 1
        }
        switch command {
        case "M", "L":
            x = Double(tokens[i])!; y = Double(tokens[i + 1])!; i += 2
            if command == "M" { result.move(to: CGPoint(x: x, y: y)); command = "L" }
            else { result.addLine(to: CGPoint(x: x, y: y)) }
        case "H":
            x = Double(tokens[i])!; i += 1; result.addLine(to: CGPoint(x: x, y: y))
        case "V":
            y = Double(tokens[i])!; i += 1; result.addLine(to: CGPoint(x: x, y: y))
        case "Z": result.closeSubpath(); command = ""
        default: fatalError("Unsupported SVG path")
        }
    }
    return result
}

func artwork(_ variant: String) -> [(String, CGColor)] {
    variant == "shared" ? [(aOutline, ivory), (joinedL, ivory), (terminal, lime)]
                        : [(aOutline, ivory), (openL, lime)]
}

func placement(_ variant: String) -> (Double, Double, Double) {
    var bounds = CGRect.null
    for (data, _) in artwork(variant) {
        var transform = slant
        bounds = bounds.union(path(data).copy(using: &transform)!.boundingBoxOfPath)
    }
    let scale = min(620 / bounds.width, 430 / bounds.height)
    return (512 - bounds.midX * scale, 512 - bounds.midY * scale, scale)
}

func render(_ variant: String, size: Int) -> CGImage {
    let context = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8,
                            bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    context.scaleBy(x: Double(size)/1024, y: Double(size)/1024)
    context.translateBy(x: 0, y: 1024); context.scaleBy(x: 1, y: -1)
    let tile = CGPath(roundedRect: CGRect(x: 100, y: 100, width: 824, height: 824),
                      cornerWidth: 182, cornerHeight: 182, transform: nil)
    context.saveGState()
    context.addPath(tile); context.clip()
    let colors = [CGColor(gray: 0.115, alpha: 1), CGColor(gray: 0.025, alpha: 1)] as CFArray
    let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colors, locations: [0, 1])!
    context.drawLinearGradient(gradient, start: CGPoint(x: 512, y: 100),
                               end: CGPoint(x: 512, y: 924), options: [])
    context.restoreGState()
    context.addPath(tile); context.setStrokeColor(CGColor(gray: 0.27, alpha: 0.5))
    context.setLineWidth(2); context.strokePath()
    let (x, y, scale) = placement(variant)
    context.translateBy(x: x, y: y); context.scaleBy(x: scale, y: scale)
    context.concatenate(slant)
    for (data, color) in artwork(variant) {
        context.setFillColor(color); context.addPath(path(data)); context.fillPath()
    }
    return context.makeImage()!
}

func png(_ image: CGImage, _ url: URL) throws {
    try NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])!.write(to: url)
}

func svg(_ variant: String) -> String {
    let (x, y, scale) = placement(variant)
    let paths = artwork(variant).map { data, color in
        "<path fill=\"\(color === lime ? "#d5ed79" : "#f2f2e8")\" fill-rule=\"nonzero\" d=\"\(data)\"/>"
    }.joined()
    return """
    <svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 1024 1024" role="img" aria-label="Ana-Line AL app icon · \(variant)">
    <defs><linearGradient id="tile" x2="0" y2="1"><stop stop-color="#1d1d1d"/><stop offset="1" stop-color="#060606"/></linearGradient></defs>
    <rect x="100" y="100" width="824" height="824" rx="182" fill="url(#tile)" stroke="#454545" stroke-opacity=".5" stroke-width="2"/>
    <g transform="translate(\(x) \(y)) scale(\(scale)) skewX(-13)">\(paths)</g>
    </svg>
    """
}

try FileManager.default.createDirectory(at: directory.appendingPathComponent("AnaLine.iconset"), withIntermediateDirectories: true)
for variant in ["shared", "open"] {
    try png(render(variant, size: 1024), directory.appendingPathComponent("al-\(variant).png"))
    try svg(variant).write(to: directory.appendingPathComponent("al-\(variant).svg"), atomically: true, encoding: .utf8)
}
for size in [16, 32, 128, 256, 512] {
    for retina in [false, true] {
        let suffix = retina ? "@2x" : ""
        try png(render("shared", size: size * (retina ? 2 : 1)),
                directory.appendingPathComponent("AnaLine.iconset/icon_\(size)x\(size)\(suffix).png"))
    }
}

let board = CGContext(data: nil, width: 1080, height: 560, bitsPerComponent: 8, bytesPerRow: 0,
                       space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
board.setFillColor(CGColor(gray: 0.9, alpha: 1)); board.fill(CGRect(x: 0, y: 0, width: 1080, height: 560))
for (index, variant) in ["shared", "open"].enumerated() {
    board.draw(render(variant, size: 1024), in: CGRect(x: 40 + index * 530, y: 70, width: 470, height: 470))
    for (sample, size) in [16, 32, 64].enumerated() {
        board.draw(render(variant, size: size), in: CGRect(x: 175 + index * 530 + sample * 60,
                                                          y: 30, width: size, height: size))
    }
}
try png(board.makeImage()!, directory.appendingPathComponent("al-icon-comparison.png"))
print("Exported two AL concepts, size proofs, and a complete iconset.")
