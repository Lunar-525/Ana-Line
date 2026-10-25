import XCTest
import SwiftUI
import AppKit
@testable import AnalogGUI

/// Window transparency is off for now. These checks pin the default and the
/// opaque fallback, so bringing the glass back has to be a deliberate edit or an
/// explicit `ANALINE_GLASS=1` rather than something that slips through.
final class WorkspaceGlassTests: XCTestCase {
    private var optedIn: Bool {
        ProcessInfo.processInfo.environment["ANALINE_GLASS"] == "1"
    }

    @MainActor
    func testTransparencyIsOffByDefault() throws {
        try XCTSkipIf(optedIn, "ANALINE_GLASS=1 opted into the glass for this run")
        XCTAssertFalse(WorkspaceGlass.isEnabled,
                       "the workspace glass is off by default; ANALINE_GLASS=1 brings it back")
    }

    /// The fallback the opaque workspace is read against: uniform, fully opaque
    /// black. If the glass is re-enabled this branch goes away and the alpha
    /// check below is what notices.
    @MainActor
    func testOpaqueBackgroundRendersUniformBlack() throws {
        try XCTSkipIf(optedIn, "ANALINE_GLASS=1 opted into the glass for this run")
        let view = WorkspaceGlassBackground().frame(width: 200, height: 120)
        let renderer = ImageRenderer(content: view)
        renderer.scale = 1
        let image = try XCTUnwrap(renderer.cgImage, "render failed")
        let rep = NSBitmapImageRep(cgImage: image)
        print("WORKSPACE_GLASS image=\(image.width)x\(image.height)")

        var sampled = 0
        for y in stride(from: 1, to: rep.pixelsHigh, by: 7) {
            for x in stride(from: 1, to: rep.pixelsWide, by: 7) {
                let c = try XCTUnwrap(rep.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB))
                XCTAssertEqual(c.redComponent, 0, accuracy: 0.01)
                XCTAssertEqual(c.greenComponent, 0, accuracy: 0.01)
                XCTAssertEqual(c.blueComponent, 0, accuracy: 0.01)
                XCTAssertEqual(c.alphaComponent, 1, accuracy: 0.01,
                               "the workspace background must be opaque, not see-through")
                sampled += 1
            }
        }
        print("WORKSPACE_GLASS sampled=\(sampled)")
        XCTAssertGreaterThan(sampled, 100, "the sample grid must actually cover the surface")
    }
}
