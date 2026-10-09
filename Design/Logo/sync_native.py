"""Synchronize selected SVG outline variants without rewriting the SwiftUI view."""
from pathlib import Path
import re
import sys
import xml.etree.ElementTree as ET

ROOT = Path(__file__).resolve().parent
NS = {'s': 'http://www.w3.org/2000/svg'}


def commands(data, dx):
    tokens = re.findall(r'[MLHVQZ]|-?\d+(?:\.\d+)?', data)
    index = 0
    command = None
    x = y = 0

    def point(x, y):
        return f'CGPoint(x: {x + dx:g}, y: {y:g})'

    while index < len(tokens):
        if tokens[index].isalpha():
            command = tokens[index]
            index += 1
        if command == 'Z':
            yield 'p.closeSubpath()'
            command = None
        elif command in ('M', 'L'):
            x, y = map(float, tokens[index:index + 2])
            index += 2
            operation = 'move' if command == 'M' else 'addLine'
            yield f'p.{operation}(to: {point(x, y)})'
            command = 'L'
        elif command == 'H':
            x = float(tokens[index])
            index += 1
            yield f'p.addLine(to: {point(x, y)})'
        elif command == 'V':
            y = float(tokens[index])
            index += 1
            yield f'p.addLine(to: {point(x, y)})'
        elif command == 'Q':
            cx, cy, x, y = map(float, tokens[index:index + 4])
            index += 4
            yield f'p.addQuadCurve(to: {point(x, y)}, control: {point(cx, cy)})'
        else:
            raise ValueError(f'Unsupported SVG command: {command}')


def native_variant(mode):
    svg = ET.parse(ROOT / f'ana-line-{mode}.svg').getroot()
    groups = svg.findall('.//s:g[@class="letter-motion"]', NS)
    groups += svg.findall('.//s:g[@class="signal-motion"]', NS)
    assert len(groups) == 6
    lines = [f'    static let {mode}: [Path] = [']
    for group in groups:
        lines.append('        Path { p in')
        for path in group.findall('s:path', NS):
            transform = path.get('transform', 'translate(0 0)')
            dx = float(re.search(r'translate\(([-\d.]+)', transform)[1])
            lines.extend('            ' + line for line in commands(path.get('d'), dx))
        lines.append('        }.applying(slant),')
    lines.append('    ]')
    return '\n'.join(lines)


if __name__ == '__main__':
    target = ROOT.parents[1] / 'Sources/AnalogGUI/AnaLineLogo.swift'
    source = target.read_text()
    for mode in sys.argv[1:] or ['film', 'tv']:
        assert mode in ('master', 'film', 'sstv', 'tv')
        pattern = rf'    static let {mode}: \[Path\] = \[.*?\n    \]'
        source, count = re.subn(pattern, lambda _: native_variant(mode), source, flags=re.S)
        assert count == 1, f'Expected one native variant for {mode}'
    target.write_text(source)
