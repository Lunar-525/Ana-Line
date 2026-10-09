import Foundation
import CryptoKit
import AnalogCore

public struct LUTPreset: Codable, Sendable, Identifiable {
    public let id: String
    public let name: String
    public let collection: String
    public let file: String
    public let format: String
    public let inputSpace: LUTColorSpace
    public let outputSpace: LUTColorSpace
    public let certainty: String
    public let role: String
    public let url: URL
    public let gitBlobSHA: String
    public var compressOutputGamut: Bool { outputSpace == .adobeRGB1998 || outputSpace == .displayP3 }
    public var colorDescription: String {
        "\(inputSpace.label) → \(outputSpace.label)" + (certainty == "assumed" ? " (assumed)" : "")
            + (compressOutputGamut ? " → sRGB gamut compression" : "")
    }
}

public struct LUTLibrary: Sendable {
    public let root: URL
    public let presets: [LUTPreset]
    public init(root: URL) throws {
        self.root = root
        presets = try JSONDecoder().decode([LUTPreset].self,from: Data(contentsOf: root.appendingPathComponent("catalog.json")))
        guard Set(presets.map(\.id)).count == presets.count,
              presets.allSatisfy({ ["cube","png"].contains($0.format) && $0.file == URL(fileURLWithPath: $0.file).lastPathComponent && $0.url.scheme == "https" && $0.url.host == "raw.githubusercontent.com" }) else {
            throw CubeLUT.ParseError.invalid("Invalid catalog")
        }
    }
    public static func verify(_ data: Data, preset: LUTPreset) -> Bool {
        var blob = Data("blob \(data.count)\0".utf8); blob.append(data)
        return Insecure.SHA1.hash(data: blob).map { String(format: "%02x",$0) }.joined() == preset.gitBlobSHA
    }
    public func data(for preset: LUTPreset) async throws -> Data {
        let bundled = root.appendingPathComponent(preset.file)
        let cache = FileManager.default.urls(for: .cachesDirectory,in: .userDomainMask)[0]
            .appendingPathComponent("AnalogLab/LUTs/\(preset.gitBlobSHA).\(preset.format)")
        for file in [bundled,cache] {
            if FileManager.default.fileExists(atPath: file.path) {
                let data = try Data(contentsOf: file)
                guard Self.verify(data,preset: preset) else { throw CubeLUT.ParseError.invalid("LUT checksum mismatch: \(preset.name)") }
                return data
            }
        }
        let (file,response) = try await URLSession.shared.download(from: preset.url)
        defer { try? FileManager.default.removeItem(at: file) }
        try Task.checkCancellation()
        guard (response as? HTTPURLResponse)?.statusCode == 200,
              let size = try file.resourceValues(forKeys: [.fileSizeKey]).fileSize, size <= 32*1024*1024 else {
            throw CubeLUT.ParseError.invalid("LUT download failed or exceeds 32 MB")
        }
        let data = try Data(contentsOf: file)
        guard Self.verify(data,preset: preset) else { throw CubeLUT.ParseError.invalid("Upstream LUT changed; update catalog first") }
        try FileManager.default.createDirectory(at: cache.deletingLastPathComponent(),withIntermediateDirectories: true)
        try data.write(to: cache,options: .atomic)
        return data
    }
    public static func decode(_ data: Data,preset: LUTPreset) throws -> CubeLUT {
        switch preset.format {
        case "cube":
            guard let text = String(data: data,encoding: .utf8) else { throw CubeLUT.ParseError.invalid("CUBE is not UTF-8") }
            return try CubeLUT(text: text)
        case "png": return try HaldLUT.load(data: data)
        default: throw CubeLUT.ParseError.invalid("Unsupported LUT format")
        }
    }
}
