import SwiftUI
import AppKit

/// Whether the workspace draws a translucent surface behind its content.
///
/// Off by default: the glass needs `window.isOpaque == false` so a system
/// material can sample the desktop, and that is what made AppKit rebuild the
/// window's opaque-region map on every display cycle — the reason the header
/// carries its own native drag surface. With it off the window supplies its own
/// black fill and nothing behind it is sampled. `ANALINE_GLASS=1` brings the
/// glass back without a recompile, the same A/B pattern as `ANALINE_DRAG`.
enum WorkspaceGlass {
    static let isEnabled = ProcessInfo.processInfo.environment["ANALINE_GLASS"] == "1"
}

/// One surface behind the workspace, independent of frame telemetry. Opaque
/// black unless `WorkspaceGlass.isEnabled`.
struct WorkspaceGlassBackground: View {
    var body: some View {
        Group {
            if !WorkspaceGlass.isEnabled {
                // Opaque workspace. The backdrop view is still installed so the
                // window itself stops being transparent; the fill below is what
                // the content is then read against.
                Color.black
                    .background(WorkspaceWindowBackdrop(frosted: false, opaque: true))
            } else if #available(macOS 26.0, *) {
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
    /// Give the window its own opaque fill instead of letting the surface
    /// sample whatever is behind it.
    var opaque = false

    func makeNSView(context: Context) -> WorkspaceBackdropView {
        let view = WorkspaceBackdropView()
        view.opaqueWindow = opaque
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
    var opaqueWindow = false

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if opaqueWindow {
            // Transparency is off, so the window paints its own black rather
            // than letting a system material sample the desktop.
            window?.isOpaque = true
            window?.backgroundColor = .black
        } else {
            // Let the system material sample the desktop instead of an opaque
            // window fill beneath the SwiftUI hosting view.
            window?.isOpaque = false
            window?.backgroundColor = .clear
        }
        // Dragging is declared, never computed. isMovableByWindowBackground has
        // to stay off: whenever the window is not opaque it makes AppKit rebuild
        // the window's opaque-region map by walking the whole SwiftUI responder
        // tree on every display cycle (measured at 40% of the main thread on
        // the Radio page, ~87% process CPU). Instead the places that may move
        // the window opt in with `WindowDragRegion` below.
        window?.isMovableByWindowBackground = false
    }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

/// Which mechanism moves the window. Selected once at launch so a single build
/// can be A/B/C compared without recompiling.
enum WindowDragMechanism {
    case gesture, native, none
    static let current: WindowDragMechanism = {
        switch ProcessInfo.processInfo.environment["ANALINE_DRAG"] {
        case "native": return .native
        case "none": return .none
        case "gesture": return .gesture
        default: return .native
        }
    }()
}

/// Optional SwiftUI drag path retained for controlled profiling comparisons.
/// Production uses the native surface in the header spacer.
///
/// `WindowDragGesture` asks SwiftUI for a window drag. It still has AppKit work
/// out which regions of the view tree would *prevent* a drag, which is what
/// `_regionForOpaqueViewsBlockingDraggableFrame` walks the responder tree for.
struct WindowDragRegion: ViewModifier {
    var mechanism: WindowDragMechanism = .current
    @ViewBuilder
    func body(content: Content) -> some View {
        if mechanism == .gesture, #available(macOS 15.0, *) {
            content.gesture(WindowDragGesture())
        } else {
            content
        }
    }
}

/// A region that moves the window by handing the mouse-down straight
/// to `NSWindow.performDrag`, without installing a SwiftUI WindowDragGesture.
/// The surface occupies only the header's blank spacer; buttons keep their clicks.
struct WindowDragSurface: NSViewRepresentable {
    func makeNSView(context: Context) -> Surface { Surface() }
    func updateNSView(_ view: Surface, context: Context) {}
    final class Surface: NSView {
        override func mouseDown(with event: NSEvent) {
            window?.performDrag(with: event)
        }
    }
}

/// The blank stretch of the header: a Spacer when dragging is not native, the
/// explicit drag surface when it is. Same layout either way.
struct WindowDragSpacer: View {
    var mechanism: WindowDragMechanism = .current
    var body: some View {
        if mechanism == .native {
            WindowDragSurface().frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            Spacer()
        }
    }
}

@available(*, deprecated, renamed: "WindowDragRegion")
typealias WorkspaceHeaderDrag = WindowDragRegion
