import XCTest
import SwiftUI
import AppKit
@testable import AnalogGUI

final class TVCRTMaskGlyphTests: XCTestCase {
    @MainActor
    func testChooserIncludesDescriptionsAndCanRenderSevenRows() throws {
        XCTAssertEqual(TVCRTMaskType.allCases.count, 7)
        XCTAssertEqual(Set(TVCRTMaskType.allCases.map(\.title)).count, 7)
        for type in TVCRTMaskType.allCases { XCTAssertFalse(type.detail.isEmpty) }
        let renderer = ImageRenderer(content: TVServicePanel(title: "CRT display") {
            TVCRTMaskChooser(selection: .constant(4))
        })
        renderer.scale = 2
        let cg = try XCTUnwrap(renderer.cgImage)
        XCTAssertGreaterThan(cg.height, 400)
        // Optional visual QA output; regular test runs do not save artifacts.
        if let path = ProcessInfo.processInfo.environment["ANALINE_CRT_CHOOSER_PREVIEW"] {
            let png = try XCTUnwrap(NSBitmapImageRep(cgImage: cg).representation(using: .png, properties: [:]))
            try png.write(to: URL(fileURLWithPath: path))
        }
    }

    @MainActor
    func testEveryMaskGlyphDrawsThreePrimaries() throws {
        for type in TVCRTMaskType.allCases {
            let renderer = ImageRenderer(content: TVCRTMaskGlyph(type: type)
                .frame(width: 46, height: 26))
            renderer.scale = 4
            let image = try XCTUnwrap(renderer.cgImage)
            let rep = try XCTUnwrap(NSBitmapImageRep(cgImage: image))
            var counts = [0, 0, 0]

            for y in 0..<rep.pixelsHigh {
                for x in 0..<rep.pixelsWide {
                    guard let c = rep.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB) else { continue }
                    let r = c.redComponent, g = c.greenComponent, b = c.blueComponent
                    if r > 0.45 && r > g * 1.5 && r > b * 1.5 { counts[0] += 1 }
                    if g > 0.45 && g > r * 1.5 && g > b * 1.5 { counts[1] += 1 }
                    if b > 0.45 && b > r * 1.5 && b > g * 1.2 { counts[2] += 1 }
                }
            }

            XCTAssertGreaterThan(counts[0], 4, "\(type.title) needs red phosphor")
            XCTAssertGreaterThan(counts[1], 4, "\(type.title) needs green phosphor")
            XCTAssertGreaterThan(counts[2], 4, "\(type.title) needs blue phosphor")
        }
    }
}
