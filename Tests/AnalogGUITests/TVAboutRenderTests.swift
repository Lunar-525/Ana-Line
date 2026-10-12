import XCTest
import SwiftUI
import AppKit
@testable import AnalogGUI

/// Renders the About panel to a PNG so the artwork can be reviewed without
/// launching the app. Not a correctness test: it fails only if rendering does.
final class TVAboutRenderTests: XCTestCase {
    @MainActor
    func testRenderAboutPanel() throws {
        let view = AnaLineAboutView()
            .environment(\.colorScheme, .dark)
            .background(Color(red: 0.13, green: 0.13, blue: 0.14))
        let renderer = ImageRenderer(content: view)
        renderer.scale = 2
        guard let image = renderer.cgImage else { return XCTFail("render failed") }
        let rep = NSBitmapImageRep(cgImage: image)
        let data = try XCTUnwrap(rep.representation(using: .png, properties: [:]))
        let url = URL(fileURLWithPath: "/tmp/about-panel.png")
        try data.write(to: url)
        print("ABOUT_RENDER \(image.width)x\(image.height) -> \(url.path)")
        // The mark must actually be present: sample the lower half for ink that is
        // much brighter than the panel background.
        let rep2 = NSBitmapImageRep(data: data)!
        var bright = 0
        for y in (rep2.pixelsHigh/2)..<rep2.pixelsHigh {
            for x in 0..<rep2.pixelsWide {
                if let c = rep2.colorAt(x: x, y: y), c.brightnessComponent > 0.6 { bright += 1 }
            }
        }
        print("ABOUT_BRIGHT_PIXELS \(bright)")
        XCTAssertGreaterThan(bright, 500, "The AsyncAlter mark must be visible in the panel")

        // The mark on its own, for a shape comparison against the source artwork.
        let markOnly = AsyncAlterMark(width: 210)
            .environment(\.colorScheme, .dark)
            .background(Color(red: 0.13, green: 0.13, blue: 0.14))
        let markRenderer = ImageRenderer(content: markOnly)
        markRenderer.scale = 2
        if let markImage = markRenderer.cgImage {
            let markRep = NSBitmapImageRep(cgImage: markImage)
            if let markData = markRep.representation(using: .png, properties: [:]) {
                try markData.write(to: URL(fileURLWithPath: "/tmp/about-mark.png"))
                print("ABOUT_MARK \(markImage.width)x\(markImage.height)")
            }
        }
    }
}
