import XCTest
import SwiftUI
import AppKit
import AnalogCore
@testable import AnalogGUI

@MainActor
final class FilmLabWorkflowTests: XCTestCase {
    func testResumeAndUndoPreserveRecipeAndLog() throws {
        let name = "FilmLabTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        let lab = FilmLabController(defaults: defaults)
        lab.scannerPreset = "test-scan-preset"; lab.scannerMix = 0.35
        lab.session.recipe.kelvin = 3200
        lab.advance(1); lab.complete()
        let exposed = lab.session.operations
        lab.session.recipe.developer = .perceptol
        lab.advance(300); lab.complete()
        let restored = FilmLabController(defaults: defaults)
        XCTAssertEqual(restored.session,lab.session)
        XCTAssertFalse(restored.running)
        XCTAssertEqual(restored.scannerPreset,"test-scan-preset")
        XCTAssertEqual(restored.scannerMix,0.35)
        restored.undo()
        XCTAssertEqual(restored.session.stage,.development)
        XCTAssertEqual(restored.session.operations,exposed)
        XCTAssertEqual(restored.session.recipe.kelvin,3200)
        XCTAssertEqual(restored.session.recipe.developer,.id11)
    }
    func testRewindPausesAndPersists() {
        let name = "FilmLabRewind.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        let lab = FilmLabController(defaults: defaults)
        lab.advance(1); lab.complete(); lab.advance(60)
        lab.toggle(); XCTAssertTrue(lab.running)
        lab.rewind(30)
        XCTAssertFalse(lab.running); XCTAssertEqual(lab.session.elapsed,30)
        XCTAssertEqual(FilmLabController(defaults: defaults).session,lab.session)
    }
    func testStageLayouts() throws {
        guard let path = ProcessInfo.processInfo.environment["ANALINE_LAB_ARTIFACTS"] else { return }
        try FileManager.default.createDirectory(at: URL(fileURLWithPath: path),withIntermediateDirectories: true)
        _ = NSApplication.shared
        let name = "FilmLabLayout.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        let lab = FilmLabController(defaults: defaults),model = PreviewModel()
        model.original = NSImage(size: NSSize(width: 640,height: 480))
        for stage in FilmLabStage.allCases {
            let file = "\(path)/stage-\(stage.rawValue).png"
            model.processed = NSImage(contentsOfFile: file)
            let view = NSHostingView(rootView: FilmLabWorkspace(model: model,lab: lab).padding(20).preferredColorScheme(.dark))
            let window = NSWindow(contentRect: NSRect(x: 0,y: 0,width: 1120,height: 700),styleMask: [.borderless],backing: .buffered,defer: false)
            window.contentView = view
            view.frame = NSRect(x: 0,y: 0,width: 1120,height: 700)
            view.layoutSubtreeIfNeeded()
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
            guard let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return XCTFail("Cannot capture stage layout") }
            view.cacheDisplay(in: view.bounds,to: bitmap)
            try bitmap.representation(using: .png,properties: [:])!.write(to: URL(fileURLWithPath: "\(path)/ui-\(stage.rawValue).png"))
            window.orderOut(nil)
            if stage != .scan { lab.advance(stage.defaultDuration); lab.complete() }
        }
    }
}
