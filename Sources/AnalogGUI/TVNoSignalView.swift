import SwiftUI
import AppKit
import AnalogCore

/// A small bank of grayscale textures keeps idle snow off the RF pipeline and
/// avoids generating pixels or publishing application state on every tick.
@MainActor
enum TVSnowFrames {
    static let images: [CGImage] = (0..<32).map { frame in
        let width = 256, height = 192
        var seed = UInt64(frame+1) &* 0x9e3779b97f4a7c15
        var pixels = [UInt8](repeating: 0,count: width*height)
        for n in pixels.indices {
            seed ^= seed >> 12; seed ^= seed << 25; seed ^= seed >> 27
            pixels[n] = UInt8(truncatingIfNeeded: (seed &* 0x2545f4914f6cdd1d) >> 56)
        }
        let provider = CGDataProvider(data: Data(pixels) as CFData)!
        return CGImage(width: width,height: height,bitsPerComponent: 8,bitsPerPixel: 8,
            bytesPerRow: width,space: CGColorSpaceCreateDeviceGray(),bitmapInfo: [],
            provider: provider,decode: nil,shouldInterpolate: false,intent: .defaultIntent)!
    }
}

@MainActor
enum TVOSDFont {
    static let name = NSFontManager.shared.availableFonts.first {
        $0.localizedCaseInsensitiveContains("VCR") && $0.localizedCaseInsensitiveContains("OSD")
    }
    static func font(_ size: CGFloat) -> Font {
        name.map { .custom($0,size: size) } ?? .system(size: size,weight: .medium,design: .monospaced)
    }
}

struct TVNoSignalView: View {
    let standard: TVStandard
    var preparing = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var visible = false
    var body: some View {
        ZStack {
            Color.black
            TimelineView(.animation(minimumInterval: 1/25,paused: !visible || reduceMotion)) { tick in
                let index = reduceMotion ? 0 : Int(tick.date.timeIntervalSinceReferenceDate*25)%TVSnowFrames.images.count
                let frame = TVSnowFrames.images[index]
                Canvas(rendersAsynchronously: true) { context,size in
                    context.opacity = 0.7
                    context.draw(Image(decorative: frame,scale: 1),in: CGRect(origin: .zero,size: size))
                }.accessibilityHidden(true)
            }
            VStack(alignment: .leading) {
                Text(standard == .pal ? "PAL" : "NTSC").font(TVOSDFont.font(24))
                Spacer()
                VStack(spacing: 14) {
                    Text(preparing ? "PREPARING VIDEO" : "NO SIGNAL").font(TVOSDFont.font(40))
                    Text(preparing ? "PAL + NTSC" : "NO VIDEO INPUT").font(TVOSDFont.font(24))
                }.frame(maxWidth: .infinity)
                Spacer()
                VStack(spacing: 8) {
                    Text(preparing ? "PLEASE WAIT" : "DROP A VIDEO HERE")
                    if !preparing { Text("OR CLICK CHOOSE VIDEO...") }
                }.font(TVOSDFont.font(23)).frame(maxWidth: .infinity)
            }.padding(28).padding(.bottom,12)
                .foregroundStyle(.white).shadow(color: .black,radius: 0,x: 2,y: 2)
                .allowsHitTesting(false)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(preparing ? L("Preparing PAL + NTSC video…") : L("Drop a video here to start"))
        .help(preparing ? L("Preparing PAL + NTSC video…") : L("You can also click “Choose Video…” above"))
        .onAppear { visible = true }.onDisappear { visible = false }
    }
}
