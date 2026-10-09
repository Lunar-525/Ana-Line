import XCTest
@testable import AnalogGUI

final class TVAudioOutputTests: XCTestCase {
    func testQueueWrapAndUnderrunDoNotAdvanceMediaClock() throws {
        let queue = TVPCMQueue(capacity: 8)
        var output = [Float](repeating: -1,count: 6)
        try queue.append([1,2,3,4,5])
        output.withUnsafeMutableBufferPointer { queue.read(into: $0.baseAddress!,count: 3) }
        XCTAssertEqual(Array(output.prefix(3)),[1,2,3])
        try queue.append([6,7,8,9,10,11])
        XCTAssertThrowsError(try queue.append([12]))
        output.withUnsafeMutableBufferPointer { queue.read(into: $0.baseAddress!,count: 6) }
        XCTAssertEqual(output,[4,5,6,7,8,9])
        output.withUnsafeMutableBufferPointer { queue.read(into: $0.baseAddress!,count: 6) }
        XCTAssertEqual(output,[10,11,0,0,0,0])
        XCTAssertEqual(queue.snapshot.consumed,11)
        XCTAssertEqual(queue.snapshot.underrun,4)
        XCTAssertEqual(queue.snapshot.pending,0)
    }

    @MainActor
    func testAudioEngineActuallyConsumesPCMAndMuteDoesNotStopClock() async throws {
        let output = TVAudioOutput(); output.muted = true
        defer { output.stop() }
        try output.prepare()
        try output.append((0..<9600).map { Float(sin(Double($0)*0.1))*0.1 })
        try output.start()
        let deadline = ContinuousClock.now.advanced(by: .seconds(3))
        while output.consumedSamples < 9600 && ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertEqual(output.consumedSamples,9600,"The native output callback must render PCM")
        XCTAssertEqual(output.pendingSeconds,0)
        output.stop()
        XCTAssertEqual(output.consumedSamples,0)
        XCTAssertEqual(output.pendingSeconds,0)
    }
}
