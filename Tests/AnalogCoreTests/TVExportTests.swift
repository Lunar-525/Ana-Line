import XCTest
import AnalogCore
@testable import AnalogImaging

@MainActor
final class TVExportTests: XCTestCase {
    func testFullAndFastExportContinuousVideoAndRecoveredAudio() async throws {
        let path = "/usr/bin:/bin:/usr/sbin:/sbin"
        guard let ffmpeg = TVExecutableResolver.find("ffmpeg", path: path),
              let ffprobe = TVExecutableResolver.find("ffprobe", path: path) else {
            throw XCTSkip("ffmpeg and ffprobe required")
        }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = directory.appendingPathComponent("source.mkv")
        let generate = Process(); generate.executableURL = ffmpeg
        generate.arguments = ["-v", "error", "-f", "lavfi", "-i", "testsrc2=size=160x120:rate=25",
            "-f", "lavfi", "-i", "sine=frequency=700:sample_rate=48000", "-t", "0.24",
            "-c:v", "ffv1", "-c:a", "pcm_f32le", source.path]
        try generate.run(); generate.waitUntilExit()
        XCTAssertEqual(generate.terminationStatus, 0)
        for standard in TVStandard.allCases {
            for fast in [false, true] {
                let renderer = TVRenderer(executableSearchPath: path)
                let duration = try await renderer.loadVideo(source, standard: standard)
                var settings = TerrestrialSettings(system: TerrestrialSystem(video: standard))
                settings.performance = fast ? .mobile : .full
                let destination = directory.appendingPathComponent("\(standard.rawValue)-\(fast).mov")
                let result = try await renderer.exportVideo(to: destination, channel: settings) { _ in }
                XCTAssertEqual(result.fraction, 1)
                XCTAssertGreaterThan(result.speed, 0)
                let probe = Process(); probe.executableURL = ffprobe
                probe.arguments = ["-v", "error", "-show_streams", "-of", "json", destination.path]
                let pipe = Pipe(); probe.standardOutput = pipe
                try probe.run()
                let data = pipe.fileHandleForReading.readDataToEndOfFile(); probe.waitUntilExit()
                XCTAssertEqual(probe.terminationStatus, 0)
                let json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
                let streams = try XCTUnwrap(json["streams"] as? [[String: Any]])
                let video = try XCTUnwrap(streams.first { $0["codec_type"] as? String == "video" })
                XCTAssertEqual(video["width"] as? Int, standard.width)
                XCTAssertEqual(video["height"] as? Int, standard.height)
                XCTAssertEqual(video["display_aspect_ratio"] as? String, "4:3")
                XCTAssertEqual(Int(video["nb_frames"] as? String ?? ""), Int((duration*standard.frameRate+1e-7).rounded(.down)))
                let audio = try XCTUnwrap(streams.first { $0["codec_type"] as? String == "audio" })
                XCTAssertEqual(audio["sample_rate"] as? String, "48000")
                XCTAssertEqual(audio["channels"] as? Int, 1)
                let originalOutput = try Data(contentsOf: destination)
                let cancelled = Task { try await renderer.exportVideo(to: destination, channel: settings) { _ in } }
                cancelled.cancel()
                do {
                    _ = try await cancelled.value
                    XCTFail("Cancelled export must throw")
                } catch is CancellationError { }
                XCTAssertEqual(try Data(contentsOf: destination), originalOutput)
                await renderer.unloadVideo()
            }
        }
    }
}
