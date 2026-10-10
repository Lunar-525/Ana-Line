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
    private var resolvedFrame: Int64?

    init(firstFrame: Int64? = nil) { resolvedFrame = firstFrame.map { $0-1 } }
    mutating func dropped(through frame: Int64) {
        if let resolvedFrame,frame > resolvedFrame {
            skippedFrames += frame-resolvedFrame; self.resolvedFrame = frame
        }
    }

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
        if let resolvedFrame { skippedFrames += max(0,frame-resolvedFrame-1) }
        maximumPresentationLateness = max(maximumPresentationLateness,lateness)
        previousPresentation = now; resolvedFrame = frame; presentedFrames += 1
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
    private var latest: TVRenderer.Preview?
    private var presentedFrame: Int64?
    private var timings = TVPlaybackMetrics()
    private var channel: TerrestrialSettings
    private let frameRate: Double
    let capacity: Int
    init(settings: TerrestrialSettings,capacity: Int = 8,firstFrame: Int64 = 0,frameRate: Double = 25) {
        channel = settings; self.capacity = max(1,capacity); self.frameRate = frameRate
        timings = TVPlaybackMetrics(firstFrame: firstFrame)
    }
    var settings: TerrestrialSettings {
        get { lock.withLock { channel } }
        set { lock.withLock { channel = newValue } }
    }
    var metrics: TVPlaybackMetrics { lock.withLock { timings } }
    var lastPreview: TVRenderer.Preview? { lock.withLock { latest } }
    var queuedFrames: Int { lock.withLock { pending.count } }
    func append(_ preview: TVRenderer.Preview, frameRate: Double) {
        lock.withLock {
            latest = preview
            pending.append((Double(preview.frameIndex)/frameRate,preview))
            while pending.count > capacity {
                let dropped = pending.removeFirst(); timings.dropped(through: dropped.preview.frameIndex)
            }
        }
    }
    func produced(seconds: Double, frameDuration: Double, preview: TVRenderer.Preview) {
        lock.withLock { timings.produced(seconds: seconds,frameDuration: frameDuration,preview: preview) }
    }
    func visible(at mediaTime: Double) -> TVRenderer.Preview? {
        lock.withLock {
            let expired = Int64(floor(mediaTime*frameRate+1e-7))-1
            while let frame = pending.first,frame.preview.frameIndex <= expired { pending.removeFirst() }
            timings.dropped(through: expired)
            guard let frame = pending.first, frame.start <= mediaTime,
                  presentedFrame != frame.preview.frameIndex else { return nil }
            timings.presented(frame: frame.preview.frameIndex,lateness: mediaTime-frame.start)
            presentedFrame = frame.preview.frameIndex
            pending.removeFirst()
            return frame.preview
        }
    }
}
