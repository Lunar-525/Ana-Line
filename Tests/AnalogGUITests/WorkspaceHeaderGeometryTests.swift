import XCTest
import SwiftUI
import AppKit
@testable import AnalogGUI

/// The four mode pages render one shared `WorkspaceHeader`. These checks pin
/// that down numerically: the header used to be inline in `ContentView` with a
/// per-tool branch, so Radio came out 28 pt off its neighbours. Measuring the
/// real layout is what stops that from creeping back in unnoticed.
final class WorkspaceHeaderGeometryTests: XCTestCase {
    private let width: CGFloat = 1000
    /// `.padding(20)` on all sides plus the extra `.padding(.top, 10)`.
    private let headerPadding: CGFloat = 50
    /// `HStack(spacing: 16)` with four gaps: mode row, readout, drag spacer,
    /// progress, action.
    private let headerSpacing: CGFloat = 16

    @MainActor
    private func makeHeader(_ tool: EditingTool) -> (PreviewModel, AnyView) {
        let model = PreviewModel()
        model.tool = tool
        let view = AnyView(
            WorkspaceHeader(model: model)
                .frame(width: width)
                .environment(\.colorScheme, .dark)
        )
        return (model, view)
    }

    @MainActor
    private func layoutHeight(_ view: AnyView) -> CGFloat {
        let host = NSHostingView(rootView: view)
        host.frame = NSRect(x: 0, y: 0, width: width, height: 400)
        host.layoutSubtreeIfNeeded()
        return host.fittingSize.height
    }

    @MainActor
    private func fittingWidth(_ view: AnyView) -> CGFloat {
        let host = NSHostingView(rootView: view)
        host.frame = NSRect(x: 0, y: 0, width: 2000, height: 400)
        host.layoutSubtreeIfNeeded()
        return host.fittingSize.width
    }

    /// The whites of the mode switch: the pattern that has to land on the same
    /// row no matter which page is showing.
    private func topmostModeRow(_ rep: NSBitmapImageRep) -> Int? {
        let left = 300, right = min(700, rep.pixelsWide)
        for y in 0..<rep.pixelsHigh {
            for x in left..<right {
                guard let c = rep.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB) else { continue }
                if c.redComponent > 0.95 && c.greenComponent > 0.95 && c.blueComponent > 0.95 { return y }
            }
        }
        return nil
    }

    @MainActor
    func testEveryModeRendersTheSameHeaderHeight() throws {
        var heights: [(EditingTool, CGFloat)] = []
        for tool in EditingTool.allCases {
            let (_, view) = makeHeader(tool)
            heights.append((tool, layoutHeight(view)))
        }
        for (tool, height) in heights {
            print("WORKSPACE_HEADER_HEIGHT tool=\(tool.rawValue) height=\(height)")
        }
        let expected = WorkspaceHeader.contentHeight + headerPadding
        for (tool, height) in heights {
            XCTAssertEqual(height, expected, accuracy: 0.5,
                           "\(tool.rawValue) must render the shared header height")
        }
        XCTAssertEqual(Set(heights.map(\.1)).count, 1, "all four mode headers must be the same height")
    }

    @MainActor
    func testEveryModePlacesTheModeRowOnTheSameRow() throws {
        var tops: [(EditingTool, Int)] = []
        for tool in EditingTool.allCases {
            let (_, view) = makeHeader(tool)
            let renderer = ImageRenderer(content: view)
            renderer.scale = 1
            let image = try XCTUnwrap(renderer.cgImage, "render failed for \(tool.rawValue)")
            let rep = NSBitmapImageRep(cgImage: image)
            let top = try XCTUnwrap(topmostModeRow(rep), "no mode switch found for \(tool.rawValue)")
            tops.append((tool, top))
            let slug = tool.rawValue.replacingOccurrences(of: " ", with: "-")
            try XCTUnwrap(rep.representation(using: .png, properties: [:]))
                .write(to: URL(fileURLWithPath: "/tmp/analine-header-\(slug).png"))
            print("WORKSPACE_HEADER_ROW tool=\(tool.rawValue) image=\(image.width)x\(image.height) modeRowTop=\(top)")
            // The rendered image must agree with the measured layout height, or
            // the two checks are describing different things.
            XCTAssertEqual(CGFloat(image.height), layoutHeight(view), accuracy: 0.5)
        }
        XCTAssertEqual(Set(tops.map(\.1)).count, 1, "all four mode rows must start on the same pixel row")
    }

    /// The mode row has to sit on the header's vertical centre, which is the
    /// whole point of moving the readout lines beside it: equal space above and
    /// below the 48 pt row inside the 80 pt band.
    @MainActor
    func testModeRowIsVerticallyCentred() throws {
        let band = WorkspaceHeader.contentHeight
        let row = WorkspaceHeader.modeRowHeight
        XCTAssertGreaterThan(band, row, "the band must be taller than the mode row to have a centre")
        var tops: [(EditingTool, Int)] = []
        for tool in EditingTool.allCases {
            let (_, view) = makeHeader(tool)
            let renderer = ImageRenderer(content: view)
            renderer.scale = 1
            let image = try XCTUnwrap(renderer.cgImage)
            let rep = NSBitmapImageRep(cgImage: image)
            let top = try XCTUnwrap(topmostModeRow(rep))
            tops.append((tool, top))
            // 20 pt padding + 10 pt extra top, then half the leftover band.
            let expected = 30 + Int((band - row) / 2)
            XCTAssertEqual(top, expected, "\(tool.rawValue) mode row is not on the header centre")
            // Equal space above and below the mode row, measured inside the band.
            let above = top - 30
            let below = (30 + Int(band)) - (top + Int(row))
            XCTAssertEqual(above, below, accuracy: 1,
                           "\(tool.rawValue) must have equal space above and below the mode row")
        }
        print("WORKSPACE_HEADER_CENTRE band=\(band) row=\(row) tops=\(tops.map(\.1))")
    }

    /// Moving the readout beside the mode row takes its width out of the same
    /// line as the logo, the mode switch and the Choose button. This reports the
    /// budget so a window too narrow to hold the readout shows up as numbers
    /// rather than as a silently truncated build stamp.
    @MainActor
    func testReadoutFitsTheWidthLeftOverFromTheModeRow() throws {
        let switchWidth = fittingWidth(AnyView(ToolModeSwitch(selection: .constant(.film))))
        let modeRow = WorkspaceHeader.logoWidth + headerSpacing + switchWidth
        let fixed = modeRow + WorkspaceHeader.actionWidth + headerSpacing * 4
        print("WORKSPACE_HEADER_BUDGET modeRow=\(modeRow) switch=\(switchWidth) fixed=\(fixed)")

        let stampIdeal = fittingWidth(AnyView(EarlyBuildStamp().environment(\.colorScheme, .dark)))
        print("WORKSPACE_HEADER_BUDGET stampIdeal=\(stampIdeal) live=\(BuildStamp.compact ?? BuildStamp.notice)")

        // The test process has its own bundle, so the live stamp above is not
        // the app's. Size the string the packaged app actually shows — build id
        // and the minute from `Scripts/build-app.sh` — with the same parts.
        let iconWidth = fittingWidth(AnyView(
            Image(systemName: "exclamationmark.triangle.fill").font(.system(size: 9, weight: .bold))
        ))
        // Every form the header stamp could take, so the width cost of each is
        // on the record rather than guessed at.
        let forms = [
            "Build 6ACED473 · 2026-10-14 10:22",
            "Build 6ACED473 · 2026-10-14",
            "Build 6ACED473",
        ]
        for form in forms {
            let textWidth = fittingWidth(AnyView(Text(form).font(.caption2).monospacedDigit()))
            let total = iconWidth + 6 + textWidth
            print("WORKSPACE_HEADER_BUDGET form=\"\(form)\" width=\(total) fitsAbove=\(fixed + total + 40)")
        }

        let shippedText = forms[0]
        let shippedTextWidth = fittingWidth(AnyView(
            Text(shippedText).font(.caption2).monospacedDigit()
        ))
        let shippedStamp = iconWidth + 6 + shippedTextWidth
        print("WORKSPACE_HEADER_BUDGET shippedStamp=\(shippedStamp) icon=\(iconWidth) text=\(shippedTextWidth)")

        for window in [1000.0, 1100.0, 1200.0] as [CGFloat] {
            // Root `.padding(20)`, then the header's own `.padding(20)`.
            print("WORKSPACE_HEADER_BUDGET window=\(window) readoutSlot=\((window - 40) - fixed)")
        }

        // The default window is what the readout is sized for; below that the
        // stamp truncates, which is why the value is a budget and not a promise.
        let defaultSlot = (1200.0 - 40) - fixed
        XCTAssertGreaterThanOrEqual(defaultSlot, shippedStamp,
                                    "the build stamp must fit the default 1200 pt window")
        let threshold = fixed + shippedStamp + 40
        print("WORKSPACE_HEADER_BUDGET readoutFitsAbove=\(threshold)")
        XCTAssertLessThanOrEqual(threshold, 1200,
                                 "the readout must fit the default window, not just the widest one")
    }

    /// A second render at the default window width, where the readout has the
    /// 248 pt it needs; the checked-in numbers above use the 1000 pt minimum.
    @MainActor
    func testDefaultWindowRendersTheReadoutInFull() throws {
        for tool in EditingTool.allCases {
            let model = PreviewModel()
            model.tool = tool
            let view = AnyView(
                WorkspaceHeader(model: model)
                    .frame(width: 1200)
                    .environment(\.colorScheme, .dark)
            )
            let renderer = ImageRenderer(content: view)
            renderer.scale = 1
            let image = try XCTUnwrap(renderer.cgImage)
            let rep = NSBitmapImageRep(cgImage: image)
            let slug = tool.rawValue.replacingOccurrences(of: " ", with: "-")
            try XCTUnwrap(rep.representation(using: .png, properties: [:]))
                .write(to: URL(fileURLWithPath: "/tmp/analine-header-1200-\(slug).png"))
            print("WORKSPACE_HEADER_DEFAULT tool=\(tool.rawValue) image=\(image.width)x\(image.height)")
        }
    }
}
