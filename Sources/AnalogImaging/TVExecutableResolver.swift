import Foundation

enum TVExecutableResolver {
    // Finder-launched apps generally inherit launchd's PATH, which omits Homebrew.
    // Prefer the caller's PATH, then check the usual external-tool locations.
    static let fallbackDirectories = ["/opt/homebrew/bin", "/usr/local/bin", "/opt/local/bin"]

    static func find(_ name: String, path: String,
                     fallbackDirectories: [String] = fallbackDirectories) -> URL? {
        let directories = path.split(separator: ":").map(String.init) + fallbackDirectories
        for directory in directories {
            let url = URL(fileURLWithPath: directory, isDirectory: true).appendingPathComponent(name)
            var isDirectory: ObjCBool = false
            if FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory),
               !isDirectory.boolValue, FileManager.default.isExecutableFile(atPath: url.path) {
                return url
            }
        }
        return nil
    }
}
