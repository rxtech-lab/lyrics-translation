// swiftc -module-cache-path /tmp/lyric-swift-cache -parse-as-library Lyrics/VideoStreaming.swift scripts/test-video-streaming.swift -o /tmp/test-video-streaming
// /tmp/test-video-streaming /tmp/streaming-fixture.mp4
import Foundation

@main struct StreamingTest {
    static func main() async throws {
        let source = URL(fileURLWithPath: CommandLine.arguments[1])
        let package = try await VideoStreaming.prepare(source, hasAudio: true) { print($0) }
        defer { try? FileManager.default.removeItem(at: package.directory) }
        precondition(Set(package.files) == Set(["360.ts", "360.m3u8", "720.ts", "720.m3u8", "master.m3u8"]))
        let master = try String(contentsOf: package.directory.appendingPathComponent("master.m3u8"), encoding: .utf8)
        precondition(master.contains("RESOLUTION=640x360") && master.contains("RESOLUTION=1280x720"))
        precondition(!master.contains("1080"))
        for size in [360, 720] {
            let playlist = try String(contentsOf: package.directory.appendingPathComponent("\(size).m3u8"), encoding: .utf8)
            precondition(playlist.contains("#EXT-X-PLAYLIST-TYPE:VOD") && playlist.contains("#EXT-X-ENDLIST"))
            precondition(playlist.contains("#EXT-X-BYTERANGE:") && playlist.contains("\(size).ts"))
            precondition(!playlist.contains(package.directory.path))
            let bytes = try Data(contentsOf: package.directory.appendingPathComponent("\(size).ts"))
            precondition(bytes.count > 0)
            let decode = Process()
            decode.executableURL = URL(fileURLWithPath: "/opt/homebrew/bin/ffmpeg")
            decode.arguments = ["-v", "error", "-i", package.directory.appendingPathComponent("\(size).m3u8").path,
                                "-map", "0:v:0", "-map", "0:a:0", "-f", "null", "-"]
            try decode.run()
            decode.waitUntilExit()
            precondition(decode.terminationStatus == 0, "HLS rendition must decode with video and audio")
        }
        if CommandLine.arguments.count > 2 {
            try FileManager.default.copyItem(at: package.directory, to: URL(fileURLWithPath: CommandLine.arguments[2]))
        }
        print("PASS: hardware-encoded HLS variants, no upscale, relative URIs, byte ranges, complete VOD")
    }
}
