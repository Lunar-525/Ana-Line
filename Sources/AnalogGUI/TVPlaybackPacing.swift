import Foundation
import AnalogCore

/// A fixed playback clock: producer overload is handled by frame drops, never
/// by stretching audio or slowing the movie.
enum TVPlaybackPacing {
    static func nextFrame(after requested: Int64,consumedSamples: Int64,startSample: Int64,standard: TVStandard,leadSeconds: Double = 0) -> Int64 {
        let now = (Double(startSample+consumedSamples)/48_000+max(0,leadSeconds))*standard.frameRate
        return max(requested,Int64(ceil(now-1e-7)))
    }
}
