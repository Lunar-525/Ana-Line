import Foundation
import AnalogCore

struct TVSessionDocument: Codable, Equatable {
    var format = "AnaLine Terrestrial Session"
    var version = 1
    var video: VideoReference?
    var standard: TVStandard
    var channel: TerrestrialSettings
    var position: Double
    var muted: Bool
    var bypassedEchoGain: Float?

    struct VideoReference: Codable, Equatable {
        let path: String
        let relativePath: String
        let name: String
        init(video: URL,session: URL) {
            let target = video.standardizedFileURL
            path = target.path; name = target.lastPathComponent
            let base = session.deletingLastPathComponent().standardizedFileURL.pathComponents
            let parts = target.pathComponents
            let shared = zip(base,parts).prefix { $0 == $1 }.count
            relativePath = (Array(repeating: "..",count: base.count-shared)+parts.dropFirst(shared)).joined(separator: "/")
        }
        func resolve(relativeTo session: URL) -> URL? {
            let nearby = session.deletingLastPathComponent().appendingPathComponent(relativePath).standardizedFileURL
            let original = URL(fileURLWithPath: path)
            return [nearby,original].first { url in
                var directory: ObjCBool = false
                return FileManager.default.fileExists(atPath: url.path,isDirectory: &directory) && !directory.boolValue
                    && FileManager.default.isReadableFile(atPath: url.path)
            }
        }
    }

    func validate() throws {
        guard format == "AnaLine Terrestrial Session",version == 1 else { throw SessionError.unsupportedVersion }
        guard position.isFinite,position >= 0,
              bypassedEchoGain.map({ $0.isFinite && (0...1).contains($0) }) ?? true,
              video.map({ $0.path.hasPrefix("/") && !$0.relativePath.isEmpty }) ?? true else { throw SessionError.invalidParameters }
        try channel.validate(rate: standard.sampleRate)
    }
    static func read(from url: URL) throws -> Self {
        let document = try JSONDecoder().decode(Self.self,from: Data(contentsOf: url))
        try document.validate()
        return document
    }
    func write(to url: URL) throws {
        try validate()
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted,.sortedKeys,.withoutEscapingSlashes]
        try encoder.encode(self).write(to: url,options: .atomic)
    }
    enum SessionError: LocalizedError {
        case unsupportedVersion,invalidParameters,missingVideo(String),busy
        var errorDescription: String? {
            switch self {
            case .unsupportedVersion: L("This session format or version is not supported.")
            case .invalidParameters: L("The session contains invalid parameters.")
            case .missingVideo(let name): L("Video not found:") + " " + name
            case .busy: L("Wait for media preparation to finish.")
            }
        }
    }
}
