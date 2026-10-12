import Foundation

/// How the RF channel synthesizes its thermal-noise samples.
public enum TVNoiseGenerator: String, Codable, Sendable {
    /// One serial Box-Muller stream covering the whole frame. This is the exact
    /// historical sequence, so the reference and accelerated paths stay
    /// sample-comparable and a session is reproducible bit for bit.
    case sequentialBoxMuller
    /// Independent Box-Muller streams over disjoint sample ranges, evaluated
    /// concurrently. The distribution, noise power and whiteness are identical;
    /// only the particular realization differs from the serial sequence.
    case parallelBoxMuller
}

/// Cost/quality profile for the unified vision + companion-carrier chain.
///
/// `full` is the reference configuration and the default of every entry point,
/// so desktop behaviour is unchanged unless a caller opts in. `mobile` trades
/// documented, bounded accuracy margins for sustained throughput on phone-class
/// hardware. Every field is a value the corresponding stage reads directly:
/// nothing here silently changes the signal model, the sampling rates or the
/// filter designs that are not named.
public struct TVChainProfile: Codable, Equatable, Sendable {
    /// Companion band-limit/upsample kernel radius (taps = 2*radius+1) used when
    /// the narrowband sound envelope is placed on the vision RF grid. Shortening
    /// it was measured to leak companion interpolation images into the picture
    /// (peak RGB error 0.029 at radius 5, 0.057 at 4 and 0.086 at 3 for PAL;
    /// 0.025, 0.57 and 0.80 for NTSC), so the reference value is kept.
    public var soundUpsampleRadius: Int
    /// Phase-table resolution of that interpolation kernel. This changes the
    /// phase quantization only; it does not change the per-output cost.
    public var soundUpsamplePhases: Int
    /// Companion extraction kernel radius from the shared IF.
    public var soundExtractionRadius: Int
    /// Sum the companion interpolation taps in single precision. The kernel,
    /// its length and the tap positions are unchanged, so this cannot add
    /// spectral leakage: only the rounding of the sum moves.
    public var soundResamplerSinglePrecision: Bool
    /// Integrate the FM phase from an exact integer sample schedule when the
    /// RF/PCM rate ratio is an integer. The floating-point schedule gives the
    /// same result to rounding; the integer one removes a per-sample floor and
    /// index conversion.
    public var soundSynthesisIntegerSchedule: Bool
    /// Carrier PLL phase-error feedback stride in RF samples while the carrier
    /// is already tracked. The oscillator still advances every sample; only the
    /// number of measured error updates per frame changes. 1 evaluates every
    /// sample, which is also what acquisition and loss of lock always use.
    public var carrierPLLStride: Int
    public var noiseGenerator: TVNoiseGenerator
    /// Transmitter PA anti-alias kernel radius around the 2x complex envelope.
    public var amplifierAntiAliasRadius: Int
    /// PA transfer-curve table points spanning 0...16 of normalized drive power.
    /// The lookup interpolates, so this sets the table density, not the curve.
    public var amplifierTablePoints: Int
    /// Sub-sample stride of the in-band cross-compression power estimate. 1
    /// averages every RF sample into its companion-rate cell.
    public var amplifierCouplingStride: Int
    /// Frames of confirmed loss after which the receiver stops paying for a
    /// full-rate search. A full-rate acquisition over a channel that has been
    /// noise for many frames cannot succeed any sooner, so the dense path is
    /// kept only long enough to cover transient dropouts.
    public var sustainedLossFrames: Int
    /// Carrier-estimation decimation once the receiver already holds lock. The
    /// estimate is still taken from the same narrowband carrier filter; the
    /// filter is evaluated on a decimated grid whose Nyquist stays far above
    /// the carrier-filter passband. 1 keeps the full-rate estimate.
    public var afcLockedDecimation: Int
    /// Averaged FFT windows per spectrum estimate.
    public var spectrumWindows: Int

    public init(soundUpsampleRadius: Int = 6, soundUpsamplePhases: Int = 512,
                soundExtractionRadius: Int = 12, soundResamplerSinglePrecision: Bool = false,
                soundSynthesisIntegerSchedule: Bool = false,
                carrierPLLStride: Int = 1, noiseGenerator: TVNoiseGenerator = .sequentialBoxMuller,
                amplifierAntiAliasRadius: Int = 12, amplifierTablePoints: Int = 8192,
                amplifierCouplingStride: Int = 1, afcLockedDecimation: Int = 1,
                sustainedLossFrames: Int = 8, spectrumWindows: Int = 8) {
        self.soundUpsampleRadius = soundUpsampleRadius
        self.soundUpsamplePhases = soundUpsamplePhases
        self.soundExtractionRadius = soundExtractionRadius
        self.soundResamplerSinglePrecision = soundResamplerSinglePrecision
        self.soundSynthesisIntegerSchedule = soundSynthesisIntegerSchedule
        self.carrierPLLStride = carrierPLLStride
        self.noiseGenerator = noiseGenerator
        self.amplifierAntiAliasRadius = amplifierAntiAliasRadius
        self.amplifierTablePoints = amplifierTablePoints
        self.amplifierCouplingStride = amplifierCouplingStride
        self.afcLockedDecimation = afcLockedDecimation
        self.sustainedLossFrames = sustainedLossFrames
        self.spectrumWindows = spectrumWindows
    }

    /// Reference configuration. Every stage runs at the resolution the signal
    /// model was validated at, and the noise channel keeps its serial sequence.
    public static let full = TVChainProfile()

    /// Phone-class configuration, and what each reduction was measured to cost
    /// against the reference chain on a damaged unified PAL/NTSC channel:
    /// single-precision companion interpolation taps (no kernel change),
    /// the exact integer FM schedule, a 2-sample carrier-PLL feedback stride
    /// (<=0.003 PAL / <=0.005 NTSC peak RGB error), concurrent noise streams
    /// with the reference Box-Muller distribution, a smaller PA curve table and
    /// a sub-sampled cross-compression estimate (<=0.001), an 8x
    /// carrier-estimation decimation while locked (0.000), and two spectrum
    /// windows (display only). The companion upsample kernel, the companion
    /// extraction kernel and the PA anti-alias kernel all keep their reference
    /// length: shortening each was measured to buy nothing or, for the
    /// companion upsample, to leak images into the picture.
    public static let mobile = TVChainProfile(
        soundUpsampleRadius: 6, soundUpsamplePhases: 512, soundExtractionRadius: 12,
        soundResamplerSinglePrecision: true, soundSynthesisIntegerSchedule: true,
        carrierPLLStride: 2, noiseGenerator: .parallelBoxMuller, amplifierAntiAliasRadius: 12,
        amplifierTablePoints: 2048, amplifierCouplingStride: 4, afcLockedDecimation: 8,
        sustainedLossFrames: 8, spectrumWindows: 2)

    public enum CodingKeys: String, CodingKey {
        case soundUpsampleRadius, soundUpsamplePhases, soundExtractionRadius
        case soundResamplerSinglePrecision, soundSynthesisIntegerSchedule, carrierPLLStride, noiseGenerator
        case amplifierAntiAliasRadius, amplifierTablePoints, amplifierCouplingStride
        case afcLockedDecimation, sustainedLossFrames, spectrumWindows
    }

    /// Unknown or missing keys fall back to the reference value, so a session
    /// written before a field existed still decodes.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = TVChainProfile.full
        soundUpsampleRadius = try c.decodeIfPresent(Int.self,forKey: .soundUpsampleRadius) ?? d.soundUpsampleRadius
        soundUpsamplePhases = try c.decodeIfPresent(Int.self,forKey: .soundUpsamplePhases) ?? d.soundUpsamplePhases
        soundExtractionRadius = try c.decodeIfPresent(Int.self,forKey: .soundExtractionRadius) ?? d.soundExtractionRadius
        soundResamplerSinglePrecision = try c.decodeIfPresent(Bool.self,forKey: .soundResamplerSinglePrecision) ?? d.soundResamplerSinglePrecision
        soundSynthesisIntegerSchedule = try c.decodeIfPresent(Bool.self,forKey: .soundSynthesisIntegerSchedule) ?? d.soundSynthesisIntegerSchedule
        carrierPLLStride = try c.decodeIfPresent(Int.self,forKey: .carrierPLLStride) ?? d.carrierPLLStride
        noiseGenerator = try c.decodeIfPresent(TVNoiseGenerator.self,forKey: .noiseGenerator) ?? d.noiseGenerator
        amplifierAntiAliasRadius = try c.decodeIfPresent(Int.self,forKey: .amplifierAntiAliasRadius) ?? d.amplifierAntiAliasRadius
        amplifierTablePoints = try c.decodeIfPresent(Int.self,forKey: .amplifierTablePoints) ?? d.amplifierTablePoints
        amplifierCouplingStride = try c.decodeIfPresent(Int.self,forKey: .amplifierCouplingStride) ?? d.amplifierCouplingStride
        afcLockedDecimation = try c.decodeIfPresent(Int.self,forKey: .afcLockedDecimation) ?? d.afcLockedDecimation
        sustainedLossFrames = try c.decodeIfPresent(Int.self,forKey: .sustainedLossFrames) ?? d.sustainedLossFrames
        spectrumWindows = try c.decodeIfPresent(Int.self,forKey: .spectrumWindows) ?? d.spectrumWindows
    }

    public func validate() throws {
        guard (1...24).contains(soundUpsampleRadius), (2...4096).contains(soundUpsamplePhases),
              (4...48).contains(soundExtractionRadius), (1...64).contains(carrierPLLStride),
              (2...24).contains(amplifierAntiAliasRadius), (256...16384).contains(amplifierTablePoints),
              (1...64).contains(amplifierCouplingStride), (1...64).contains(afcLockedDecimation),
              (1...600).contains(sustainedLossFrames),
              (1...32).contains(spectrumWindows),
              amplifierTablePoints % 16 == 0 else { throw TVError.invalidSettings }
    }
}
