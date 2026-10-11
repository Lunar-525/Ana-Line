import SwiftUI
import AppKit

/// One glass surface behind the workspace, independent of frame telemetry.
struct WorkspaceGlassBackground: View {
    var body: some View {
        Group {
            if #available(macOS 26.0, *) {
                Rectangle()
                    .fill(.clear)
                    .glassEffect(.regular.tint(.black.opacity(0.12)), in: Rectangle())
                    .background(WorkspaceWindowBackdrop(frosted: false))
            } else {
                WorkspaceWindowBackdrop(frosted: true)
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

private struct WorkspaceWindowBackdrop: NSViewRepresentable {
    let frosted: Bool

    func makeNSView(context: Context) -> WorkspaceBackdropView {
        let view = WorkspaceBackdropView()
        if frosted {
            let material = NSVisualEffectView()
            material.material = .underWindowBackground
            material.blendingMode = .behindWindow
            material.state = .followsWindowActiveState
            material.autoresizingMask = [.width, .height]
            view.addSubview(material)
        }
        return view
    }

    func updateNSView(_ view: WorkspaceBackdropView, context: Context) {}
}

private final class WorkspaceBackdropView: NSView {
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        // Let the system material sample the desktop instead of an opaque
        // window fill beneath the SwiftUI hosting view.
        window?.isOpaque = false
        window?.backgroundColor = .clear
        window?.isMovableByWindowBackground = true
    }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

struct WorkspaceHeaderDrag: ViewModifier {
    @ViewBuilder
    func body(content: Content) -> some View {
        if #available(macOS 15.0, *) {
            content.gesture(WindowDragGesture())
        } else {
            content
        }
    }
}
