import SwiftUI

/// Geometric sampling estimate, not image-content detection. Thresholds are
/// deliberately heuristic; shader filtering and beam curvature are included.
@MainActor
struct TVMoireAdvice {
    enum Risk: Int, Comparable {
        case low, medium, high
        static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }
        var title: String {
            switch self {
            case .low: return "Low"
            case .medium: return "Medium"
            case .high: return "High"
            }
        }
    }
    struct Estimate {
        let mask: Double
        let scan: Double
        var score: Double { max(mask, scan) }
        var risk: Risk { score >= 0.55 ? .high : score >= 0.2 ? .medium : .low }
    }
    let estimate: Estimate
    let lines: Int
    let scanlines: Int
    let suggestions: [Int]

    init(drawableSize: CGSize, maximum: Double, requestedLines: Double,
         requestedScanlines: Double = 0, maskType: Int = 0, maskStrength: Double = 0.8,
         curvature: Double = 0.018) {
        let width = drawableSize.width.isFinite ? max(1, Double(drawableSize.width)) : 1
        let height = drawableSize.height.isFinite ? max(1, Double(drawableSize.height)) : 1
        let curve = curvature.isFinite ? min(TVCRTDisplay.maximumCurvature, max(0, curvature)) : 0.018
        let cap = TVCRTDisplay.Renderer.displayLineLimit(maxLines: maximum, drawableHeight: height)
        lines = TVCRTDisplay.Renderer.crtLineCount(requestedLines, maximum: Double(cap))
        scanlines = Int(TVCRTDisplay.Renderer.lineCount(requestedScanlines, crtLines: requestedLines, maximum: Double(cap)))
        let style = TVCRTMaskStyle.make(type: maskType, mask: maskStrength)
        func evaluate(_ rows: Int) -> Estimate {
            let grid = TVCRTDisplay.Renderer.dotGrid(lines: rows, aspect: width / height)
            let cell = min(width / Double(grid.triads), height / Double(grid.rows))
            let lattice = style.type == .shadowMask || style.type == .hexagonalMask
            let dot = cell * (lattice ? 2 * style.radius / 1.611854898 : 1.0 / 3)
            // A triangular/hexagonal lattice interleaves the three primaries in
            // two dimensions. Its colour beat is much less directional than a
            // vertical grille, so it stays clean to higher line counts. The 0.20
            // weighting is an empirical calibration knob: it is intentionally
            // separate from the geometry so visual tests can retune it without
            // rewriting the lattice math.
            let latticeBias = lattice ? 0.20 : 1.0
            // Match the shader's unresolved-dot fallback, so fully averaged
            // phosphors do not generate a false high-risk warning.
            let resolved = Self.smooth(0.6, 1.6, dot)
            let scans = TVCRTDisplay.Renderer.lineCount(requestedScanlines, crtLines: Double(rows), maximum: Double(cap))
            var maskScore = 0.0
            var scanScore = 0.0
            // Curvature changes local pitch across the screen (Jacobian up to
            // 1.108 on either axis). Integer centre pitch alone is insufficient.
            for i in 0...12 {
                let stretch = 1 + 6 * curve * Double(i) / 12
                let triadPitch = width / Double(grid.triads) / stretch
                let rowPitch = height / Double(rows) / stretch
                let maskPitch = style.type == .horizontalStripes ? rowPitch : lattice ? min(triadPitch, rowPitch) : triadPitch
                let density = 1 - Self.smooth(2, 6, maskPitch)
                let beat = Self.noninteger(maskPitch) * (1 - Self.smooth(3, 8, maskPitch))
                var score = max(density, beat) * resolved
                // A staggered lattice does not have the square row beat that
                // slot/inline masks have; adding it here was what made the
                // triangular masks look *more* risky at high line counts.
                if !lattice && style.type != .apertureGrille && style.type != .beamIndex && style.type != .horizontalStripes {
                    score = max(score, resolved * Self.noninteger(rowPitch) * (1 - Self.smooth(3, 8, rowPitch)))
                }
                score *= latticeBias
                maskScore = max(maskScore, score)
                let pitch = height / scans / stretch
                let visible = 1 - Self.smooth(0.5, 1, 1 / pitch)
                scanScore = max(scanScore, visible * max(1 - Self.smooth(2, 4, pitch), Self.noninteger(pitch) * (1 - Self.smooth(3, 8, pitch))))
            }
            return Estimate(mask: maskScore, scan: scanScore)
        }
        let currentLines = lines
        let currentEstimate = evaluate(currentLines)
        estimate = currentEstimate
        // Only recommend a perceptible improvement; do not recommend more
        // lines merely because their mask disappears into the fallback.
        suggestions = (120...cap).filter { $0 < currentLines && evaluate($0).score + 0.12 < currentEstimate.score }
            .sorted { abs($0 - currentLines) < abs($1 - currentLines) }.prefix(2).sorted()
    }
    private static func smooth(_ a: Double, _ b: Double, _ x: Double) -> Double {
        let t = min(1, max(0, (x - a) / (b - a)))
        return t * t * (3 - 2 * t)
    }
    private static func noninteger(_ pitch: Double) -> Double {
        min(1, abs(pitch - pitch.rounded()) * 2)
    }
}

struct TVMoireWarningView: View {
    @ObservedObject var model: PreviewModel
    private let state: TVPreviewState
    @State private var drawableSize: CGSize = .zero
    init(model: PreviewModel) { self.model = model; state = model.tvPreviewState }
    @AppStorage("tvCRTEnabled") private var enabled = false
    @AppStorage("tvCRTLines") private var lines = 240.0
    @AppStorage("tvCRTAutomaticLines") private var automatic = true
    @AppStorage("tvCRTScanlines") private var scans = 480.0
    @AppStorage("tvCRTMaskStrength") private var strength = 0.8
    @AppStorage("tvCRTMaskType") private var type = 0
    @AppStorage("tvCRTCurvature") private var curvature = 0.5
    @AppStorage("tvCRTPixelPerfectStripes") private var pixelPerfect = true

    var body: some View {
        Group {
            if model.tool == .tv, enabled, model.tvDuration > 0,
               drawableSize.width > 0, drawableSize.height > 0,
               !(pixelPerfect && TVCRTPixelPerfect.isStripe(type)) {
                let advice = TVMoireAdvice(drawableSize: drawableSize,
                    maximum: Double(model.tvStandard.height), requestedLines: lines,
                    requestedScanlines: automatic ? 0 : scans, maskType: type, maskStrength: strength,
                    curvature: TVCRTDisplay.curvatureCoefficient(curvature))
                HStack(spacing: 6) {
                    Image(systemName: advice.estimate.risk == .low ? "info.circle" : "exclamationmark.triangle.fill")
                    Text(message(advice)).lineLimit(3)
                    Spacer(minLength: 0)
                }
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.black)
                .padding(.horizontal, 10).padding(.vertical, 5)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(advice.estimate.risk == .low ? Color.white.opacity(0.85) : EditingTool.tv.logoAccentColor)
                .allowsHitTesting(false)
            }
        }
        // Observe only the drawable-size publisher. Observing the whole
        // TVPreviewState would recompute the suggestion search on every video
        // frame, even though only the size changes the geometry.
        .onAppear { drawableSize = state.crtDrawableSize }
        .onReceive(state.$crtDrawableSize) { drawableSize = $0 }
    }
    private func message(_ advice: TVMoireAdvice) -> String {
        let heading = String(format: L("CRT moiré risk: %@."), L(advice.estimate.risk.title) as NSString)
        guard advice.estimate.risk != .low else { return heading + " " + L("Sampling estimate; image content is not analysed.") }
        let reason = advice.estimate.mask >= advice.estimate.scan ? L("Phosphor mask is dense or unevenly sampled.") : L("Scanlines are dense or unevenly sampled.")
        let suggestion: String
        if advice.estimate.mask >= advice.estimate.scan {
            suggestion = advice.suggestions.isEmpty ? L("Enlarge the preview.")
                : String(format: L("Try CRT lines %@ or enlarge the preview."),
                    advice.suggestions.map(String.init).joined(separator: " / ") as NSString)
        } else {
            suggestion = advice.suggestions.isEmpty ? L("Reduce scanline count or enlarge the preview.")
                : String(format: L("Try CRT lines %@, reduce scanline count, or enlarge the preview."),
                    advice.suggestions.map(String.init).joined(separator: " / ") as NSString)
        }
        return heading + " " + reason + " " + suggestion
    }
}
