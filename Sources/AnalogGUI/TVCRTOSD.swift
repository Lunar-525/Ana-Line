import SwiftUI
import AppKit

/// Shared navigation and settings for the PVM-style panel and its on-screen
/// menu. The panel owns navigation; the OSD renders the current selection.
enum TVOSDPalette {
    /// The TV accent is a warm yellow; the OSD uses its complementary hue.
    static let accent: Color = {
        let base = NSColor(calibratedRed: 234/255, green: 212/255, blue: 119/255, alpha: 1)
        var h: CGFloat = 0, sat: CGFloat = 0, bri: CGFloat = 0, alpha: CGFloat = 0
        base.getHue(&h, saturation: &sat, brightness: &bri, alpha: &alpha)
        let complement = (h + 0.5).truncatingRemainder(dividingBy: 1)
        return Color(nsColor: NSColor(hue: complement, saturation: sat, brightness: bri, alpha: 1))
    }()
}

@MainActor
final class TVOSDState: ObservableObject {
    enum Page { case main, mask }
    static let rowCount = 9
    static let mainPageSize = 6
    static let maskPageSize = 5
    static let rowTitles = [
        "CRT DISPLAY", "HDR PHOSPHOR", "AUTO XDR", "PIXEL PERFECT",
        "CRT LINES", "SCANLINES", "PHOSPHOR MASK", "CURVATURE", "MASK TYPE",
    ]

    @Published var isOpen = false
    @Published var selection = 0
    @Published var editing = false
    @Published var page: Page = .main
    @Published var maskSelection = 0

    @Published var enabled = false
    @Published var hdr = true
    @Published var automaticBrightness = true
    @Published var pixelPerfect = true
    @Published var lines = 240.0
    @Published var automaticLines = true
    @Published var scanlines = 480.0
    @Published var maskStrength = 0.8
    @Published var curvature = 0.5
    @Published var maskType = 0

    var mainPage: Int { selection / Self.mainPageSize }
    var mainPageCount: Int { (Self.rowCount + Self.mainPageSize - 1) / Self.mainPageSize }
    var visibleMainRows: Range<Int> {
        let start = min(Self.rowCount, mainPage * Self.mainPageSize)
        return start..<min(Self.rowCount, start + Self.mainPageSize)
    }
    var maskPage: Int { maskSelection / Self.maskPageSize }
    var maskPageCount: Int { (TVCRTMaskType.allCases.count + Self.maskPageSize - 1) / Self.maskPageSize }
    var visibleMaskIndices: Range<Int> {
        let count = TVCRTMaskType.allCases.count
        let start = min(count, maskPage * Self.maskPageSize)
        return start..<min(count, start + Self.maskPageSize)
    }

    var maxLines: Double
    private let defaults: UserDefaults
    private let lineKey = "tvCRTLines"
    private let scanKey = "tvCRTScanlines"

    init(defaults: UserDefaults = .standard, maxLines: Double = 576) {
        self.defaults = defaults
        self.maxLines = maxLines.isFinite ? max(120, maxLines) : 576
        reload()
    }

    private var lineLimit: Double { maxLines.isFinite ? max(120, maxLines) : 576 }

    private func bool(_ key: String, _ fallback: Bool) -> Bool {
        (defaults.object(forKey: key) as? Bool) ?? fallback
    }
    private func number(_ key: String, _ fallback: Double) -> Double {
        (defaults.object(forKey: key) as? NSNumber)?.doubleValue ?? fallback
    }
    private func set(_ key: String, _ value: Any) { defaults.set(value, forKey: key) }
    private func clamp(_ value: Double, _ low: Double, _ high: Double) -> Double {
        min(high, max(low, value.isFinite ? value : low))
    }

    func reload() {
        enabled = bool("tvCRTEnabled", false)
        hdr = bool("tvCRTHDR", true)
        automaticBrightness = bool("tvCRTAutoBrightness", true)
        pixelPerfect = bool("tvCRTPixelPerfectStripes", true)
        lines = min(lineLimit, max(120, number(lineKey, 240)))
        automaticLines = bool("tvCRTAutomaticLines", true)
        scanlines = min(lineLimit, max(120, number(scanKey, 480)))
        maskStrength = clamp(number("tvCRTMaskStrength", 0.8), 0, 1)
        curvature = clamp(number("tvCRTCurvature", 0.5), 0, 1)
        maskType = min(6, max(0, Int(number("tvCRTMaskType", 0).rounded())))
        maskSelection = maskType
    }

    func togglePower() {
        enabled.toggle()
        set("tvCRTEnabled", enabled)
        if !enabled { closeForPowerOff() }
    }

    private func closeForPowerOff() {
        isOpen = false
        page = .main
        editing = false
    }

    /// Called when another CRT control (the detailed popover) turns power off.
    func forcePowerOff() {
        enabled = false
        closeForPowerOff()
    }

    func openMenu() {
        reload()
        guard enabled else {
            closeForPowerOff()
            return
        }
        isOpen = true
        page = .main
        editing = false
        selection = 0
    }

    func menu() {
        guard enabled else {
            closeForPowerOff()
            return
        }
        guard isOpen else { openMenu(); return }
        if page == .mask || editing {
            page = .main
            editing = false
        } else {
            isOpen = false
        }
    }

    func up() {
        guard isOpen else { return }
        if page == .mask {
            let count = TVCRTMaskType.allCases.count
            maskSelection = (maskSelection + count - 1) % count
        } else if editing {
            adjust(-1)
        } else {
            selection = (selection + Self.rowCount - 1) % Self.rowCount
        }
    }

    func down() {
        guard isOpen else { return }
        if page == .mask {
            let count = TVCRTMaskType.allCases.count
            maskSelection = (maskSelection + 1) % count
        } else if editing {
            adjust(1)
        } else {
            selection = (selection + 1) % Self.rowCount
        }
    }

    func enter() {
        guard isOpen else { return }
        if page == .mask {
            applyMask(maskSelection)
            page = .main
            return
        }
        if editing {
            editing = false
            return
        }
        switch selection {
        case 0:
            enabled.toggle(); set("tvCRTEnabled", enabled)
            if !enabled { closeForPowerOff() }
        case 1:
            hdr.toggle(); set("tvCRTHDR", hdr)
        case 2:
            automaticBrightness.toggle(); set("tvCRTAutoBrightness", automaticBrightness)
        case 3:
            pixelPerfect.toggle(); set("tvCRTPixelPerfectStripes", pixelPerfect)
        case 4:
            editing = true
        case 5:
            if automaticLines {
                automaticLines = false
                set("tvCRTAutomaticLines", false)
            } else {
                editing = true
            }
        case 6:
            editing = true
        case 7:
            editing = true
        case 8:
            page = .mask
            maskSelection = maskType
        default:
            break
        }
    }

    private func applyMask(_ raw: Int) {
        maskType = min(6, max(0, raw))
        set("tvCRTMaskType", maskType)
    }

    private func adjust(_ direction: Int) {
        switch selection {
        case 4:
            lines = min(lineLimit, max(120, lines + Double(direction) * 5))
            set(lineKey, lines)
        case 5:
            guard !automaticLines else { return }
            scanlines = min(lineLimit, max(120, scanlines + Double(direction) * 5))
            set(scanKey, scanlines)
        case 6:
            maskStrength = clamp(maskStrength + Double(direction) * 0.05, 0, 1)
            set("tvCRTMaskStrength", maskStrength)
        case 7:
            curvature = clamp(curvature + Double(direction) * 0.05, 0, 1)
            set("tvCRTCurvature", curvature)
        default:
            break
        }
    }

    func value(for row: Int) -> String {
        switch row {
        case 0: return enabled ? "ON" : "STANDBY"
        case 1: return hdr ? "ON" : "OFF"
        case 2: return automaticBrightness ? "ON" : "OFF"
        case 3: return pixelPerfect ? "ON" : "OFF"
        case 4: return "\(Int(lines)) L"
        case 5: return automaticLines ? "AUTO" : "\(Int(scanlines)) L"
        case 6: return "\(Int((maskStrength * 100).rounded()))%"
        case 7: return "\(Int((curvature * 100).rounded()))%"
        case 8: return TVCRTMaskType(rawValue: maskType)?.title ?? "—"
        default: return ""
        }
    }
}

struct TVCRTOSDView: View {
    @ObservedObject var state: TVOSDState

    var body: some View {
        if state.isOpen {
            ZStack {
                Color.black.opacity(0.32).ignoresSafeArea()
                VStack(spacing: 0) {
                    header
                    if state.page == .mask { maskList } else { rows }
                    footer
                }
                .frame(width: 430)
                .background(Rectangle().fill(Color.black.opacity(0.90)))
                .overlay(Rectangle().stroke(Color.white.opacity(0.45), lineWidth: 1))
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                Text("SETUP")
                    .font(TVOSDFont.font(17))
                    .tracking(2)
                    .foregroundStyle(.white)
                Text("CRT MONITOR / MULTI FORMAT")
                    .font(TVOSDFont.font(9))
                    .foregroundStyle(.white.opacity(0.55))
            }
            Spacer(minLength: 0)
            Text(state.enabled ? "ON" : "STANDBY")
                .font(TVOSDFont.font(9))
                .foregroundStyle(.white.opacity(0.7))
        }
        .padding(.horizontal, 12).frame(height: 50)
        .background(Color.white.opacity(0.06))
    }

    private var rows: some View {
        VStack(spacing: 0) {
            ForEach(state.visibleMainRows, id: \.self) { index in
                row(index)
            }
        }
        .padding(.vertical, 4)
    }

    private func row(_ index: Int) -> some View {
        let selected = state.selection == index
        return HStack(spacing: 7) {
            Text(selected ? "▶" : " ").frame(width: 12, alignment: .leading)
            Text(TVOSDState.rowTitles[index])
                .frame(maxWidth: .infinity, alignment: .leading)
            Text(state.value(for: index))
                .monospacedDigit()
            if selected && state.editing {
                Text("◀▶").font(TVOSDFont.font(9))
            }
        }
        .font(TVOSDFont.font(15))
        .foregroundStyle(selected ? Color.black : Color.white.opacity(0.9))
        .padding(.horizontal, 10).frame(height: 32)
        .background(selected ? TVOSDPalette.accent : Color.clear)
        .contentShape(Rectangle())
        .onTapGesture {
            state.selection = index
            state.enter()
        }
    }

    private var maskList: some View {
        VStack(spacing: 0) {
            Text("PHOSPHOR ARRANGEMENT")
                .font(TVOSDFont.font(9.5))
                .foregroundStyle(.white.opacity(0.55))
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 12).padding(.vertical, 5)
            ForEach(Array(state.visibleMaskIndices), id: \.self) { index in
                let type = TVCRTMaskType.allCases[index]
                let selected = state.maskSelection == index
                HStack(spacing: 9) {
                    Text(selected ? "▶" : " ").frame(width: 12, alignment: .leading)
                    TVCRTMaskGlyph(type: type).frame(width: 38, height: 22)
                    Text(type.title)
                    Spacer(minLength: 0)
                    if state.maskType == type.rawValue { Text("✓") }
                }
                .font(TVOSDFont.font(13))
                .foregroundStyle(selected ? Color.black : Color.white.opacity(0.9))
                .padding(.horizontal, 10).frame(height: 36)
                .background(selected ? TVOSDPalette.accent : Color.clear)
                .contentShape(Rectangle())
                .onTapGesture {
                    state.maskSelection = index
                    state.enter()
                }
            }
        }
        .padding(.vertical, 4)
    }

    private var footer: some View {
        HStack(spacing: 12) {
            Text(pageText)
            Spacer(minLength: 0)
            Text(footerText)
        }
        .font(TVOSDFont.font(8.5))
        .foregroundStyle(.white.opacity(0.55))
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 12).frame(height: 30)
        .background(Color.white.opacity(0.05))
    }

    private var pageText: String {
        if state.page == .mask {
            return String(format: "PAGE %d/%d", state.maskPage + 1, state.maskPageCount)
        }
        return String(format: "PAGE %d/%d", state.mainPage + 1, state.mainPageCount)
    }

    private var footerText: String {
        if state.editing { return "← BACK   ↑↓ ADJUST   ENTER/→ SET" }
        if state.page == .mask { return "← BACK   ↑↓ SELECT   ENTER/→ SET" }
        return "← MENU/BACK   ↑↓ SELECT   ENTER/→"
    }
}


@MainActor
enum TVCRTOSDImage {
    /// Rasterise the OSD once per menu change. The renderer uploads it as a
    /// separate texture and crtFragment blends it into the source sample before
    /// the phosphor/scanline/curvature pass. No per-frame CPU compositing.
    static func make(state: TVOSDState, size: NSSize = NSSize(width: 640, height: 480)) -> NSImage? {
        guard state.isOpen else { return nil }
        let renderer = ImageRenderer(content: TVCRTOSDView(state: state)
            .frame(width: size.width, height: size.height))
        renderer.scale = 1
        guard let image = renderer.cgImage else { return nil }
        return NSImage(cgImage: image, size: size)
    }
}
