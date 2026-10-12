import XCTest
import SwiftUI
import AppKit
@testable import AnalogGUI

/// Renders the workspace header chrome to a PNG so the tape can be reviewed
/// without launching the app, and checks that the pattern and its fade are
/// actually drawn rather than silently empty.
final class HeaderChromeRenderTests: XCTestCase {
    @MainActor
    func testRenderHazardTapeAndBuildStamp() throws {
        let band = HazardStripeBand()
            .frame(width: 900)
            .background(Color.black)
        let renderer = ImageRenderer(content: band)
        renderer.scale = 2
        let image = try XCTUnwrap(renderer.cgImage, "render failed")
        let data = try XCTUnwrap(NSBitmapImageRep(cgImage: image)
            .representation(using: .png, properties: [:]))
        let url = URL(fileURLWithPath: "/tmp/header-tape.png")
        try data.write(to: url)
        print("HEADER_TAPE \(image.width)x\(image.height) -> \(url.path)")

        let rep = try XCTUnwrap(NSBitmapImageRep(data: data))
        // Antialiased edges blend toward black, so only clearly yellow pixels count.
        func isYellow(_ x: Int, _ y: Int) -> Bool {
            guard let c = rep.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB) else { return false }
            return c.redComponent > 0.7 && c.greenComponent > 0.5 && c.blueComponent < 0.35
        }
        func scan(_ y: Int) -> [Bool] { (0..<rep.pixelsWide).map { isYellow($0, y) } }

        let top = scan(1).filter { $0 }.count
        let bottom = scan(rep.pixelsHigh - 2).filter { $0 }.count
        print("HEADER_TAPE_YELLOW top=\(top) bottom=\(bottom)")
        XCTAssertGreaterThan(top, rep.pixelsWide/4, "the tape must be drawn at the top edge")
        XCTAssertEqual(bottom, 0, "the tape must fade out before the bottom edge")

        // Yellow and black stripes must share the tape evenly. Measuring the run
        // lengths catches a pitch that crowds one colour out.
        var runs: [(yellow: Bool, length: Int)] = []
        for yellow in scan(1) {
            if let last = runs.last, last.yellow == yellow { runs[runs.count - 1].length += 1 }
            else { runs.append((yellow, 1)) }
        }
        let whole = runs.dropFirst().dropLast()
        let yellowRun = whole.filter(\.yellow).map(\.length).reduce(0, +)
        let blackRun = whole.filter { !$0.yellow }.map(\.length).reduce(0, +)
        let duty = Double(yellowRun)/Double(yellowRun + blackRun)
        let stripeCount = whole.filter(\.yellow).count
        print("HEADER_TAPE_DUTY \(String(format: "%.1f%%", duty*100)) "
            + "stripe=\(Double(yellowRun)/Double(stripeCount)/2)pt")
        XCTAssertEqual(duty, 0.5, accuracy: 0.06, "yellow and black stripes must share the tape evenly")
        XCTAssertGreaterThanOrEqual(stripeCount, 8, "the tape must read as repeated stripes")

        let stamp = EarlyBuildStamp()
            .padding(12)
            .background(Color.black)
        let stampRenderer = ImageRenderer(content: stamp)
        stampRenderer.scale = 2
        if let stampImage = stampRenderer.cgImage,
           let stampData = NSBitmapImageRep(cgImage: stampImage)
            .representation(using: .png, properties: [:]) {
            try stampData.write(to: URL(fileURLWithPath: "/tmp/header-build-stamp.png"))
            print("HEADER_STAMP \(stampImage.width)x\(stampImage.height)")
        }
    }

    /// The tape is chrome, not content: it has to reach the window's top edge and
    /// both side edges, which depends on where in the padding chain it is hung.
    @MainActor
    func testHeaderTapeReachesWindowEdges() throws {
        // AnaLine's workspace is dark, but an offscreen render has no window to
        // inherit that from, and Color.primary would come out black on the black
        // header. Asking for it explicitly keeps the wordmark visible to the
        // clearance check below.
        let view = ContentView(languageStore: LanguageStore())
            .environment(\.colorScheme, .dark)
            .frame(width: 1000, height: 760)
        let renderer = ImageRenderer(content: view)
        renderer.scale = 1
        let image = try XCTUnwrap(renderer.cgImage, "render failed")
        let rep = NSBitmapImageRep(cgImage: image)
        try XCTUnwrap(rep.representation(using: .png, properties: [:]))
            .write(to: URL(fileURLWithPath: "/tmp/header-full.png"))

        func isYellow(_ x: Int, _ y: Int) -> Bool {
            guard let c = rep.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB) else { return false }
            return c.redComponent > 0.7 && c.greenComponent > 0.5 && c.blueComponent < 0.35
        }
        let topmost = (0..<rep.pixelsHigh).first { y in (0..<rep.pixelsWide).contains { isYellow($0, y) } }
        let row = topmost.map { y in (0..<rep.pixelsWide).filter { isYellow($0, y) } } ?? []
        // A 45° pattern leaves gaps, so a stripe may not land on the very last
        // pixel. The gutter this guards against is 20pt wide, and a gap is only
        // ~13pt, so yellow anywhere in the outermost 20pt proves the tape bleeds
        // to the edge.
        let gutter = 20
        print("HEADER_FULL \(rep.pixelsWide)x\(rep.pixelsHigh) "
            + "yellow=\(row.count) left=\(row.first ?? -1) right=\(row.last ?? -1) top=\(topmost ?? -1)")
        XCTAssertEqual(topmost, 0, "the tape must sit on the window's top edge")
        XCTAssertTrue(row.contains { $0 < gutter }, "the tape must reach the left window edge")
        XCTAssertTrue(row.contains { $0 >= rep.pixelsWide - gutter }, "the tape must reach the right window edge")

        // The tape is decoration behind chrome; the cream wordmark has to stay
        // clear of it or the logo loses contrast.
        func isCream(_ x: Int, _ y: Int) -> Bool {
            guard let c = rep.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB) else { return false }
            return c.redComponent > 0.85 && c.greenComponent > 0.85 && c.blueComponent > 0.8
        }
        let wordmarkTop = (0..<rep.pixelsHigh).first { y in
            (0..<(rep.pixelsWide/2)).contains { isCream($0, y) }
        }
        print("HEADER_FULL_WORDMARK_TOP \(wordmarkTop ?? -1) tape=\(HazardStripeBand().height)")
        XCTAssertGreaterThanOrEqual(wordmarkTop ?? 0, Int(HazardStripeBand().height),
                                    "the tape must not cover the wordmark")
    }
}
