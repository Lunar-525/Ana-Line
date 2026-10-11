import Accelerate
import Foundation

/// FFT-shifted, window-energy-normalized power per bin. Frequencies are relative
/// to the nominal transmitted vision carrier; this is an actual received RF
/// IQ tap, before receiver tuning, IF filtering, and AGC.
public struct TVSpectrum: Sendable {
    public let sampleRate: Double
    public let centerHz: Double
    public let powerDB: [Float]
    public var binHz: Double { sampleRate / Double(powerDB.count) }
    public var resolutionHz: Double { binHz * 1.5 } // Hann equivalent noise bandwidth
}

/// The FFT plan and window are immutable; each call owns all working buffers.
final class TVSpectrumAnalyzer: @unchecked Sendable {
    private let fft: FFTSetup
    private let log2Size: vDSP_Length
    private let window: [Float]
    private let normalization: Float
    init(log2Size: vDSP_Length = 11) {
        self.log2Size = log2Size
        fft = vDSP_create_fftsetup(log2Size, FFTRadix(kFFTRadix2))!
        let size = 1 << Int(log2Size)
        window = (0..<size).map { Float(0.5 - 0.5 * cos(2 * .pi * Double($0) / Double(size))) }
        normalization = 1 / (Float(size) * window.reduce(0) { $0 + $1 * $1 })
    }
    deinit { vDSP_destroy_fftsetup(fft) }
    /// `windows` limits how many short windows are averaged. Power is normalized
    /// by the window count, so this changes the variance of the estimate (and
    /// therefore the refresh cost), never its mean.
    func analyze(i: [Float], q: [Float], rate: Double, centerHz: Double = 0,
                 windows requestedWindows: Int = 8) -> TVSpectrum? {
        let size = window.count
        guard i.count == q.count, i.count >= size, rate.isFinite, rate > 0 else { return nil }
        var re = [Float](repeating: 0, count: size), im = re
        var powers = re
        // Average short windows distributed across the frame. Do not decimate IQ:
        // that would alias the VSB sidebands into the displayed band.
        let windows = min(max(1,requestedWindows), i.count / size)
        i.withUnsafeBufferPointer { ip in
            q.withUnsafeBufferPointer { qp in
                for segment in 0..<windows {
                    let offset = windows == 1 ? 0 : segment * (i.count - size) / (windows - 1)
                    for n in 0..<size {
                        re[n] = ip[offset+n] * window[n]; im[n] = qp[offset+n] * window[n]
                    }
                    re.withUnsafeMutableBufferPointer { r in
                        im.withUnsafeMutableBufferPointer { m in
                            var iq = DSPSplitComplex(realp: r.baseAddress!, imagp: m.baseAddress!)
                            // Full complex FFT: real-to-complex packed FFT APIs
                            // cannot represent these independent I and Q samples.
                            vDSP_fft_zip(fft, &iq, 1, log2Size, FFTDirection(kFFTDirection_Forward))
                        }
                    }
                    for n in 0..<size { powers[n] += (re[n]*re[n] + im[n]*im[n]) * normalization / Float(windows) }
                }
            }
        }
        let shifted = (0..<size).map { 10 * log10(max(1e-12, powers[($0+size/2)%size])) }
        return TVSpectrum(sampleRate: rate, centerHz: centerHz, powerDB: shifted)
    }
}
