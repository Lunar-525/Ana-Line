"""Render selected SVG wordmarks using native vector fills, with no app changes."""
from pathlib import Path
import subprocess
import sys
import tempfile
from sync_native import native_variant

ROOT = Path(__file__).resolve().parent
COLORS = {'master': (213, 237, 121), 'film': (239, 170, 113),
          'sstv': (141, 220, 219), 'tv': (234, 212, 119), 'radio': (184, 161, 242)}

if __name__ == '__main__':
    modes = sys.argv[1:] or ['radio']
    assert all(mode in COLORS for mode in modes)
    source = 'import SwiftUI\nimport AppKit\nprivate enum LogoPaths {\n'
    source += 'static let slant = CGAffineTransform(a: 1, b: 0, c: -0.2308681911, d: 1, tx: 27, ty: 24)\n'
    source += '\n'.join(native_variant(mode) for mode in modes) + '\n}\n'
    for mode in modes:
        r, g, b = COLORS[mode]
        source += f'''
do {{
    let context = CGContext(data: nil, width: 1210, height: 264, bitsPerComponent: 8, bytesPerRow: 0,
        space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    context.setFillColor(CGColor(gray: 0.06, alpha: 1))
    context.fill(CGRect(x: 0, y: 0, width: 1210, height: 264))
    context.translateBy(x: 0, y: 264); context.scaleBy(x: 2, y: -2)
    for (index, path) in LogoPaths.{mode}.enumerated() {{
        context.setFillColor(index == 5 ? CGColor(red: {r}/255, green: {g}/255, blue: {b}/255, alpha: 1)
                                       : CGColor(gray: 0.95, alpha: 1))
        context.addPath(path.cgPath); context.fillPath()
    }}
    let image = NSBitmapImageRep(cgImage: context.makeImage()!)
    try image.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath:
        "{ROOT}/ana-line-{mode}-proof.png"))
}}
'''
    with tempfile.TemporaryDirectory(prefix='analine-logo-', dir='/private/tmp') as task_dir:
        path = Path(task_dir) / 'render.swift'
        path.write_text(source)
        subprocess.run(['swift', str(path)], check=True)
    print('Rendered: ' + ', '.join(modes))
