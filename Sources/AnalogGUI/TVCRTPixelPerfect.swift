import Foundation
import CoreGraphics

/// Geometry for stripe masks rendered point-to-point.
///
/// A stripe mask has three phosphor stripes per simulated pixel. To keep those
/// stripes on whole display pixels, the cell must be `3 × stripeScale` pixels
/// wide and tall. When that integer raster is smaller than the drawable it is
/// centred with black bars; when the requested line count is too high for even
/// a 1-pixel stripe, the line count is capped instead of falling back to a
/// fractional stripe pitch.
struct TVCRTPixelPerfect: Equatable {
    struct Fit: Equatable {
        let rows: Int
        let stripeScale: Int
    }
    let rows: Int
    let triads: Int
    let stripeScale: Int
    let rect: CGRect
    let cappedFrom: Int?

    static let stripeTypes: Set<Int> = [
        TVCRTMaskType.apertureGrille.rawValue,
        TVCRTMaskType.slotMask.rawValue,
        TVCRTMaskType.inlineShadowMask.rawValue,
        TVCRTMaskType.horizontalStripes.rawValue,
        TVCRTMaskType.beamIndex.rawValue,
    ]

    static func isStripe(_ type: Int) -> Bool { stripeTypes.contains(type) }

    /// Largest line count that can be shown with at least a one-pixel stripe.
    static func lineCap(drawableSize: CGSize, aspect: Double) -> Int? {
        let width = drawableSize.width.isFinite ? Double(drawableSize.width) : 0
        let height = drawableSize.height.isFinite ? Double(drawableSize.height) : 0
        let a = aspect.isFinite && aspect > 0 ? aspect : 4.0 / 3.0
        guard width > 0, height > 0 else { return nil }
        let cap = min(Int(floor(height / 3)), Int(floor(width / (3 * a))))
        return cap >= 120 ? cap : nil
    }

    /// Largest full-frame line count that still fits the broadcast standard
    /// with an integer stripe width. 367 on a 2202-pixel-high 4:3 drawable is
    /// `floor(2202 / 6)`: 367 rows at a 2-pixel stripe, rather than 734 rows
    /// (1-pixel stripes) which exceeds the PAL 576-line limit.
    static func bestFit(drawableSize: CGSize, maximumRows: Int,
                        aspect: Double) -> Fit? {
        let width = drawableSize.width.isFinite ? max(1, Double(drawableSize.width)) : 0
        let height = drawableSize.height.isFinite ? max(1, Double(drawableSize.height)) : 0
        let a = aspect.isFinite && aspect > 0 ? aspect : 4.0 / 3.0
        guard width > 0, height > 0 else { return nil }
        let standard = max(120, maximumRows)
        let cap = min(height / 3, width / (3 * a))
        guard cap >= 120 else { return nil }
        let stripeScale = max(1, Int(ceil(cap / Double(standard))))
        let rows = min(standard, Int(floor(cap / Double(stripeScale))))
        guard rows >= 120 else { return nil }
        return Fit(rows: rows, stripeScale: stripeScale)
    }

    static func make(drawableSize: CGSize, requestedRows: Int, maximumRows: Int,
                     aspect: Double, maskType: Int, enabled: Bool) -> Self? {
        guard enabled, isStripe(maskType),
              let cap = lineCap(drawableSize: drawableSize, aspect: aspect) else { return nil }
        let width = max(1, Double(drawableSize.width))
        let height = max(1, Double(drawableSize.height))
        let a = aspect.isFinite && aspect > 0 ? aspect : 4.0 / 3.0
        let requested = max(120, requestedRows)
        let rows = min(requested, min(max(120, maximumRows), cap))
        var triads = max(1, Int((Double(rows) * a).rounded()))
        let stripeScale = max(1, min(Int(floor(width / (3 * Double(triads)))),
                                      Int(floor(height / (3 * Double(rows))))))
        triads = max(1, min(triads, Int(floor(width / (3 * Double(stripeScale))))))
        let rasterWidth = 3 * triads * stripeScale
        let rasterHeight = 3 * rows * stripeScale
        let originX = max(0, Int(floor((width - Double(rasterWidth)) / 2)))
        let originY = max(0, Int(floor((height - Double(rasterHeight)) / 2)))
        return Self(rows: rows, triads: triads, stripeScale: stripeScale,
            rect: CGRect(x: Double(originX) / width, y: Double(originY) / height,
                width: min(1, Double(rasterWidth) / width),
                height: min(1, Double(rasterHeight) / height)),
            cappedFrom: requested > rows ? requested : nil)
    }
}
