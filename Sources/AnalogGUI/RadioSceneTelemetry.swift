import Foundation

/// Cheap counters that attribute SwiftUI work without a profiler attached.
/// Equivalent to the SwiftUI update analysis and time profiler instruments:
/// they answer "how wide is one invalidation?" and "how long does the parameter
/// hand-off hold its lock?".
enum RadioSceneTelemetry {
    nonisolated(unsafe) static var sceneBodies = 0
    nonisolated(unsafe) static var cardBodies = 0
    nonisolated(unsafe) static var spectrumBodies = 0
    nonisolated(unsafe) static var canvasDraws = 0
    nonisolated(unsafe) static var knobDragPushNanos = 0
    nonisolated(unsafe) static var knobDragPushes = 0
    static func reset() {
        sceneBodies = 0; cardBodies = 0; spectrumBodies = 0; canvasDraws = 0
        knobDragPushNanos = 0; knobDragPushes = 0
    }
}
