import Foundation

/// Only decode public-facing lyrics; agent settings and history never enter previews.
struct PreviewSong: Decodable, Sendable {
    struct Line: Decodable, Sendable {
        var original: String
        var translated: String?
        var section: String?
        var speaker: String?
    }
    var target: String?
    var lines: [Line]

    static func read(_ url: URL) throws -> PreviewSong {
        let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        guard size <= 32 * 1024 * 1024 else { throw CocoaError(.fileReadTooLarge) }
        return try JSONDecoder().decode(Self.self, from: Data(contentsOf: url))
    }
}
