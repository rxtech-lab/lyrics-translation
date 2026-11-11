import Foundation

enum LocalCache: String, CaseIterable, Identifiable, Sendable {
    case network, waveforms, videoFiles, compiledVideo, temporaryFiles
    var id: String { rawValue }
    var title: String {
        switch self {
        case .network: "Network"
        case .waveforms: "Waveforms"
        case .videoFiles: "Video Files"
        case .compiledVideo: "Compiled Videos"
        case .temporaryFiles: "Temporary Files"
        }
    }
    var symbol: String {
        switch self {
        case .network: "network"
        case .waveforms: "waveform"
        case .videoFiles, .compiledVideo: "film"
        case .temporaryFiles: "doc"
        }
    }
    var detail: String {
        switch self {
        case .network: "Cached web responses and downloaded artwork."
        case .waveforms: "Recorded waveforms. Listen to the recording again to rebuild them."
        case .videoFiles: "Temporary previews, audio copies, render workspaces, and videos prepared for upload."
        case .compiledVideo: "Compiled video scripts. These rebuild when needed. This cache is shared with other RxRemotion apps."
        case .temporaryFiles: "Temporary artwork and exported sharing images."
        }
    }
}

struct LocalCacheFile: Identifiable, Sendable {
    let url: URL
    let bytes: Int64
    var id: URL { url }
}

/// Only known cache locations are eligible; documents and user-selected exports are never scanned.
struct LocalCacheFiles: Sendable {
    var temporary = FileManager.default.temporaryDirectory
    var support = URL.applicationSupportDirectory
    var caches = URL.cachesDirectory

    private func eligibleURLs(for cache: LocalCache) throws -> [URL] {
        let root: URL
        let expected: URL
        switch cache {
        case .network: return []
        case .waveforms:
            root = support.appendingPathComponent("LyricStudio/Waveforms")
            expected = support.resolvingSymlinksInPath().appendingPathComponent("LyricStudio/Waveforms")
        case .compiledVideo:
            root = caches.appendingPathComponent("app.rxlab.RxRemotion/compiled")
            expected = caches.resolvingSymlinksInPath().appendingPathComponent("app.rxlab.RxRemotion/compiled")
        case .videoFiles, .temporaryFiles:
            root = temporary
            expected = temporary.resolvingSymlinksInPath()
        }
        guard FileManager.default.fileExists(atPath: root.path) else { return [] }
        guard root.resolvingSymlinksInPath().standardizedFileURL == expected.standardizedFileURL else { return [] }
        return try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil).filter { url in
            switch cache {
            case .videoFiles:
                return ["LyricVideo-", "LyricVideoAudio-", "LyricVideoWork-", "LyricVideoPublish-", "LyricVideoExport-"].contains { url.lastPathComponent.hasPrefix($0) }
            case .temporaryFiles:
                return url.lastPathComponent.hasPrefix("LyricArtwork-")
                    || (url.pathExtension == "png" && ["Lyrics-", "Usage-"].contains { url.lastPathComponent.hasPrefix($0) })
            case .waveforms: return url.pathExtension == "waveform"
            case .compiledVideo: return url.pathExtension == "json"
            case .network: return false
            }
        }
    }

    func files(for cache: LocalCache) throws -> [LocalCacheFile] {
        try eligibleURLs(for: cache)
            .map { LocalCacheFile(url: $0, bytes: try size(of: $0)) }
            .sorted { $0.url.lastPathComponent.localizedStandardCompare($1.url.lastPathComponent) == .orderedAscending }
    }

    func remove(_ file: LocalCacheFile, from cache: LocalCache) throws {
        guard try eligibleURLs(for: cache).contains(file.url) else { return }
        try FileManager.default.removeItem(at: file.url)
    }

    private func size(of url: URL) throws -> Int64 {
        let keys: Set<URLResourceKey> = [.isSymbolicLinkKey, .isRegularFileKey, .isDirectoryKey, .fileSizeKey]
        let values = try url.resourceValues(forKeys: keys)
        if values.isSymbolicLink == true { return 0 }
        if values.isRegularFile == true { return Int64(values.fileSize ?? 0) }
        guard values.isDirectory == true else { return 0 }
        var failure: (any Error)?
        let enumerator = FileManager.default.enumerator(at: url, includingPropertiesForKeys: Array(keys), errorHandler: { _, error in
            failure = error
            return false
        })
        var total: Int64 = 0
        while let child = enumerator?.nextObject() as? URL {
            let item = try child.resourceValues(forKeys: keys)
            if item.isSymbolicLink == true { enumerator?.skipDescendants(); continue }
            if item.isRegularFile == true { total += Int64(item.fileSize ?? 0) }
        }
        if let failure { throw failure }
        return total
    }
}
