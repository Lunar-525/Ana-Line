import SwiftUI
import UniformTypeIdentifiers

extension UTType {
    static let anaLineSession = UTType(exportedAs: "local.analine.session",conformingTo: .json)
}

struct TVSessionCommands: Commands {
    @FocusedObject private var model: PreviewModel?
    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button(L("Open Session…")) { model?.chooseSession() }
                .keyboardShortcut("o").disabled(model == nil || model?.busy == true)
        }
        CommandGroup(replacing: .saveItem) {
            Button(L("Render and Export…")) { model?.exportTVVideo() }
                .disabled(model?.tool != .tv || model?.busy == true || (model?.tvDuration ?? 0) <= 0)
            Button(L("Cancel Export")) { model?.cancelTVExport() }
                .disabled(model?.tvExporting != true)
            Divider()
            Button(L("Save Session")) { model?.saveSession() }
                .keyboardShortcut("s").disabled(model?.tool != .tv || model?.busy == true)
            Button(L("Save Session As…")) { model?.saveSession(asNew: true) }
                .keyboardShortcut("s",modifiers: [.command,.shift]).disabled(model?.tool != .tv || model?.busy == true)
        }
    }
}
