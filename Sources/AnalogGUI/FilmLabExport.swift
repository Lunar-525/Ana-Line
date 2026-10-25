import SwiftUI
import UniformTypeIdentifiers
import AnalogImaging

extension PreviewModel {
    func exportFilmLab() {
        guard !busy,let source = filmLab.resumeURL,let library else { return }
        let panel = NSSavePanel(); panel.allowedContentTypes = [.png]
        panel.nameFieldStringValue = "Film-Lab-Scan.png"
        guard panel.runModal() == .OK,let url = panel.url else { return }
        var snapshot = settings
        snapshot.laboratory = filmLab.session; snapshot.laboratoryDisplay = 0
        let preset = library.presets.first { $0.id == selected }
        busy = true
        Task {
            defer { busy = false }
            do {
                let exporter = LUTRenderer()
                try await exporter.exportFilmLab(source: source,to: url,preset: preset,library: library,settings: snapshot)
                status = "扫描图像已导出 · \(url.lastPathComponent)"
            } catch { status = "导出失败：\(error.localizedDescription)" }
        }
    }
}
