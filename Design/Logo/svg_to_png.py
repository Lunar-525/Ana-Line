"""Rasterise the SVG wordmarks to PNG at a given scale factor.

Usage: python3 svg_to_png.py [scale] [file.svg ...]

Defaults to scale 2 over every *.svg in this directory, writing
<name>@2x.png next to the source. Scaling is done by AppKit/CoreSVG, so the
artwork is re-rendered as vectors at the larger size rather than upsampled:
605x132 viewBox -> 1210x264 pixels.

`currentColor` resolves to black, exactly as when the files are shown through
the README's <img src="...svg"> on a light background. The ana-line-*-preview
files set their own cream ink and #171a18 plate, so they come out as full-bleed
opaque images; every other file keeps a transparent background.
"""
from pathlib import Path
import struct
import subprocess
import sys
import tempfile

ROOT = Path(__file__).resolve().parent

SWIFT = r'''
import AppKit

let scale = CGFloat(Double(CommandLine.arguments[1])!)
let arguments = Array(CommandLine.arguments.dropFirst(2))
precondition(arguments.count % 2 == 0, "expected input/output path pairs")

for pair in stride(from: 0, to: arguments.count, by: 2) {
    let input = arguments[pair]
    let output = arguments[pair + 1]
    guard let image = NSImage(contentsOfFile: input) else {
        FileHandle.standardError.write("cannot read \(input)\n".data(using: .utf8)!)
        exit(1)
    }
    let points = image.size
    precondition(points.width > 0 && points.height > 0, "\(input) has no intrinsic size")
    let pixels = NSSize(width: (points.width * scale).rounded(),
                        height: (points.height * scale).rounded())
    guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil,
                                     pixelsWide: Int(pixels.width), pixelsHigh: Int(pixels.height),
                                     bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                                     isPlanar: false, colorSpaceName: .deviceRGB,
                                     bytesPerRow: 0, bitsPerPixel: 0) else {
        FileHandle.standardError.write("cannot allocate bitmap for \(input)\n".data(using: .utf8)!)
        exit(1)
    }
    // A 605x132 point size over a 1210x264 pixel bitmap makes it a 2x context.
    rep.size = points
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    image.draw(in: NSRect(origin: .zero, size: points), from: .zero,
               operation: .sourceOver, fraction: 1)
    NSGraphicsContext.current?.flushGraphics()
    NSGraphicsContext.restoreGraphicsState()
    guard let data = rep.representation(using: .png, properties: [:]) else { exit(1) }
    try! data.write(to: URL(fileURLWithPath: output))
    print("\(output)  \(Int(pixels.width))x\(Int(pixels.height))")
}
'''


def png_size(path):
    with open(path, 'rb') as handle:
        return struct.unpack('>II', handle.read(24)[16:24])


if __name__ == '__main__':
    args = sys.argv[1:]
    scale = float(args.pop(0)) if args and args[0].replace('.', '', 1).isdigit() else 2.0
    tag = f'{scale:g}'
    svgs = [Path(a).resolve() for a in args] or sorted(ROOT.glob('*.svg'))
    pairs = []
    for svg in svgs:
        pairs += [str(svg), str(svg.with_name(f'{svg.stem}@{tag}x.png'))]

    with tempfile.TemporaryDirectory(prefix='analine-png-', dir='/private/tmp') as task_dir:
        script = Path(task_dir) / 'rasterise.swift'
        script.write_text(SWIFT)
        result = subprocess.run(['swift', str(script), f'{scale:g}', *pairs],
                                capture_output=True, text=True)
        if result.returncode:
            sys.exit(result.stderr.strip() or 'rasterising failed')

    for target in pairs[1::2]:
        width, height = png_size(target)
        print(f'{Path(target).name}  {width}x{height}')
