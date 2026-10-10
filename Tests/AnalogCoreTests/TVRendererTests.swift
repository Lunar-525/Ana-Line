import XCTest
import AnalogCore
@testable import AnalogImaging

private final class PreparationLog: @unchecked Sendable {
    private let lock = NSLock()
    private var entries = [TVPreparationProgress]()
    func append(_ entry: TVPreparationProgress) { lock.lock(); entries.append(entry); lock.unlock() }
    var values: [TVPreparationProgress] { lock.lock(); defer { lock.unlock() }; return entries }
}

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
            let progress = PreparationLog()
            _ = try await renderer.loadVideo(source,progress: { progress.append($0) })
            let fractions = progress.values.compactMap(\.fraction)
            XCTAssertEqual(fractions.first,0)
            XCTAssertEqual(fractions.last,1)
            XCTAssertTrue(zip(fractions,fractions.dropFirst()).allSatisfy { $0 <= $1 })
            XCTAssertTrue(fractions.contains { $0 > 0 && $0 < 0.9 },"FFmpeg must report intermediate progress")
            XCTAssertTrue(progress.values.contains { $0.stage == .audio })
            for standard in TVStandard.allCases {
                let duration = try await renderer.selectStandard(standard)
                XCTAssertEqual(duration, 213.04, accuracy: 0.1)
                let audioURL = await renderer.normalizedAudioURL()
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
                    XCTAssertEqual(preview.reception.audio.count,TVSoundClock.count(frame: preview.frameIndex,standard: standard))
                    if time == 10 {
                        XCTAssertGreaterThan(preview.reception.audio.map { abs($0) }.max() ?? 0,0.01,
                            "The real soundtrack must reach the RF receiver output")
                    }
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
            let audio = await renderer.normalizedAudioURL()
            XCTAssertNil(audio)
            let first = try await renderer.render(time: 0)
            let next = try await renderer.render(time: TVStandard.pal.frameDuration)
            XCTAssertEqual(next.frameIndex, 1)
            XCTAssertTrue(next.reception.audio.isEmpty)
            await renderer.endPlayback()
            let restarted = try await renderer.render(time: 0)
            let firstBytes = try XCTUnwrap(first.original.dataProvider?.data) as Data
            let restartedBytes = try XCTUnwrap(restarted.original.dataProvider?.data) as Data
            XCTAssertEqual(firstBytes, restartedBytes)
        } catch { await renderer.unloadVideo(); throw error }
        await renderer.unloadVideo()
    }

    func testRickrollSteadyPlaybackTimings() async throws {
        try requireFFmpeg()
        let source = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("Assets/rickroll.mp4")
        let renderer = TVRenderer(executableSearchPath: finderPath)
        var report = [[String:Any]]()
        do {
            for standard in TVStandard.allCases {
                _ = try await renderer.loadVideo(source,standard: standard)
                _ = try await renderer.render(time: 10)
                var samples = [[Double]]()
                for n in 1...8 {
                    let preview = try await renderer.render(time: 10+Double(n)*standard.frameDuration)
                    XCTAssertEqual(preview.reception.lock,.locked)
                    XCTAssertEqual(preview.prerollSeconds,0)
                    samples.append([preview.sourceSeconds,preview.encodeSeconds,preview.decodeSeconds,preview.outputSeconds,preview.totalSeconds,preview.reception.soundSeconds])
                }
                let names = ["FFmpeg / RGB","CVBS encode","RF / receiver","Output image","total_ms","FM sound (included)"]
                var row: [String:Any] = ["system":TerrestrialSystem(video: standard).rawValue]
                for stage in names.indices { row[names[stage]] = samples.map { $0[stage] }.reduce(0,+)/Double(samples.count)*1000 }
                report.append(row)
                print("TV end-to-end",row)
            }
        } catch { await renderer.unloadVideo(); throw error }
        await renderer.unloadVideo()
        let output = try JSONSerialization.data(withJSONObject: report,options: [.prettyPrinted,.sortedKeys])
        try output.write(to: URL(fileURLWithPath:"/private/tmp/Terrestrial-playback-benchmark.json"))
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
            XCTAssertEqual(tool, "ffprobe")
            XCTAssertNotEqual(status, 0)
            XCTAssertFalse(detail.isEmpty)
        }
    }

    func testRickrollSustainedRealtimeProfile() async throws {
        try requireFFmpeg()
        let source = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("Assets/rickroll.mp4")
        let renderer = TVRenderer(executableSearchPath: finderPath)
        var report = [[String:Any]]()
        do {
            for standard in TVStandard.allCases {
                _ = try await renderer.loadVideo(source,standard: standard)
                var settings = TerrestrialSettings(system: TerrestrialSystem(video: standard))
                settings.echoGain = 0.15; settings.echoDelayMicroseconds = 4.3
                settings.echoPhaseDegrees = 30; settings.tuningOffsetKHz = 20
                _ = try await renderer.render(time: 10,channel: settings)
                var samples = [Double]()
                for n in 1...240 {
                    let start = ContinuousClock.now
                    let result = try await renderer.render(time: 10+Double(n)*standard.frameDuration,channel: settings)
                    let elapsed = start.duration(to: .now).components
                    samples.append((Double(elapsed.seconds)+Double(elapsed.attoseconds)/1e18)*1000)
                    XCTAssertEqual(result.reception.lock,.locked)
                    XCTAssertEqual(result.prerollSeconds,0)
                    XCTAssertFalse(result.reception.audio.isEmpty)
                }
                let sorted = samples.sorted(), budget = standard.frameDuration*1000
                let row: [String:Any] = ["system":TerrestrialSystem(video: standard).rawValue,"frames":samples.count,
                    "mean_ms":samples.reduce(0,+)/Double(samples.count),"median_ms":sorted[sorted.count/2],
                    "p95_ms":sorted[Int(Double(sorted.count-1)*0.95)],"max_ms":sorted.last!,
                    "frame_budget_ms":budget,"over_budget_frames":samples.filter { $0 > budget }.count]
                report.append(row); print("TV sustained",row)
            }
        } catch { await renderer.unloadVideo(); throw error }
        await renderer.unloadVideo()
        try JSONSerialization.data(withJSONObject: report,options: [.prettyPrinted,.sortedKeys])
            .write(to: URL(fileURLWithPath: "/private/tmp/Terrestrial-sustained-realtime.json"))
    }

    func testRickrollPropagationWeatherAndPARealtimeProfile() async throws {
        try requireFFmpeg()
        let source = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("Assets/rickroll.mp4")
        let renderer = TVRenderer(executableSearchPath: finderPath)
        var report = [[String:Any]]()
        do {
            for standard in TVStandard.allCases {
                _ = try await renderer.loadVideo(source,standard: standard)
                var s = TerrestrialSettings(system: TerrestrialSystem(video: standard))
                s.propagation.enabled = true; s.propagation.distanceKm = 12
                s.propagation.ridgeEnabled = true; s.propagation.ridgeHeightM = 35
                s.propagation.groundReflection = 0.1
                s.propagation.weather.enabled = true; s.propagation.weather.rainMMHour = 25
                s.propagation.weather.snowMMHour = 3; s.propagation.weather.fogGramsM3 = 0.1
                s.propagation.weather.humidityPercent = 70; s.propagation.weather.temperatureC = 25
                s.propagation.weather.sunlight = 0.7; s.propagation.weather.lightning = 0.5
                s.propagation.weather.ionization = 0.2
                s.transmitter.enabled = true; s.transmitter.phaseDegrees = 5
                _ = try await renderer.render(time: 10,channel: s)
                var samples = [Double]()
                for n in 1...1200 {
                    let start = ContinuousClock.now
                    let result = try await renderer.render(time: 10+Double(n)*standard.frameDuration,channel: s)
                    let elapsed = start.duration(to: .now).components
                    samples.append((Double(elapsed.seconds)+Double(elapsed.attoseconds)/1e18)*1000)
                    XCTAssertEqual(result.prerollSeconds,0)
                    XCTAssertFalse(result.reception.audio.isEmpty)
                    XCTAssertTrue(result.reception.audio.allSatisfy(\.isFinite))
                }
                let sorted = samples.sorted(), budget = standard.frameDuration*1000
                let row: [String:Any] = ["system":TerrestrialSystem(video: standard).rawValue,"frames":samples.count,
                    "mean_ms":samples.reduce(0,+)/Double(samples.count),"p95_ms":sorted[Int(Double(sorted.count-1)*0.95)],
                    "max_ms":sorted.last!,"frame_budget_ms":budget,"over_budget_frames":samples.filter { $0 > budget }.count]
                report.append(row); print("TV scene + weather + PA",row)
            }
        } catch { await renderer.unloadVideo(); throw error }
        await renderer.unloadVideo()
        try JSONSerialization.data(withJSONObject: report,options: [.prettyPrinted,.sortedKeys])
            .write(to: URL(fileURLWithPath: "/private/tmp/Terrestrial-scene-realtime.json"))
    }

    func testAnamorphicSourceFitsFourByThreeWithoutStretching() async throws {
        try requireFFmpeg()
        let source = FileManager.default.temporaryDirectory.appendingPathComponent("AnaLine-anamorphic-\(UUID().uuidString).mkv")
        defer { try? FileManager.default.removeItem(at: source) }
        let process = Process(); process.executableURL = TVExecutableResolver.find("ffmpeg",path: finderPath)
        process.arguments = ["-hide_banner","-loglevel","error","-y","-f","lavfi","-i",
            "color=white:size=160x120:rate=25","-t","0.2","-vf","setsar=2","-c:v","ffv1",source.path]
        process.standardOutput = FileHandle.nullDevice; process.standardError = FileHandle.nullDevice
        try process.run(); process.waitUntilExit(); XCTAssertEqual(process.terminationStatus,0)
        let renderer = TVRenderer(executableSearchPath: finderPath)
        do {
            for standard in TVStandard.allCases {
                _ = try await renderer.loadVideo(source,standard: standard)
                let preview = try await renderer.render(time: 0)
                let pixels = try XCTUnwrap(preview.original.dataProvider?.data) as Data
                let image = preview.original, bytesPerPixel = image.bitsPerPixel/8
                let whiteRows = (0..<image.height).filter {
                    pixels[$0*image.bytesPerRow+(image.width/2)*bytesPerPixel] > 200
                }.count
                // Input DAR is 8:3, exactly twice the fixed 4:3 display canvas.
                XCTAssertEqual(whiteRows,standard.height/2,accuracy: 2)
            }
        } catch { await renderer.unloadVideo(); throw error }
        await renderer.unloadVideo()
    }

    func testPreparedStandardsSurviveSourceRemovalAndFailedReplacement() async throws {
        try requireFFmpeg()
        let source = FileManager.default.temporaryDirectory.appendingPathComponent("AnaLine-cache-\(UUID().uuidString).mkv")
        defer { try? FileManager.default.removeItem(at: source) }
        let process = Process(); process.executableURL = TVExecutableResolver.find("ffmpeg",path: finderPath)
        process.arguments = ["-hide_banner","-loglevel","error","-y","-f","lavfi","-i",
            "testsrc2=size=160x120:rate=30","-f","lavfi","-i","sine=frequency=1000:sample_rate=48000",
            "-t","0.25","-c:v","ffv1","-c:a","pcm_s16le",source.path]
        process.standardOutput = FileHandle.nullDevice; process.standardError = FileHandle.nullDevice
        try process.run(); process.waitUntilExit(); XCTAssertEqual(process.terminationStatus,0)
        let renderer = TVRenderer(executableSearchPath: finderPath)
        _ = try await renderer.loadVideo(source,standard: .ntsc)
        let palPath = await renderer.normalizedVideoURL(standard: .pal)
        let ntscPath = await renderer.normalizedVideoURL(standard: .ntsc)
        let audioPath = await renderer.normalizedAudioURL()
        let outputs = [try XCTUnwrap(palPath),try XCTUnwrap(ntscPath),try XCTUnwrap(audioPath)]
        let before = try outputs.map { try Data(contentsOf: $0) }
        try FileManager.default.removeItem(at: source)
        do {
            _ = try await renderer.loadVideo(source)
            XCTFail("The removed source must fail a new import")
        } catch { /* A failed replacement must retain both old caches. */ }
        for standard in [TVStandard.pal,.ntsc,.pal,.ntsc] {
            let duration = try await renderer.selectStandard(standard)
            XCTAssertGreaterThan(duration,0)
            let frame = try await renderer.render(time: duration)
            XCTAssertEqual(frame.original.height,standard.height)
            XCTAssertEqual(frame.image.height,standard.height)
            XCTAssertLessThan(Double(frame.frameIndex)*standard.frameDuration,duration)
            XCTAssertEqual(frame.reception.audio.count,TVSoundClock.count(frame: frame.frameIndex,standard: standard))
        }
        XCTAssertEqual(try outputs.map { try Data(contentsOf: $0) },before,"Switches must reuse video and PCM files")
        await renderer.unloadVideo()
        for output in outputs { XCTAssertFalse(FileManager.default.fileExists(atPath: output.path)) }
        do {
            _ = try await renderer.selectStandard(.pal)
            XCTFail("An unloaded renderer has no standard cache")
        } catch TVVideoError.noVideo {} catch { XCTFail("Unexpected error: \(error)") }
    }

    func testReleasingRendererRemovesItsConversionOutputs() async throws {
        try requireFFmpeg()
        let source = FileManager.default.temporaryDirectory.appendingPathComponent("AnaLine-cleanup-\(UUID().uuidString).mkv")
        defer { try? FileManager.default.removeItem(at: source) }
        let process = Process(); process.executableURL = TVExecutableResolver.find("ffmpeg",path: finderPath)
        process.arguments = ["-hide_banner","-loglevel","error","-y","-f","lavfi","-i",
            "color=white:size=160x120:rate=25","-f","lavfi","-i","sine=frequency=1000:sample_rate=48000",
            "-t","0.2","-c:v","ffv1","-c:a","pcm_s16le",source.path]
        process.standardOutput = FileHandle.nullDevice; process.standardError = FileHandle.nullDevice
        try process.run(); process.waitUntilExit(); XCTAssertEqual(process.terminationStatus,0)
        var renderer: TVRenderer? = TVRenderer(executableSearchPath: finderPath)
        weak var weakRenderer = renderer
        _ = try await renderer!.loadVideo(source)
        let audioPath = await renderer!.normalizedAudioURL()
        let audio = try XCTUnwrap(audioPath)
        let palPath = await renderer!.normalizedVideoURL(standard: .pal)
        let ntscPath = await renderer!.normalizedVideoURL(standard: .ntsc)
        let videos = [try XCTUnwrap(palPath),try XCTUnwrap(ntscPath)]
        XCTAssertTrue(FileManager.default.fileExists(atPath: audio.path))
        for video in videos { XCTAssertTrue(FileManager.default.fileExists(atPath: video.path)) }
        // Release without calling unloadVideo: the lifetime owner must clean up.
        renderer = nil
        for _ in 0..<50 where weakRenderer != nil { try await Task.sleep(for: .milliseconds(20)) }
        XCTAssertNil(weakRenderer)
        XCTAssertFalse(FileManager.default.fileExists(atPath: audio.path))
        for video in videos { XCTAssertFalse(FileManager.default.fileExists(atPath: video.path)) }
        XCTAssertTrue(FileManager.default.fileExists(atPath: source.path))
    }

    private func requireFFmpeg() throws {
        guard TVExecutableResolver.find("ffmpeg", path: finderPath) != nil,
              TVExecutableResolver.find("ffprobe", path: finderPath) != nil else {
            throw XCTSkip("These integration checks require FFmpeg/ffprobe on PATH or in a standard installation folder")
        }
    }
}
