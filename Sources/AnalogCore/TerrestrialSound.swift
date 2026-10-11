import Foundation
import Accelerate

public extension TerrestrialSystem {
    var soundCarrierHz: Double { self == .palDK ? 6_500_000 : 4_500_000 }
    var soundDeviationHz: Double { self == .palDK ? 50_000 : 25_000 }
    var soundEmphasisSeconds: Double { self == .palDK ? 50e-6 : 75e-6 }
}

/// Integer boundaries keep 48 kHz PCM contiguous at 30000/1001 fps as well as 25 fps.
public enum TVSoundClock {
    public static let pcmRate = 48_000
    public static func offset(frame: Int64, standard: TVStandard, rate: Int = pcmRate) -> Int64 {
        standard == .pal ? frame * Int64(rate) / 25 : frame * Int64(rate) * 1001 / 30000
    }
    public static func count(frame: Int64, standard: TVStandard, rate: Int = pcmRate) -> Int {
        Int(offset(frame: frame+1,standard: standard,rate: rate)-offset(frame: frame,standard: standard,rate: rate))
    }
}

public struct TerrestrialSoundReception: Sendable {
    public let samples: [Float]
    public let carrierDB: Float
    public let seconds: Double
    public let spectrum: TVSpectrum?
    public var transmitter = TVTransmitterTelemetry()
}

/// Legacy reference path: one call still runs modulation, a separate narrowband
/// RF channel and reception. The transmit and receive halves are now
/// TVSoundModulator and TVSoundDemodulator; this type remains as the
/// behavioural baseline until the unified channel replaces it.
public struct TerrestrialSoundEngine: Sendable {
    public let system: TerrestrialSystem
    private let spectrumAnalyzer = TVSpectrumAnalyzer(log2Size: 9)
    static let rate = 384_000
    private var channel: TerrestrialRFChannel
    private var amplifier = TVTransmitterAmplifier()
    private var modulator: TVSoundModulator
    private var demodulator: TVSoundDemodulator

    public init(system: TerrestrialSystem, seed: UInt64 = 42) {
        self.system = system
        channel = TerrestrialRFChannel(seed: seed ^ 0x534f554e44)
        modulator = TVSoundModulator(system: system)
        demodulator = TVSoundDemodulator(system: system)
    }

    public mutating func process(_ pcm: [Float], frameIndex: Int64, settings: TerrestrialSettings,
                                 visionCorrectionHz: Double = 0, receiverGain: Float = 1, visionPower: [Float] = []) throws -> TerrestrialSoundReception {
        let started = ContinuousClock.now
        guard frameIndex >= 0, frameIndex < 1_000_000_000,
              pcm.count == TVSoundClock.count(frame: frameIndex,standard: system.video),
              pcm.allSatisfy(\.isFinite), visionCorrectionHz.isFinite, receiverGain.isFinite, receiverGain > 0,
              visionPower.allSatisfy({ $0.isFinite && $0 >= 0 }) else { throw TVError.invalidSignal }
        try settings.validate(rate: system.video.sampleRate)
        let rate = Double(Self.rate)
        let rfStart = TVSoundClock.offset(frame: frameIndex,standard: system.video,rate: Self.rate)
        let signal = modulator.modulate(pcm,frameIndex: frameIndex,settings: settings,rate: rate)
        var i = signal.i, q = signal.q
        (i,q) = amplifier.apply(i: i,q: q,settings: settings.transmitter,execution: settings.execution,
                                otherPower: visionPower,profile: settings.performance)
        var meter = TVTransmitterTelemetry()
        meter.forwardPower = amplifier.meanOutputPower
        meter.reflectedPower = meter.forwardPower*settings.transmitter.reflectedFraction
        meter.saturated = settings.transmitter.enabled && amplifier.peakDrivePower >= pow(10,settings.transmitter.backoffDB/10)
        meter.overmodulated = modulator.overmodulated
        TVTransmitterSettings.deliver(i: &i,q: &q,settings: settings.transmitter)
        (i,q) = channel.transmit(i: i,q: q,rate: rate,carrierOffsetHz: system.soundCarrierHz,
                                noiseReferenceRate: system.video.sampleRate,time: Double(rfStart)/rate,settings: settings)
        // Fixed RF coordinates, after propagation but before the tuner / IF.
        let spectrum = spectrumAnalyzer.analyze(i: i,q: q,rate: rate,centerHz: system.soundCarrierHz,
                                                windows: settings.performance.spectrumWindows)
        let recovered = demodulator.demodulate(
            TVSoundIQ(system: system,frameIndex: frameIndex,sampleRate: rate,i: i,q: q),
            settings: settings,visionCorrectionHz: visionCorrectionHz,receiverGain: receiverGain)
        return TerrestrialSoundReception(samples: recovered.samples,carrierDB: recovered.carrierDB,
            seconds: TerrestrialTimings.seconds(started.duration(to: .now)),spectrum: spectrum,transmitter: meter)
    }
}
