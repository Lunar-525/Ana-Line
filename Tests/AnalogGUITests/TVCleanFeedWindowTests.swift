import XCTest
import SwiftUI
import AppKit
@testable import AnalogGUI

final class TVCleanFeedWindowTests: XCTestCase {
    @MainActor
    func testCleanFeedWindowCanBeClosedAndReopened() throws {
        _ = NSApplication.shared
        let defaults = UserDefaults.standard
        let previous = defaults.object(forKey: "tvCRTEnabled")
        defaults.set(true, forKey: "tvCRTEnabled")
        defer {
            if let previous { defaults.set(previous, forKey: "tvCRTEnabled") }
            else { defaults.removeObject(forKey: "tvCRTEnabled") }
        }

        let model = PreviewModel()
        let space = try XCTUnwrap(CGColorSpace(name: CGColorSpace.sRGB))
        let bitmap = try XCTUnwrap(CGContext(data: nil, width: 64, height: 48,
            bitsPerComponent: 8, bytesPerRow: 64*4, space: space,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        bitmap.setFillColor(CGColor(red: 0.8, green: 0.2, blue: 0.3, alpha: 1))
        bitmap.fill(CGRect(x: 0, y: 0, width: 64, height: 48))
        model.tvPreviewState.processed = NSImage(cgImage: try XCTUnwrap(bitmap.makeImage()),
            size: NSSize(width: 64, height: 48))

        let controller = TVCleanFeedWindowController()
        controller.show(model: model)
        RunLoop.main.run(until: Date().addingTimeInterval(0.4))
        let first = try XCTUnwrap(controller.window)
        XCTAssertTrue(first.isVisible)

        controller.close()
        RunLoop.main.run(until: Date().addingTimeInterval(0.2))
        XCTAssertNil(controller.window)

        controller.show(model: model)
        RunLoop.main.run(until: Date().addingTimeInterval(0.4))
        let second = try XCTUnwrap(controller.window)
        XCTAssertTrue(second.isVisible)
        XCTAssertFalse(second === first)
        controller.close()
    }
}
