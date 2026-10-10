import XCTest
import SwiftUI
import AppKit
@testable import AnalogGUI

@MainActor
final class TVNoSignalTests: XCTestCase {
    func testInstalledVCROSDFontIsUsed() throws {
        let installed = NSFontManager.shared.availableFonts.filter {
            $0.localizedCaseInsensitiveContains("VCR") && $0.localizedCaseInsensitiveContains("OSD")
        }
        guard !installed.isEmpty else { throw XCTSkip("VCR OSD Mono is not installed on this test host") }
        let name = try XCTUnwrap(TVOSDFont.name)
        XCTAssertTrue(installed.contains(name))
        XCTAssertNotNil(NSFont(name: name,size: 24))
        print("OSD font:",name)
    }

    func testNativeNoInputAndPreparingScreens() async throws {
        guard ProcessInfo.processInfo.environment["ANALINE_CAPTURE_NO_SIGNAL"] == "1" else {
            throw XCTSkip("Opt-in: opens an owned native window to verify idle snow and OSD")
        }
        _ = NSApplication.shared
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let window = NSWindow(contentRect: NSRect(x: 60,y: 60,width: 640,height: 480),
            styleMask: [.titled,.closable],backing: .buffered,defer: false)
        window.isReleasedWhenClosed = false
        defer { window.orderOut(nil); window.contentView = nil; window.close() }
        let model = PreviewModel(); model.tool = .tv
        // A previous film-mode source must not replace the no-video snow.
        let still = NSImage(size: NSSize(width: 20,height: 20))
        still.lockFocus(); NSColor.magenta.setFill(); NSRect(x: 0,y: 0,width: 20,height: 20).fill(); still.unlockFocus()
        model.original = still; model.processed = still
        window.contentView = NSHostingView(rootView: TVPlayerView(model: model))
        window.orderFront(nil)
        try await Task.sleep(for: .milliseconds(200))
        let view = try XCTUnwrap(window.contentView)
        func capture(_ filename: String) throws -> Data {
            let bitmap = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
            view.cacheDisplay(in: view.bounds,to: bitmap)
            let png = try XCTUnwrap(bitmap.representation(using: .png,properties: [:]))
            try png.write(to: root.appendingPathComponent("build/\(filename).png"))
            return png
        }
        let first = try capture("TV-no-input-pal")
        try await Task.sleep(for: .milliseconds(160))
        let second = try capture("TV-no-input-pal-moving")
        if !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            XCTAssertNotEqual(first,second,"Idle snow must animate without input or app state changes")
        }
        model.tvStandard = .ntsc
        try await Task.sleep(for: .milliseconds(120))
        _ = try capture("TV-no-input-ntsc")
        window.contentView = NSHostingView(rootView: TVNoSignalView(standard: .ntsc,preparing: true).frame(width: 640,height: 480))
        try await Task.sleep(for: .milliseconds(120))
        let preparing = try XCTUnwrap(window.contentView)
        let bitmap = try XCTUnwrap(preparing.bitmapImageRepForCachingDisplay(in: preparing.bounds))
        preparing.cacheDisplay(in: preparing.bounds,to: bitmap)
        try XCTUnwrap(bitmap.representation(using: .png,properties: [:])).write(to: root.appendingPathComponent("build/TV-no-input-preparing.png"))
    }
}
