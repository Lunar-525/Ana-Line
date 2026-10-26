import XCTest
import SwiftUI
import AppKit
@testable import AnalogGUI

final class TVCleanFeedTests: XCTestCase {
    /// The clean feed must be the processed image only: no comparison labels,
    /// no split, no OSD. Render it offscreen and inspect the visible pixels.
    @MainActor
    func testCleanFeedRendersOnlyProcessedImage() throws {
        let defaults = UserDefaults.standard
        let previous = defaults.object(forKey: "tvCRTEnabled")
        defaults.set(false, forKey: "tvCRTEnabled")
        defer {
            if let previous { defaults.set(previous, forKey: "tvCRTEnabled") }
            else { defaults.removeObject(forKey: "tvCRTEnabled") }
        }

        let model = PreviewModel()
        let space = try XCTUnwrap(CGColorSpace(name: CGColorSpace.sRGB))
        let bitmap = try XCTUnwrap(CGContext(data: nil, width: 8, height: 4,
            bitsPerComponent: 8, bytesPerRow: 32, space: space,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        bitmap.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        bitmap.fill(CGRect(x: 0, y: 0, width: 8, height: 4))
        let cg = try XCTUnwrap(bitmap.makeImage())
        model.tvPreviewState.processed = NSImage(cgImage: cg, size: NSSize(width: 8, height: 4))

        let view = TVCleanFeedView(model: model).frame(width: 320, height: 240)
        let renderer = ImageRenderer(content: view)
        renderer.scale = 1
        let image = try XCTUnwrap(renderer.cgImage)
        let rep = try XCTUnwrap(NSBitmapImageRep(cgImage: image))

        let centre = try XCTUnwrap(rep.colorAt(x: rep.pixelsWide/2, y: rep.pixelsHigh/2)?
            .usingColorSpace(.deviceRGB))
        let corner = try XCTUnwrap(rep.colorAt(x: 2, y: 2)?
            .usingColorSpace(.deviceRGB))
        XCTAssertGreaterThan(centre.redComponent, 0.8)
        XCTAssertGreaterThan(centre.greenComponent, 0.8)
        XCTAssertGreaterThan(centre.blueComponent, 0.8)
        XCTAssertLessThan(corner.redComponent, 0.1)
        XCTAssertLessThan(corner.greenComponent, 0.1)
        XCTAssertLessThan(corner.blueComponent, 0.1)
    }
}
