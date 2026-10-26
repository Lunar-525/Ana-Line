import SwiftUI
import AppKit

/// A separate program window. It observes the same receiver preview as the
/// main workspace and draws only the processed feed: no comparison split,
/// labels, scan progress or OSD.
struct TVCleanFeedView: View {
    @ObservedObject var model: PreviewModel
    @ObservedObject var tvState: TVPreviewState
    @AppStorage("tvCRTEnabled") private var crtEnabled = false
    @AppStorage("tvCRTHDR") private var crtHDR = true
    @AppStorage("tvCRTBrightness") private var crtBrightness = 2.0
    @AppStorage("tvCRTAutomaticLines") private var crtAutomaticLines = true
    @AppStorage("tvCRTLines") private var crtLines = 240.0
    @AppStorage("tvCRTMaskStrength") private var crtMaskStrength = 0.8
    @AppStorage("tvCRTMaskType") private var crtMaskType = TVCRTMaskType.apertureGrille.rawValue
    @AppStorage("tvCRTScanlines") private var crtScanlines = 480.0

    init(model: PreviewModel) {
        self.model = model
        self.tvState = model.tvPreviewState
    }

    var body: some View {
        GeometryReader { geometry in
            let imageSize = tvState.processed?.size ?? CGSize(width: 4, height: 3)
            let scale = min(geometry.size.width / max(1, imageSize.width),
                            geometry.size.height / max(1, imageSize.height))
            let width = imageSize.width * scale
            let height = imageSize.height * scale
            ZStack {
                Color.black
                if let image = tvState.processed {
                    Group {
                        if crtEnabled, TVCRTDisplay.isAvailable {
                            TVCRTDisplay(image: image, hdr: crtHDR, brightness: crtBrightness,
                                crtLines: crtLines, maskStrength: crtMaskStrength,
                                scanlines: crtAutomaticLines ? 0 : crtScanlines,
                                maxLines: Double(model.tvStandard.height),
                                maskType: crtMaskType, historyID: tvState.crtHistoryID)
                        } else {
                            Image(nsImage: image).resizable().interpolation(.high)
                        }
                    }
                    .frame(width: width, height: height)
                }
            }
            .frame(width: geometry.size.width, height: geometry.size.height)
        }
        .background(Color.black)
        .preferredColorScheme(.dark)
        .navigationTitle(L("Clean Feed"))
        .accessibilityLabel(L("Clean feed"))
    }
}
