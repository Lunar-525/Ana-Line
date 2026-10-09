import Foundation
import AnalogCore
import AnalogImaging

/// Per-run tail measurements, independent of average throughput. Keeping these
/// off @Published avoids invalidating the window for every timing observation.
struct TVPlaybackMetrics {
    private(set) var producedFrames = 0
    private(set) var maximumProductionSeconds = 0.0
    private(set) var maximumRenderSeconds = 0.0
    private(set) var maximumDeliveryOverheadSeconds = 0.0
    private(set) var worstFrameStages = [Double]()
    private(set) var worstRFStages = [Double]()
    private(set) var productionDeadlineMisses = 0
    private(set) var presentedFrames = 0
    private(set) var maximumPresentationGap = 0.0
    private(set) var maximumPresentationLateness = 0.0
    private(set) var skippedFrames: Int64 = 0
    private var previousPresentation: ContinuousClock.Instant?
    private var previousFrame: Int64?

    mutating func produced(seconds: Double, frameDuration: Double, preview: TVRenderer.Preview) {
        producedFrames += 1
        if seconds > maximumProductionSeconds {
            worstFrameStages = [preview.sourceSeconds,preview.encodeSeconds,preview.decodeSeconds,preview.outputSeconds]
            let t = preview.reception.timings
            worstRFStages = [t.modulation,t.channel,t.tuner,t.carrier,t.synchronization,t.videoDecode,preview.reception.soundSeconds]
        }
        maximumProductionSeconds = max(maximumProductionSeconds,seconds)
        let renderSeconds = preview.totalSeconds-preview.prerollSeconds
        maximumRenderSeconds = max(maximumRenderSeconds,renderSeconds)
        maximumDeliveryOverheadSeconds = max(maximumDeliveryOverheadSeconds,seconds-renderSeconds)
        if seconds > frameDuration { productionDeadlineMisses += 1 }
    }
    mutating func presented(frame: Int64, lateness: Double, now: ContinuousClock.Instant = .now) {
        if let previousPresentation {
            maximumPresentationGap = max(maximumPresentationGap,Self.seconds(previousPresentation.duration(to: now)))
        }
        if let previousFrame { skippedFrames += max(0,frame-previousFrame-1) }
        maximumPresentationLateness = max(maximumPresentationLateness,lateness)
        previousPresentation = now; previousFrame = frame; presentedFrames += 1
    }
    static func seconds(_ duration: Duration) -> Double {
        let c = duration.components
        return Double(c.seconds)+Double(c.attoseconds)/1e18
    }
}

/// A bounded lead shared by a background producer and the main-actor presenter.
/// Never hold this lock while rendering, updating UI, or acquiring the PCM lock.
final class TVPlaybackBuffer: @unchecked Sendable {
    private let lock = NSLock()
    private var pending = [(start: Double, preview: TVRenderer.Preview)]()
    private var presentedFrame: Int64?
    private var timings = TVPlaybackMetrics()
    private var channel: TerrestrialSettings
    init(settings: TerrestrialSettings) { channel = settings }
    var settings: TerrestrialSettings {
        get { lock.withLock { channel } }
        set { lock.withLock { channel = newValue } }
    }
    var metrics: TVPlaybackMetrics { lock.withLock { timings } }
    var lastPreview: TVRenderer.Preview? { lock.withLock { pending.last?.preview } }
    func append(_ preview: TVRenderer.Preview, frameRate: Double) {
        lock.withLock { pending.append((Double(preview.frameIndex)/frameRate,preview)) }
    }
    func produced(seconds: Double, frameDuration: Double, preview: TVRenderer.Preview) {
        lock.withLock { timings.produced(seconds: seconds,frameDuration: frameDuration,preview: preview) }
    }
    func visible(at mediaTime: Double) -> TVRenderer.Preview? {
        lock.withLock {
            while pending.count > 1 && pending[1].start <= mediaTime { pending.removeFirst() }
            guard let frame = pending.first, frame.start <= mediaTime,
                  presentedFrame != frame.preview.frameIndex else { return nil }
            timings.presented(frame: frame.preview.frameIndex,lateness: mediaTime-frame.start)
            presentedFrame = frame.preview.frameIndex
            return frame.preview
        }
    }
}
