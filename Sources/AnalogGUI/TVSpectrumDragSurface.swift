import SwiftUI
import AppKit

enum TVSpectrumDragPart { case tuning, lowerEdge, upperEdge }

extension TVSpectrumTuning {
    func dragged(_ part: TVSpectrumDragPart,by deltaHz: Double) -> Self {
        guard deltaHz.isFinite else { return self }
        switch part {
        case .tuning:
            return Self(offsetHz: min(1_500_000,max(-1_500_000,offsetHz+deltaHz)),
                bandwidthHz: bandwidthHz,carrierHz: carrierHz)
        case .upperEdge:
            return Self(offsetHz: offsetHz,bandwidthHz: min(10_000_000,max(1_000_000,bandwidthHz+deltaHz)),
                carrierHz: carrierHz)
        case .lowerEdge:
            // The lower IF edge is fixed at -1.25 MHz relative to tuning.
            // Resize from the left by moving tuning too, anchoring the right edge.
            let lower = max(-1_500_000-offsetHz,bandwidthHz-10_000_000)
            let upper = min(1_500_000-offsetHz,bandwidthHz-1_000_000)
            let delta = min(upper,max(lower,deltaHz))
            return Self(offsetHz: offsetHz+delta,bandwidthHz: bandwidthHz-delta,carrierHz: carrierHz)
        }
    }
}

/// A transparent, local hit surface. Only the marker and bracket take mouse
/// input; the rest of the instrument remains available to its scroll container.
struct TVSpectrumDragSurface: NSViewRepresentable {
    let tuning: TVSpectrumTuning
    let centerHz: Double, sampleRate: Double
    let onChange: (TVSpectrumTuning) -> Void

    final class Surface: NSView {
        var tuning = TVSpectrumTuning(offsetHz: 0,bandwidthHz: 8_000_000,carrierHz: 0)
        var centerHz = 0.0, sampleRate = 16_000_000.0
        var onChange: ((TVSpectrumTuning) -> Void)?
        private var dragPart: TVSpectrumDragPart?
        private var previousX: CGFloat = 0
        private var dragHzPerPoint = 0.0
        override var isFlipped: Bool { true }
        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
        private func x(_ frequency: Double) -> CGFloat {
            CGFloat((frequency-centerHz)/sampleRate+0.5)*bounds.width
        }
        private var targets: [(TVSpectrumDragPart,NSRect)] {
            guard bounds.width > 0, sampleRate > 0 else { return [] }
            var result: [(TVSpectrumDragPart,NSRect)] = []
            for (part,frequency) in [(TVSpectrumDragPart.lowerEdge,tuning.lowerHz),(.upperEdge,tuning.upperHz)] {
                let edge = x(frequency)
                if edge >= 0 && edge <= bounds.width {
                    result.append((part,NSRect(x: edge-6,y: 0,width: 12,height: 20)))
                }
            }
            let marker = x(tuning.indicatorHz)
            if marker >= 0 && marker <= bounds.width {
                result.append((.tuning,NSRect(x: marker-6,y: 0,width: 12,height: bounds.height)))
            }
            let left = max(0,x(tuning.lowerHz)), right = min(bounds.width,x(tuning.upperHz))
            if right > left {
                result.append((.tuning,NSRect(x: left,y: 0,width: right-left,height: 14)))
            }
            return result
        }
        func part(at point: NSPoint) -> TVSpectrumDragPart? {
            guard bounds.contains(point) else { return nil }
            return targets.first { $0.1.contains(point) }?.0
        }
        override func hitTest(_ point: NSPoint) -> NSView? {
            part(at: convert(point,from: superview)) == nil ? nil : self
        }
        override func resetCursorRects() {
            // Add the broad bracket first, then the more precise edge targets.
            for (part,rect) in targets.reversed() {
                addCursorRect(rect.intersection(bounds),cursor: part == .tuning ? .openHand : .resizeLeftRight)
            }
        }
        override func mouseDown(with event: NSEvent) {
            dragPart = part(at: convert(event.locationInWindow,from: nil))
            previousX = event.locationInWindow.x
            dragHzPerPoint = sampleRate/Double(max(1,bounds.width))
        }
        override func mouseDragged(with event: NSEvent) {
            guard let dragPart else { return }
            let delta = Double(event.locationInWindow.x-previousX)*dragHzPerPoint
                * (event.modifierFlags.contains(.shift) ? 0.1 : 1)
            previousX = event.locationInWindow.x
            tuning = tuning.dragged(dragPart,by: delta)
            onChange?(tuning)
            window?.invalidateCursorRects(for: self)
        }
        override func mouseUp(with event: NSEvent) { dragPart = nil }
        func refresh(tuning: TVSpectrumTuning,centerHz: Double,sampleRate: Double) {
            if self.centerHz != centerHz || self.sampleRate != sampleRate { dragPart = nil }
            self.tuning = tuning; self.centerHz = centerHz; self.sampleRate = sampleRate
            window?.invalidateCursorRects(for: self)
        }
    }
    func makeNSView(context: Context) -> Surface { Surface() }
    func updateNSView(_ view: Surface,context: Context) {
        view.onChange = onChange
        view.refresh(tuning: tuning,centerHz: centerHz,sampleRate: sampleRate)
        view.toolTip = L("Drag the marker or bracket to tune · drag either edge to resize IF · Shift for fine control. The left edge also adjusts tuning to keep the right edge fixed.")
    }
}
