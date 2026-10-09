import XCTest
import AnalogCore
@testable import AnalogImaging

@MainActor
final class TVRendererTests: XCTestCase {
    private let finderPath = "/usr/bin:/bin:/usr/sbin:/sbin"

    func testExecutableResolutionPrefersPATHAndFallsBackForGUI() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let preferred = directory.appendingPathComponent("preferred")
        let fallback = directory.appendingPathComponent("fallback")
        for folder in [preferred, fallback] {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            XCTAssertTrue(FileManager.default.createFile(atPath: folder.appendingPathComponent("ffmpeg").path,
                contents: Data(), attributes: [.posixPermissions: 0o755]))
        }
        XCTAssertEqual(TVExecutableResolver.find("ffmpeg", path: preferred.path,
            fallbackDirectories: [fallback.path]), preferred.appendingPathComponent("ffmpeg"))
        XCTAssertEqual(TVExecutableResolver.find("ffmpeg", path: finderPath,
            fallbackDirectories: [fallback.path]), fallback.appendingPathComponent("ffmpeg"))
        XCTAssertNil(TVExecutableResolver.find("missing-tool", path: preferred.path,
            fallbackDirectories: [fallback.path]))
    }

    func testCompositeRoundTripRecoversBothFields() throws {
        for standard in TVStandard.allCases {
            for frameIndex: Int64 in [0, 1] {
                let original = TVFrame.colorBars(standard)
                let transmission = try TVEngine.encode(original, frameIndex: frameIndex)
                let reception = try TVEngine.decode(transmission)
                XCTAssertEqual(reception.recoveredLines, standard.height, "\(standard), frame \(frameIndex)")
                XCTAssertEqual(reception.colorLockedLines, standard.height)
                for row in [standard.height / 4, standard.height / 4 + 1] {
                    for x in stride(from: 45, to: standard.width, by: 90) {
                        let index = row * standard.width + x
                        for channel in 0..<3 {
                            XCTAssertEqual(reception.frame.rgb[index][channel], original.rgb[index][channel], accuracy: 0.08)
                        }
                    }
                }
            }
        }
    }

    func testRickrollLoadsAndSeeksWithFinderPATH() async throws {
        try requireFFmpeg()
        let source = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("Assets/rickroll.mp4")
        let renderer = TVRenderer(executableSearchPath: finderPath)
        do {
            for standard in TVStandard.allCases {
                let duration = try await renderer.loadVideo(source, standard: standard)
                XCTAssertEqual(duration, 213.04, accuracy: 0.1)
                let audioURL = await renderer.playbackAudioURL()
                let audio = try XCTUnwrap(audioURL)
                XCTAssertTrue(FileManager.default.fileExists(atPath: audio.path))
                var frames = [Int64: Data]()
                for time in [0.0, standard.frameDuration, standard.frameDuration * 3,
                    10.0, 10.0 + standard.frameDuration, 10.0 + standard.frameDuration * 3,
                    0.0, 10.0 + standard.frameDuration, duration] {
                    let preview = try await renderer.render(time: time)
                    XCTAssertEqual(preview.original.width, standard.width)
                    XCTAssertEqual(preview.original.height, standard.height)
                    XCTAssertEqual(preview.image.width, standard.width)
                    XCTAssertEqual(preview.image.height, standard.height)
                    XCTAssertLessThan(Double(preview.frameIndex) / standard.frameRate, duration)
                    let bytes = try XCTUnwrap(preview.image.dataProvider?.data) as Data
                    let original = try XCTUnwrap(preview.original.dataProvider?.data) as Data
                    if let previous = frames[preview.frameIndex] {
                        XCTAssertEqual(original, previous, "Sequential reads and seeks must agree on the source frame")
                    }
                    frames[preview.frameIndex] = original
                    XCTAssertEqual(bytes.count, original.count)
                    let meanError = zip(bytes, original).reduce(0.0) { $0 + abs(Double($1.0) - Double($1.1)) } / Double(bytes.count)
                    XCTAssertLessThan(meanError, 35, "\(standard) at \(time): decoded RGB diverged from source")
                    // The clip fades from/to black; inspect contrast in its actual picture content.
                    if time == 10 { XCTAssertGreaterThan(Int(bytes.max() ?? 0) - Int(bytes.min() ?? 0), 20) }
                }
            }
        } catch {
            await renderer.unloadVideo()
            throw error
        }
        await renderer.unloadVideo()
    }

    func testSilentVideoSupportsSequentialPlaybackAndReaderRestart() async throws {
        try requireFFmpeg()
        let source = FileManager.default.temporaryDirectory.appendingPathComponent("AnaLine-silent-\(UUID().uuidString).mp4")
        defer { try? FileManager.default.removeItem(at: source) }
        let process = Process()
        process.executableURL = TVExecutableResolver.find("ffmpeg", path: finderPath)
        process.arguments = ["-hide_banner", "-loglevel", "error", "-y", "-f", "lavfi", "-i",
            "testsrc2=size=160x90:rate=25", "-t", "0.4", "-an", "-c:v", "libx264", "-pix_fmt", "yuv420p", source.path]
        process.standardOutput = FileHandle.nullDevice; process.standardError = FileHandle.nullDevice
        try process.run(); process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0)
        let renderer = TVRenderer(executableSearchPath: finderPath)
        do {
            _ = try await renderer.loadVideo(source)
            let audio = await renderer.playbackAudioURL()
            XCTAssertNil(audio)
            let first = try await renderer.render(time: 0)
            let next = try await renderer.render(time: TVStandard.pal.frameDuration)
            XCTAssertEqual(next.frameIndex, 1)
            await renderer.endPlayback()
            let restarted = try await renderer.render(time: 0)
            let firstBytes = try XCTUnwrap(first.original.dataProvider?.data) as Data
            let restartedBytes = try XCTUnwrap(restarted.original.dataProvider?.data) as Data
            XCTAssertEqual(firstBytes, restartedBytes)
        } catch { await renderer.unloadVideo(); throw error }
        await renderer.unloadVideo()
    }

    func testInvalidVideoReportsFFmpegDiagnostic() async throws {
        try requireFFmpeg()
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("AnaLine-invalid-\(UUID().uuidString).mkv")
        defer { try? FileManager.default.removeItem(at: url) }
        try Data("not a movie".utf8).write(to: url)
        let renderer = TVRenderer(executableSearchPath: finderPath)
        do {
            _ = try await renderer.loadVideo(url)
            XCTFail("Invalid media should fail")
        } catch TVVideoError.processFailed(let tool, let status, let detail) {
            XCTAssertEqual(tool, "ffmpeg")
            XCTAssertNotEqual(status, 0)
            XCTAssertFalse(detail.isEmpty)
        }
    }

    private func requireFFmpeg() throws {
        guard TVExecutableResolver.find("ffmpeg", path: finderPath) != nil,
              TVExecutableResolver.find("ffprobe", path: finderPath) != nil else {
            throw XCTSkip("These integration checks require FFmpeg/ffprobe on PATH or in a standard installation folder")
        }
    }
}
