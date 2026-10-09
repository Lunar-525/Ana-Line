import Foundation

/// Protect remaining FIFO headroom using recent worst production latency.
/// A healthy buffer plays at 1x, even after a transient producer stall.
struct TVPlaybackPacing {
    private var recent = [Double]()
    mutating func requestedRate(cost: Double, frameDuration: Double, queuedSeconds: Double) -> Float {
        let measured = max(0.001,cost)
        recent.append(measured)
        if recent.count > 8 { recent.removeFirst() }
        let worst = recent.max() ?? measured
        if queuedSeconds >= frameDuration*3 || worst <= frameDuration { return 1 }
        return Float(max(0.25,min(1,frameDuration/(worst*1.02))))
    }
}
