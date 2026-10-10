import Foundation

/// One physical RF impulse. Its identity and time also travel with the decoded
/// frame, so a buffered receiver can show the same strike when it is presented.
public struct TVLightningEvent: Equatable, Sendable {
    public let token: UInt64
    public let time: Double
    public let intensity: Float
    public static let pulseDuration = 0.003
}

public enum TVLightningTimeline {
    /// Returns impulses overlapping this half-open interval on the media clock.
    public static func events(time: Double, duration: Double, seed: UInt64,
                              settings: TVPropagationSettings) -> [TVLightningEvent] {
        let intensity = settings.weather.lightning, rate = settings.weather.lightningRatePerMinute
        guard settings.enabled, settings.weather.enabled, intensity.isFinite, intensity > 0,
              rate.isFinite, rate > 0,
              time.isFinite, duration.isFinite, time >= 0, duration > 0 else { return [] }
        let end = time+duration
        let first = max(0,Int(floor(time*4))-1), last = max(0,Int(floor(end*4)))
        var result = [TVLightningEvent]()
        for cell in first...last {
            let random = hash(seed &+ UInt64(cell) &* 0x9e3779b9)
            // Four deterministic candidates per second. Only the requested
            // average rate admits candidates; intensity cannot move an event.
            guard Double(random & 0xffff)/65536 < Double(min(120,rate))/240 else { continue }
            let eventTime = Double(cell)*0.25+0.02+Double((random >> 16)&0xffff)/65535*0.20
            if eventTime < end && eventTime+TVLightningEvent.pulseDuration > time {
                result.append(TVLightningEvent(token: random,time: eventTime,intensity: intensity))
            }
        }
        return result
    }

    static func hash(_ input: UInt64) -> UInt64 {
        var z = input &+ 0x9e3779b97f4a7c15
        z = (z ^ (z >> 30)) &* 0xbf58476d1ce4e5b9
        z = (z ^ (z >> 27)) &* 0x94d049bb133111eb
        return z ^ (z >> 31)
    }
}
