import SwiftUI
import AppKit
import AnalogCore

struct TVRotaryParameter: View {
    let name: String
    @Binding var value: Float
    let range: ClosedRange<Float>
    let initial: Float
    let step: Float
    var unit = ""
    var digits = 1
    var percent = false
    var active = true
    var horizontal = false
    var body: some View {
        VStack(spacing: 2) {
            if horizontal {
                HStack(spacing: 3) {
                    knob
                    VStack(spacing: 2) {
                        readout
                        Text(percent ? "%" : unit).font(.system(size: 7)).foregroundStyle(.white.opacity(0.55))
                    }
                }
            } else { knob }
            Text(L(name)).font(.system(size: 8,weight: .medium)).lineLimit(1).minimumScaleFactor(0.75)
            if !horizontal {
                HStack(spacing: 1) {
                    readout
                    Text(percent ? "%" : unit).foregroundStyle(.white.opacity(0.55))
                }.font(.system(size: 9).monospacedDigit()).fixedSize()
            }
        }.foregroundStyle(.white.opacity(active ? 0.9 : 0.35))
            .frame(maxWidth: .infinity).disabled(!active)
            .help(L("Scroll or drag to adjust · Shift for fine control · double-click to reset"))
    }
    private var knob: some View {
        TVNativeKnob(value: $value,range: range,initial: initial,step: step,label: L(name),enabled: active)
            .frame(width: 36,height: 36)
    }
    private var readout: some View {
        TVSegmentValue(value: $value,range: range,digits: digits,percent: percent,
            label: "\(L(name)) · \(percent ? "%" : unit)")
    }
}

/// Native hit testing keeps scroll input local to the dial. No global event
/// monitor is installed; inactive dials hand scrolling back to their parent.
struct TVNativeKnob: NSViewRepresentable {
    @Environment(\.isEnabled) private var parentEnabled
    @Binding var value: Float
    let range: ClosedRange<Float>, initial: Float, step: Float
    let label: String
    var enabled = true
    final class Dial: NSControl {
        var position = 0.0 { didSet { needsDisplay = true } }
        var lower = 0.0, upper = 1.0, reset = 0.0, increment = 0.01
        private var dragY: CGFloat = 0
        private var wheelRemainder = 0.0
        override var acceptsFirstResponder: Bool { isEnabled }
        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
        override func hitTest(_ point: NSPoint) -> NSView? {
            let p = convert(point,from: superview)
            return hypot(p.x-bounds.midX,p.y-bounds.midY) <= min(bounds.width,bounds.height)/2 ? self : nil
        }
        func setPosition(_ next: Double) {
            guard next.isFinite, isEnabled else { return }
            let clipped = min(upper,max(lower,next))
            guard clipped != position else { return }
            position = clipped; sendAction(action,to: target)
        }
        override func mouseDown(with event: NSEvent) {
            guard isEnabled else { return }
            window?.makeFirstResponder(self)
            wheelRemainder = 0
            if event.clickCount == 2 { setPosition(reset) }
            dragY = event.locationInWindow.y
        }
        override func mouseDragged(with event: NSEvent) {
            let delta = event.locationInWindow.y-dragY
            dragY = event.locationInWindow.y
            setPosition(position+Double(delta)*(upper-lower)/180*(event.modifierFlags.contains(.shift) ? 0.1 : 1))
        }
        override func scrollWheel(with event: NSEvent) {
            guard isEnabled else { super.scrollWheel(with: event); return }
            guard event.momentumPhase.isEmpty else { return }
            if event.phase.contains(.began) { wheelRemainder = 0 }
            // macOS may translate Shift + a physical vertical wheel into X.
            let axis = event.scrollingDeltaY != 0 ? event.scrollingDeltaY :
                (event.modifierFlags.contains(.shift) ? event.scrollingDeltaX : 0)
            let delta = Double(axis)*(event.isDirectionInvertedFromDevice ? -1 : 1)
            wheelRemainder += delta/(event.hasPreciseScrollingDeltas ? 8 : 1)
            let steps = wheelRemainder.rounded(.towardZero)
            wheelRemainder -= steps
            setPosition(position+steps*increment*(event.modifierFlags.contains(.shift) ? 0.1 : 1))
        }
        override func keyDown(with event: NSEvent) {
            let fine = event.modifierFlags.contains(.shift) ? 0.1 : 1.0
            switch event.keyCode {
            case 126,124: setPosition(position+increment*fine)
            case 125,123: setPosition(position-increment*fine)
            case 115: setPosition(reset)
            default: super.keyDown(with: event)
            }
        }
        override func accessibilityValue() -> Any? { position }
        override func accessibilityPerformIncrement() -> Bool { setPosition(position+increment); return isEnabled }
        override func accessibilityPerformDecrement() -> Bool { setPosition(position-increment); return isEnabled }
        override func draw(_ dirtyRect: NSRect) {
            let centre = NSPoint(x: bounds.midX,y: bounds.midY), radius = min(bounds.width,bounds.height)/2
            let t = min(1,max(0,(position-lower)/(upper-lower)))
            NSGraphicsContext.saveGraphicsState()
            if !isEnabled { NSGraphicsContext.current?.cgContext.setAlpha(0.35) }
            for n in 0...10 {
                let a = (225-Double(n)*27)*Double.pi/180
                let p = NSBezierPath()
                p.move(to: NSPoint(x: centre.x+cos(a)*(radius-3),y: centre.y+sin(a)*(radius-3)))
                p.line(to: NSPoint(x: centre.x+cos(a)*radius,y: centre.y+sin(a)*radius))
                NSColor(white: 0.7,alpha: 1).setStroke(); p.lineWidth = n%5 == 0 ? 1.2 : 0.5; p.stroke()
            }
            let rim = NSBezierPath(ovalIn: bounds.insetBy(dx: 5,dy: 5))
            let shadow = NSShadow(); shadow.shadowColor = NSColor.black.withAlphaComponent(0.8)
            shadow.shadowBlurRadius = 3; shadow.shadowOffset = NSSize(width: 0,height: -2); shadow.set()
            NSColor(white: 0.18,alpha: 1).setFill(); rim.fill()
            NSShadow().set()
            NSGradient(starting: NSColor(white: 0.98,alpha: 1),ending: NSColor(white: 0.65,alpha: 1))?.draw(in: rim,angle: -90)
            NSColor(white: 0.55,alpha: 1).setStroke(); rim.lineWidth = 0.8; rim.stroke()
            let inset = NSBezierPath(ovalIn: bounds.insetBy(dx: 7,dy: 7))
            NSColor.white.withAlphaComponent(0.75).setStroke(); inset.lineWidth = 0.6; inset.stroke()
            let a = (225-270*t)*Double.pi/180, p = NSBezierPath()
            p.move(to: NSPoint(x: centre.x+cos(a)*radius*0.23,y: centre.y+sin(a)*radius*0.23))
            p.line(to: NSPoint(x: centre.x+cos(a)*(radius-8),y: centre.y+sin(a)*(radius-8)))
            NSColor(white: 0.08,alpha: 1).setStroke(); p.lineWidth = 2.2; p.lineCapStyle = .round; p.stroke()
            if window?.firstResponder === self {
                NSColor.systemYellow.withAlphaComponent(0.75).setStroke()
                let focus = NSBezierPath(ovalIn: bounds.insetBy(dx: 2,dy: 2)); focus.lineWidth = 0.7; focus.stroke()
            }
            NSGraphicsContext.restoreGraphicsState()
        }
    }
    @MainActor final class Coordinator: NSObject {
        var binding: Binding<Float>
        init(_ binding: Binding<Float>) { self.binding = binding }
        @objc func change(_ dial: Dial) { binding.wrappedValue = Float(dial.position) }
    }
    func makeCoordinator() -> Coordinator { Coordinator($value) }
    func makeNSView(context: Context) -> Dial {
        let d = Dial(); d.target = context.coordinator; d.action = #selector(Coordinator.change(_:))
        d.setAccessibilityRole(.slider)
        return d
    }
    func updateNSView(_ d: Dial,context: Context) {
        context.coordinator.binding = $value
        d.lower = Double(range.lowerBound); d.upper = Double(range.upperBound)
        d.reset = Double(initial); d.increment = Double(step); d.position = Double(value); d.isEnabled = enabled && parentEnabled
        d.setAccessibilityLabel(label)
        d.setAccessibilityHelp(L("Scroll or drag to adjust · Shift for fine control · double-click to reset"))
    }
}

struct TVRackSwitch: View {
    @Binding var enabled: Bool
    let label: String
    var body: some View {
        Button { enabled.toggle() } label: {
            VStack(spacing: 2) {
                Text("ACTIVE").foregroundStyle(.white.opacity(enabled ? 0.8 : 0.35))
                Canvas { context,size in
                    let socket = CGRect(x: 5,y: 0,width: 20,height: size.height)
                    context.fill(Path(socket.offsetBy(dx: 1,dy: 1)),with: .color(.black.opacity(0.65)))
                    context.fill(Path(socket),with: .color(.black))
                    context.stroke(Path(socket),with: .color(.white.opacity(0.22)),lineWidth: 0.6)
                    let topInset: CGFloat = enabled ? 2.5 : 1.2, bottomInset: CGFloat = enabled ? 1.2 : 2.5
                    let face = Path { p in
                        p.move(to: CGPoint(x: socket.minX+topInset,y: 2))
                        p.addLine(to: CGPoint(x: socket.maxX-topInset,y: 2))
                        p.addLine(to: CGPoint(x: socket.maxX-bottomInset,y: size.height-2))
                        p.addLine(to: CGPoint(x: socket.minX+bottomInset,y: size.height-2)); p.closeSubpath()
                    }
                    // The raised end catches the light; the pressed end recedes
                    // into its bezel. Silver matches the rotary knob's finish.
                    let silver = Gradient(colors: enabled ? [Color(white: 0.58),Color(white: 0.84),Color(white: 0.98)] :
                        [Color(white: 0.98),Color(white: 0.84),Color(white: 0.58)])
                    context.fill(face,with: .linearGradient(silver,startPoint: .zero,endPoint: CGPoint(x: 0,y: size.height)))
                    context.stroke(face,with: .color(.white.opacity(0.55)),lineWidth: 0.5)
                    let ridge = size.height*(enabled ? 0.37 : 0.63)
                    context.fill(Path(CGRect(x: socket.minX+2,y: ridge,width: socket.width-4,height: 1)),with: .color(.white.opacity(0.9)))
                    context.fill(Path(CGRect(x: socket.minX+2,y: ridge+1,width: socket.width-4,height: 0.6)),with: .color(.black.opacity(0.15)))
                }.frame(width: 30,height: 32).accessibilityHidden(true)
                Text("BYPASS").foregroundStyle(.white.opacity(enabled ? 0.35 : 0.8))
            }.font(.system(size: 6.5,weight: .medium,design: .monospaced))
        }.buttonStyle(.plain).accessibilityLabel(L(label)).accessibilityValue(enabled ? L("Active") : L("Bypass"))
            .help(L(label))
    }
}

enum TVRackFinish { case encoder, filter, transmitter }
struct TVRackHousing: View {
    let finish: TVRackFinish
    var body: some View {
        ZStack {
            Rectangle().fill(LinearGradient(colors: finish == .encoder ?
                [Color(red: 0.13,green: 0.4,blue: 0.43),Color(red: 0.035,green: 0.19,blue: 0.22),Color(red: 0.07,green: 0.29,blue: 0.32)] :
                [Color(white: 0.19),Color(white: 0.065),Color(white: 0.12)],
                                             startPoint: .topLeading,endPoint: .bottomTrailing))
            Canvas { context,size in
                let w = size.width, h = size.height
                for x in [CGFloat(5),w-15] {
                    context.fill(Path(CGRect(x: x,y: 2,width: 10,height: h-4)),with: .color(Color(white: 0.2)))
                    for y in [CGFloat(11),h-11] {
                        context.fill(Path(ellipseIn: CGRect(x: x+2,y: y-3,width: 6,height: 6)),with: .color(Color(white: 0.5)))
                        var slot = Path(); slot.move(to: CGPoint(x: x+3,y: y)); slot.addLine(to: CGPoint(x: x+7,y: y))
                        context.stroke(slot,with: .color(.black),lineWidth: 0.8)
                    }
                }
                if finish == .filter {
                    for y in [CGFloat(1),h-2] {
                        context.fill(Path(CGRect(x: 16,y: y,width: w-32,height: 1)),with: .color(Color(red: 0.74,green: 0.59,blue: 0.29)))
                    }
                }
            }
            Rectangle().stroke(.black,lineWidth: 2)
            Rectangle().stroke(.white.opacity(0.08),lineWidth: 0.6).padding(2)
        }.shadow(color: .black.opacity(0.65),radius: 4,y: 3).allowsHitTesting(false).accessibilityHidden(true)
    }
}

struct TVRackHeatsink: View {
    var body: some View {
        Canvas { context,size in
            context.fill(Path(CGRect(origin: .zero,size: size)),with: .color(Color(white: 0.035)))
            for x in stride(from: 3.0,to: size.width-2,by: 5) {
                let fin = CGRect(x: x,y: 1,width: 3,height: size.height-2)
                context.fill(Path(fin),with: .linearGradient(Gradient(colors: [Color(white: 0.3),Color(white: 0.07)]),
                    startPoint: CGPoint(x: x,y: 0),endPoint: CGPoint(x: x+3,y: 0)))
            }
        }.frame(height: 14).padding(.horizontal,18).allowsHitTesting(false).accessibilityHidden(true)
    }
}

struct TVRackHeader: View {
    let name: String, subtitle: String
    var gold = false
    @Binding var service: Bool
    var body: some View {
        HStack(spacing: 5) {
            Text(name).font(.system(size: 10,weight: .bold,design: .monospaced))
            Text(subtitle).font(.system(size: 7,design: .monospaced)).foregroundStyle(.white.opacity(0.4))
            Spacer(minLength: 2)
            Button { service.toggle() } label: { Image(systemName: "ellipsis").frame(width: 22,height: 16) }
                .buttonStyle(.plain).accessibilityLabel(L("Service adjustments"))
                .help(L("Service adjustments"))
        }.foregroundStyle(gold ? Color(red: 0.84,green: 0.7,blue: 0.4) : .white.opacity(0.9))
    }
}

struct TVServicePanel<Content: View>: View {
    let title: String
    @ViewBuilder var content: Content
    var body: some View {
        VStack(alignment: .leading,spacing: 12) {
            Text(L(title)).font(.system(size: 12,weight: .semibold))
            content
        }.padding(18).frame(width: 340).foregroundStyle(.white)
            .background(Color(white: 0.1)).environment(\.colorScheme,.dark)
    }
}
