import AVFoundation
import CoreGraphics

/// How an imported video is mapped onto the 4:3 analogue frame.
///
/// The chain always renders into the standard's raster, which is 4:3 in display
/// terms. A source that is not 4:3 therefore has to be either letterboxed — the
/// whole picture with bars — or cropped, filling the frame with the chosen 4:3
/// window. This describes the second: a window that is always 4:3, moved by its
/// centre, sized as a fraction of the largest window that fits, and turned in
/// quarter steps. AVFoundation applies it through the reader's video composition,
/// so nothing is re-encoded and the import stays as fast as a plain read.
struct MobileCrop: Equatable, Sendable {
    var quarterTurns = 0
    /// Centre of the 4:3 window, normalised inside the turned picture.
    var center = CGPoint(x: 0.5, y: 0.5)
    /// Width of the window as a fraction of the largest 4:3 window that fits.
    var zoom: CGFloat = 1

    /// The largest 4:3 window, centred: the whole picture, cropped, with nothing
    /// else chosen yet.
    static let full = MobileCrop()
    /// What a freshly imported video starts as, before any choice is made.
    static let automatic: MobileCrop? = nil

    var turns: Int { ((quarterTurns % 4) + 4) % 4 }
    var isFull: Bool { self == .full }

    /// The picture's bounds after the track's own preferred transform (portrait
    /// recordings carry their rotation there) and after this crop's quarter turns.
    static func turnedRect(upright: CGRect, quarterTurns: Int) -> CGRect {
        let turns = ((quarterTurns % 4) + 4) % 4
        let size = turns % 2 == 0 ? upright.size : CGSize(width: upright.height, height: upright.width)
        return CGRect(x: upright.midX - size.width/2, y: upright.midY - size.height/2,
                      width: size.width, height: size.height)
    }

    /// The 4:3 window inside `rect`, clamped so it always stays within the picture.
    func window(in rect: CGRect) -> CGRect {
        let largest = min(rect.width, rect.height * 4/3)
        let width = max(1, largest*max(0.1, min(1, zoom)))
        let height = width * 3/4
        let x = rect.minX + max(0, min(1, center.x)) * rect.width - width/2
        let y = rect.minY + max(0, min(1, center.y)) * rect.height - height/2
        return CGRect(x: max(rect.minX, min(rect.maxX - width, x)),
                      y: max(rect.minY, min(rect.maxY - height, y)), width: width, height: height)
    }

    /// Source track → the standard's raster, filling it with the chosen window.
    func transform(naturalSize: CGSize, preferredTransform: CGAffineTransform,
                   standard: TVStandard) -> CGAffineTransform {
        let up = CGRect(origin: .zero, size: naturalSize).applying(preferredTransform)
        let upright = CGRect(x: 0, y: 0, width: abs(up.width), height: abs(up.height))
        let turned = Self.turnedRect(upright: upright, quarterTurns: turns)
        let window = window(in: turned)
        let height = CGFloat(standard.height)
        let displayWidth = height * 4/3
        let scale = displayWidth/window.width
        // Turn the upright picture about its own centre. The window is expressed in
        // that same turned space — `turnedRect` is only a description of its bounds
        // — so the next step subtracts the window directly. Subtracting the turned
        // bounds as well would shift the picture a second time, which shows up as a
        // black band only when the turns make those bounds non-zero.
        let spin = CGAffineTransform(translationX: upright.midX, y: upright.midY)
            .rotated(by: CGFloat(turns) * CGFloat.pi / 2)
            .translatedBy(x: -upright.midX, y: -upright.midY)
        return preferredTransform
            .concatenating(CGAffineTransform(translationX: -up.minX, y: -up.minY))
            .concatenating(spin)
            .concatenating(CGAffineTransform(translationX: -window.minX, y: -window.minY))
            .concatenating(CGAffineTransform(scaleX: scale, y: scale))
            .concatenating(CGAffineTransform(translationX: 0, y: (height - window.height * scale)/2))
            .concatenating(CGAffineTransform(scaleX: CGFloat(standard.width)/displayWidth, y: 1))
    }

    /// The classic whole-picture fit, used until a window is chosen: the source is
    /// scaled to sit inside the 4:3 display box and centred, leaving bars.
    static func fitTransform(naturalSize: CGSize, preferredTransform: CGAffineTransform,
                            standard: TVStandard) -> CGAffineTransform {
        let up = CGRect(origin: .zero, size: naturalSize).applying(preferredTransform)
        let height = CGFloat(standard.height)
        let displayWidth = height * 4/3
        let scale = min(displayWidth/abs(up.width), height/abs(up.height))
        return preferredTransform
            .concatenating(CGAffineTransform(translationX: -up.minX, y: -up.minY))
            .concatenating(CGAffineTransform(scaleX: scale, y: scale))
            .concatenating(CGAffineTransform(translationX: (displayWidth-abs(up.width)*scale)/2,
                                             y: (height-abs(up.height)*scale)/2))
            .concatenating(CGAffineTransform(scaleX: CGFloat(standard.width)/displayWidth, y: 1))
    }
}
