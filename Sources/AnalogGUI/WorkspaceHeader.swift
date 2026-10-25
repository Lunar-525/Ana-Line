import SwiftUI

/// The workspace header, rendered by all four mode pages.
///
/// It used to be inline in `ContentView` with a per-tool branch in the middle of
/// it, which let a page drift out of step with its neighbours twice over: Radio
/// hid the Choose button and came out shorter, and a follow-up
/// `.padding(.top, tool == .radio ? -28 : 0)` patch then pushed Radio 28 pt the
/// other way. Both are gone. Every page renders this one view, and the content
/// is pinned to `contentHeight`, so the four headers are equal by construction
/// rather than by two numbers happening to agree.
///
/// The layout is deliberately a single row. Stacking the status line and the
/// build stamp under the logo is what left the logo pinned to the top of the
/// band, so the mode switch could never sit on the header's vertical centre;
/// beside the mode row, everything shares one centre line.
@MainActor
struct WorkspaceHeader: View {
    @ObservedObject var model: PreviewModel

    /// One row, sized by the tallest thing in it: the 80 pt Choose button. The
    /// 48 pt mode row and the two readout lines centre inside that, which is
    /// what puts the logo and the mode switch on the header's vertical centre.
    static let contentHeight: CGFloat = actionHeight
    /// The status area is always exactly one row: a `.caption` line, the TV
    /// export row, or nothing. Fixing the slot keeps the header from growing
    /// when a mode swaps what it puts there.
    static let statusHeight: CGFloat = 22
    static let modeRowHeight: CGFloat = 48
    static let logoWidth: CGFloat = 240
    /// Reserved for the Choose button even on Radio, which has nothing to
    /// choose. The empty slot is what keeps the drag spacer the same width.
    static let actionWidth: CGFloat = 120
    static let actionHeight: CGFloat = 80

    var body: some View {
        HStack(alignment: .center, spacing: 16) {
            HStack(spacing: 16) {
                AnaLineLogo(tool: model.tool, width: Self.logoWidth)
                ToolModeSwitch(selection: $model.tool)
                    .disabled(model.busy)
            }
            .frame(height: Self.modeRowHeight)
            // These two lines used to hang under the logo, which left the logo
            // flush with the top of the band and 40 pt of text below it — never
            // centred no matter how the text was trimmed. Beside the mode row
            // they centre against it instead.
            VStack(alignment: .leading, spacing: 4) {
                status
                    .frame(height: Self.statusHeight, alignment: .leading)
                EarlyBuildStamp()
            }
            .layoutPriority(1)
            WindowDragSpacer()
            if model.busy || (model.rendering && !model.tvPlaying) {
                ProgressView().controlSize(.small)
            }
            action
        }
        .frame(height: Self.contentHeight)
        .padding(20)
        .padding(.top, 10)
        .background(Color.black.ignoresSafeArea(.container, edges: .top))
        // Hung before `ContentView` applies the negative padding below. That
        // padding is what lets the header bleed past the workspace gutter to the
        // window's own side and top edges, and it reports the *inset* frame, so
        // an overlay hung after it would sit 20 pt low and 20 pt short on each
        // side.
        .overlay(alignment: .top) { HazardStripeBand() }
        .modifier(WindowDragRegion())
    }

    /// One row, whichever mode is active. A page that stacked two rows here
    /// would be taller than its neighbours, which is exactly what the fixed
    /// `contentHeight` exists to prevent.
    @ViewBuilder private var status: some View {
        if model.tool == .tv {
            if model.tvExporting {
                HStack(spacing: 8) {
                    ProgressView(value: model.tvExportProgress).frame(width: 120)
                    Text(String(format: L("Rendering %.0f%% · %.2f×"), model.tvExportProgress*100, model.tvExportSpeed))
                        .font(.caption).monospacedDigit()
                    Button(L("Cancel")) { model.cancelTVExport() }
                }
            } else if !model.tvExportMessage.isEmpty {
                Text(model.tvExportMessage).font(.caption)
                    .lineLimit(1).textSelection(.enabled)
            } else {
                TVStatusText(state: model.tvPreviewState)
            }
        } else if model.tool == .tape {
            Text("CHF60 · " + L("Real-time tape processing")).font(.caption)
                .foregroundStyle(EditingTool.tape.logoAccentColor).lineLimit(1)
        } else if model.tool == .radio {
            Text("AM / FM / SSB / CW / PM · 实时收发")
                .font(.caption).foregroundStyle(EditingTool.radio.logoAccentColor)
                .lineLimit(1)
        } else {
            Text(model.status).font(.caption).foregroundStyle(.secondary)
                .lineLimit(1).textSelection(.enabled).help(model.status)
        }
    }

    @ViewBuilder private var action: some View {
        if model.tool == .radio {
            // Radio has no image or video to open, so the slot stays empty
            // instead of collapsing and shortening the header.
            Color.clear.frame(width: Self.actionWidth, height: Self.actionHeight)
        } else {
            Button { model.choose() } label: {
                Text(model.tool == .tape ? L("Choose Audio…") : model.tool == .tv ? L("Choose Video…") : L("Choose Image…"))
                    .font(.system(size: 13, weight: .medium))
                    .frame(width: Self.actionWidth, height: Self.actionHeight)
            }
            .buttonStyle(HeaderImageButtonStyle())
            .disabled(model.busy)
        }
    }
}
