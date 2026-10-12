import SwiftUI

enum HazardPalette {
    /// Sign-paint yellow. Deeper than the TV accent so the tape reads as a
    /// warning instead of as another mode colour.
    static let yellow = Color(red: 0.96, green: 0.75, blue: 0.05)
}

/// Hazard tape across the top of the workspace: 45° black/yellow stripes pinned
/// to the window's top edge, dissolving downward into the black header so the
/// wordmark and mode switch below stay legible. The black half of the pattern is
/// simply the header showing through; only the yellow bars are drawn.
struct HazardStripeBand: View {
    /// Total height of the tape, including the part that fades out.
    var height: CGFloat = 28
    /// Width of one yellow stripe measured across it, i.e. perpendicular to the
    /// 45° run of the tape. The black gap between stripes matches it.
    var stripeWidth: CGFloat = 9

    var body: some View {
        Canvas { context, size in
            // Stripes follow x + y = intercept, so shifting the intercept by d
            // moves the tape d/√2 across it. One yellow stripe plus one black gap
            // therefore needs an intercept step of two perpendicular widths times
            // √2; stepping by twice the width alone would crowd out the black.
            let pitch = stripeWidth*2*sqrt(2)
            let length = (size.width + size.height)*1.5
            var intercept = stripeWidth/2
            while intercept < size.width + size.height {
                var stripe = context
                stripe.translateBy(x: intercept - size.height/2, y: size.height/2)
                stripe.rotate(by: .degrees(-45))
                stripe.fill(Path(CGRect(x: -length/2, y: -stripeWidth/2,
                                        width: length, height: stripeWidth)),
                            with: .color(HazardPalette.yellow))
                intercept += pitch
            }
        }
        .frame(height: height)
        .mask {
            LinearGradient(stops: [.init(color: .black, location: 0),
                                   .init(color: .black, location: 0.6),
                                   .init(color: .clear, location: 1)],
                           startPoint: .top, endPoint: .bottom)
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

#if DEBUG
/// Open Package.swift in Xcode to tune stripe pitch and the fade while watching
/// the tape render.
#Preview("Hazard tape") {
    HazardStripeBand()
        .frame(width: 600)
        .background(Color.black)
        .padding(40)
        .background(Color(red: 0.13, green: 0.13, blue: 0.14))
}
#endif
