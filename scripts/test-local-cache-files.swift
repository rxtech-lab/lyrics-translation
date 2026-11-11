import Foundation

@main struct LocalCacheFilesTests {
    static func main() throws {
        let manager = FileManager.default
        let root = manager.temporaryDirectory.appendingPathComponent("LyricStudio-cache-test-" + UUID().uuidString)
        defer { try? manager.removeItem(at: root) }
        let store = LocalCacheFiles(temporary: root.appendingPathComponent("temp"),
                                    support: root.appendingPathComponent("support"),
                                    caches: root.appendingPathComponent("caches"))
        func write(_ url: URL, bytes: Int = 7) throws {
            try manager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(repeating: 1, count: bytes).write(to: url)
        }
        let first = store.temporary.appendingPathComponent("LyricVideo-1/public/clip.mp4")
        let second = store.temporary.appendingPathComponent("LyricVideoPublish-2/video.mp4")
        let exported = store.temporary.appendingPathComponent("My Export.mp4")
        let document = store.support.appendingPathComponent("LyricStudio/Conversations/song.json")
        let waveform = store.support.appendingPathComponent("LyricStudio/Waveforms/song.waveform")
        let compiled = store.caches.appendingPathComponent("app.rxlab.RxRemotion/compiled/script.json")
        let image = store.temporary.appendingPathComponent("Lyrics-1.png")
        for file in [first, second, exported, document, waveform, compiled, image] { try write(file) }
        let video = try store.files(for: .videoFiles)
        precondition(video.count == 2 && video.reduce(0) { $0 + $1.bytes } == 14)
        try store.remove(video.first { $0.url.lastPathComponent == "LyricVideo-1" }!, from: .videoFiles)
        precondition(!manager.fileExists(atPath: first.path) && manager.fileExists(atPath: second.path))
        // Even a forged selection must not remove a user export or a document.
        try store.remove(LocalCacheFile(url: exported, bytes: 7), from: .videoFiles)
        try store.remove(LocalCacheFile(url: document, bytes: 7), from: .temporaryFiles)
        precondition(manager.fileExists(atPath: exported.path) && manager.fileExists(atPath: document.path))
        // A symlink contributes no external bytes; clearing it only unlinks the cache entry.
        let external = root.appendingPathComponent("outside/precious.mp4")
        try write(external, bytes: 100)
        let link = store.temporary.appendingPathComponent("LyricVideo-link")
        try manager.createSymbolicLink(at: link, withDestinationURL: external.deletingLastPathComponent())
        let linked = try store.files(for: .videoFiles).first { $0.url.lastPathComponent == link.lastPathComponent }!
        precondition(linked.bytes == 0)
        try store.remove(linked, from: .videoFiles)
        precondition(manager.fileExists(atPath: external.path))
        let waveforms = try store.files(for: .waveforms)
        let compilations = try store.files(for: .compiledVideo)
        let images = try store.files(for: .temporaryFiles)
        precondition(waveforms.count == 1 && compilations.count == 1 && images.count == 1)
        // Clear all eligible categories while preserving unrelated local files.
        for cache in LocalCache.allCases {
            for file in try store.files(for: cache) { try store.remove(file, from: cache) }
            let remaining = try store.files(for: cache)
            precondition(remaining.isEmpty)
        }
        precondition(manager.fileExists(atPath: exported.path) && manager.fileExists(atPath: document.path))
        // Refuse cache roots redirected to unrelated storage by a symlinked parent.
        try manager.removeItem(at: store.caches.appendingPathComponent("app.rxlab.RxRemotion"))
        try manager.createDirectory(at: root.appendingPathComponent("outside/compiled"), withIntermediateDirectories: true)
        try write(root.appendingPathComponent("outside/compiled/precious.json"))
        try manager.createSymbolicLink(at: store.caches.appendingPathComponent("app.rxlab.RxRemotion"),
                                      withDestinationURL: root.appendingPathComponent("outside"))
        let redirected = try store.files(for: .compiledVideo)
        precondition(redirected.isEmpty)
        print("Local cache files: individual/all clearing, sizes, document preservation, and symlink boundaries passed")
    }
}
