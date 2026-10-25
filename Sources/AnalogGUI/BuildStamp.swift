import SwiftUI

/// The build identity `Scripts/build-app.sh` stamps into Info.plist, read in one
/// place so the About panel and the workspace header can never disagree.
enum BuildStamp {
    static var identifier: String? { Bundle.main.infoDictionary?["CFBundleVersion"] as? String }
    static var time: String? { Bundle.main.infoDictionary?["AnaLineBuildTime"] as? String }

    static var configuration: String {
        #if DEBUG
        "Debug · DSP unoptimized"
        #else
        "Release · DSP optimized"
        #endif
    }

    /// "Build 6ACCF960 · 2026-10-13 00:19:44 +0800"; nil when the executable
    /// runs straight out of the build directory with no bundle around it.
    static var summary: String? {
        guard let identifier else { return nil }
        guard let time else { return "Build \(identifier)" }
        return "Build \(identifier) · \(time)"
    }

    /// The line under the workspace header: which build this is, and why the
    /// interface may still move.
    static var notice: String {
        let warning = L("Early build · features and interface are still changing")
        guard let summary else { return warning }
        return "\(summary) · \(warning)"
    }

    /// Header form. The header holds the wordmark, the mode switch and the
    /// Choose button on one row, so the stamp shows the identifier and the
    /// minute and leaves the full `notice` to the tooltip and the About panel.
    /// Nil when there is no bundle around the executable, which is also when
    /// `notice` collapses to the warning on its own.
    static var compact: String? {
        guard let identifier else { return nil }
        guard let time else { return "Build \(identifier)" }
        // "2026-10-14 10:22:36 +0800" -> "2026-10-14 10:22"
        let stamp = time.split(separator: " ").prefix(2).joined(separator: " ")
        return "Build \(identifier) · \(stamp)"
    }
}

/// Which build is running, beside the workspace header's status line. The
/// triangle borrows the hazard yellow so the warning reads as part of the tape
/// rather than as an error.
struct EarlyBuildStamp: View {
    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(HazardPalette.yellow)
            Text(BuildStamp.compact ?? BuildStamp.notice)
                .font(.caption2)
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
                .textSelection(.enabled)
                .help(BuildStamp.notice)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(BuildStamp.notice)
    }
}
