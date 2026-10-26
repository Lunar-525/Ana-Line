import SwiftUI
import AppKit

/// AppKit owns the clean-feed window lifecycle. SwiftUI's single-instance
/// `Window` scene can keep stale content after a close/reopen; recreating an
/// `NSWindow` and its hosting view each time is deterministic.
@MainActor
final class TVCleanFeedWindowController: NSWindowController, NSWindowDelegate {
    static let shared = TVCleanFeedWindowController()
    private var hostingView: NSHostingView<TVCleanFeedView>?

    init() {
        super.init(window: nil)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func show(model: PreviewModel) {
        if let window, window.isVisible {
            window.makeKeyAndOrderFront(nil)
            return
        }
        if let window {
            window.delegate = nil
            window.close()
            self.window = nil
            hostingView = nil
        }

        let host = NSHostingView(rootView: TVCleanFeedView(model: model))
        host.autoresizingMask = [.width, .height]
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 960, height: 720),
            styleMask: [.titled, .closable, .resizable, .miniaturizable],
            backing: .buffered, defer: false)
        window.title = L("Clean Feed")
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.appearance = NSAppearance(named: .darkAqua)
        window.backgroundColor = .black
        window.minSize = NSSize(width: 480, height: 360)
        window.contentView = host
        window.center()
        self.window = window
        hostingView = host
        showWindow(nil)
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func windowWillClose(_ notification: Notification) {
        // Release the SwiftUI/Metal graph so the next open builds a fresh one.
        window?.contentView = nil
        hostingView = nil
        window = nil
    }
}
