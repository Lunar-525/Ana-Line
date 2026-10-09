import Foundation

/// Both one-shot jobs and the playback reader drain stdout while stderr goes
/// to a file, so RGB pipe backpressure never blocks error reporting.
final class TVFFmpegProcess {
    let output: FileHandle
    private let process: Process
    private let logURL: URL
    private let log: FileHandle
    private let name: String
    private let completion = DispatchSemaphore(value: 0)
    private var closed = false

    init(_ executable: URL, _ arguments: [String]) throws {
        name = executable.lastPathComponent
        process = Process(); process.executableURL = executable; process.arguments = arguments
        let pipe = Pipe(); process.standardOutput = pipe; output = pipe.fileHandleForReading
        logURL = FileManager.default.temporaryDirectory.appendingPathComponent("AnaLine-ffmpeg-\(UUID().uuidString).log")
        guard FileManager.default.createFile(atPath: logURL.path, contents: nil) else { throw CocoaError(.fileWriteUnknown) }
        log = try FileHandle(forWritingTo: logURL)
        process.standardError = log
        process.terminationHandler = { [completion] _ in completion.signal() }
        do { try process.run() }
        catch {
            try? log.close(); try? FileManager.default.removeItem(at: logURL)
            throw TVVideoError.processLaunch(name, error.localizedDescription)
        }
    }

    func finish() throws {
        completion.wait()
        guard process.terminationStatus == 0 else {
            let reader = try FileHandle(forReadingFrom: logURL)
            defer { try? reader.close() }
            let size = try reader.seekToEnd()
            try reader.seek(toOffset: size > 4096 ? size - 4096 : 0)
            let detail = String(decoding: try reader.readToEnd() ?? Data(), as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            throw TVVideoError.processFailed(name, process.terminationStatus, detail)
        }
    }

    func readFrame(byteCount: Int) throws -> Data {
        var bytes = Data(); bytes.reserveCapacity(byteCount)
        while bytes.count < byteCount {
            guard let chunk = try output.read(upToCount: byteCount - bytes.count), !chunk.isEmpty else {
                try finish()
                throw TVVideoError.invalidFrame
            }
            bytes.append(chunk)
        }
        return bytes
    }

    func close() {
        guard !closed else { return }; closed = true
        try? output.close()
        // A streaming process may be closed on a different executor thread from
        // the one which launched it. Process.waitUntilExit's run-loop wait can
        // hang in that case. Termination/reaping stays with Foundation's handler.
        if process.isRunning { process.terminate() }
        try? log.close(); try? FileManager.default.removeItem(at: logURL)
    }

    deinit { close() }
}
