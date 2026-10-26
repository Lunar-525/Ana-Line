import Foundation

/// Conventional CRT phosphors plus explicitly labelled patent geometries.
/// Keep persisted raw values stable when adding arrangements.
enum TVCRTMaskType: Int, CaseIterable, Identifiable {
    case apertureGrille = 0
    case shadowMask = 1
    case slotMask = 2
    case inlineShadowMask = 3
    case hexagonalMask = 4
    case horizontalStripes = 5
    case beamIndex = 6

    var id: Int { rawValue }

    var title: String {
        switch self {
        case .apertureGrille: return "Aperture grille"
        case .shadowMask: return "Shadow mask (dot triad)"
        case .slotMask: return "Slot mask"
        case .inlineShadowMask: return "Inline shadow mask"
        case .hexagonalMask: return "Hexagonal phosphors (experimental)"
        case .horizontalStripes: return "Horizontal RGB stripes (experimental)"
        case .beamIndex: return "Beam-index vertical stripes"
        }
    }

    var detail: String {
        switch self {
        case .apertureGrille:
            return "Vertical stripes with damping wires."
        case .shadowMask:
            return "Round RGB dots on a close-packed triangular lattice."
        case .slotMask:
            return "Staggered vertical slots."
        case .inlineShadowMask:
            return "Vertical dots in a straight row."
        case .hexagonalMask:
            return "Hexagonal RGB cells; experimental patent geometry."
        case .horizontalStripes:
            return "Horizontal RGB bands; experimental beam-index geometry."
        case .beamIndex:
            return "RGB stripes without damping wires; index layer is not visible."
        }
    }
}

/// CPU-side aperture description. `meanFill` is the integrated aperture
/// fraction used to keep the sub-pixel fallback at the same average light.
struct TVCRTMaskStyle {
    let type: TVCRTMaskType
    let fillH: Double
    let fillV: Double
    let radius: Double
    let meanFill: Double
    let stagger: Double

    var hasDamperWires: Bool { type == .apertureGrille }

    static func make(type: Int, mask: Double) -> TVCRTMaskStyle {
        let kind = TVCRTMaskType(rawValue: type) ?? .apertureGrille
        let m = mask.isFinite ? min(1, max(0, mask)) : 0.8
        let baseH = 1 - 0.45 * m
        let baseV = 1 - 0.15 * m
        switch kind {
        case .apertureGrille:
            // Vertical stripes have no horizontal mask gap. The two damping
            // wires remove a tiny fraction of the aperture.
            return TVCRTMaskStyle(type: kind, fillH: baseH, fillV: 1, radius: 0,
                meanFill: baseH * 0.997, stagger: 0)
        case .shadowMask:
            // Triangular lattice: dot spacing 1, row spacing sqrt(3)/2.
            let r = 0.46 - 0.10 * m
            return TVCRTMaskStyle(type: kind, fillH: 0, fillV: 0, radius: r,
                meanFill: Double.pi * r * r / (sqrt(3) / 2), stagger: 0)
        case .hexagonalMask:
            // Hexagon apothem; the un-gapped Voronoi cell has apothem 0.5.
            let a = 0.46 - 0.10 * m
            return TVCRTMaskStyle(type: kind, fillH: 0, fillV: 0, radius: a,
                meanFill: 4 * a * a, stagger: 0)
        case .horizontalStripes:
            return TVCRTMaskStyle(type: kind, fillH: 1, fillV: baseH, radius: 0,
                meanFill: baseH, stagger: 0)
        case .beamIndex:
            let fill = 1 - 0.25 * m
            return TVCRTMaskStyle(type: kind, fillH: fill, fillV: 1, radius: 0,
                meanFill: fill, stagger: 0)
        case .slotMask:
            // Taller, staggered slots leave a smaller vertical gap than the
            // old inline/slot approximation.
            let v = 1 - 0.08 * m
            return TVCRTMaskStyle(type: kind, fillH: baseH, fillV: v, radius: 0,
                meanFill: baseH * v, stagger: 1.0 / 6.0)
        case .inlineShadowMask:
            return TVCRTMaskStyle(type: kind, fillH: baseH, fillV: baseV, radius: 0,
                meanFill: baseH * baseV, stagger: 0)
        }
    }
}
