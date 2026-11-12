import AVFoundation
import Foundation

/// Locally prepares a complete, immutable HLS package before any publication is changed.
enum VideoStreaming {
    struct Package: Sendable {
        let directory: URL
        let files: [String]
    }

    static func prepare(_ source: URL, hasAudio: Bool,
                        report: @escaping @MainActor @Sendable (String) -> Void) async throws -> Package {
        let candidates = [Bundle.main.url(forResource: "ffmpeg", withExtension: nil)?.path,
                          "/opt/homebrew/bin/ffmpeg", "/usr/local/bin/ffmpeg", "/usr/bin/ffmpeg"].compactMap { $0 }
        guard let executable = candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0) }) else {
            throw Failure.message("Install FFmpeg (brew install ffmpeg) to prepare streaming video, then publish again.")
        }
        let asset = AVURLAsset(url: source)
        guard let track = try await asset.loadTracks(withMediaType: .video).first else {
            throw Failure.message("The selected file has no video track.")
        }
        let size = try await track.load(.naturalSize)
        let transform = try await track.load(.preferredTransform)
        let rect = CGRect(origin: .zero, size: size).applying(transform)
        let width = abs(rect.width), height = abs(rect.height)
        guard width >= 2, height >= 2 else { throw Failure.message("Invalid video dimensions.") }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("LyricStreaming-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        do {
            let shortSide = min(width, height)
            var sizes = [360, 720, 1080].filter { Double($0) <= shortSide }
            if sizes.isEmpty { sizes = [Int(shortSide)] }
            var master = "#EXTM3U\n#EXT-X-VERSION:4\n#EXT-X-INDEPENDENT-SEGMENTS\n"
            for target in sizes {
                try Task.checkCancellation()
                let scale = Double(target) / shortSide
                let w = max(2, Int(width * scale) / 2 * 2)
                let h = max(2, Int(height * scale) / 2 * 2)
                let bitrate = target <= 360 ? 800_000 : target <= 720 ? 2_800_000 : 5_000_000
                await report("Preparing \(target)p streaming video (VideoToolbox)…")
                var args = ["-hide_banner", "-nostdin", "-y", "-hwaccel", "videotoolbox", "-i", source.path,
                            "-map", "0:v:0"]
                if hasAudio { args += ["-map", "0:a:0?"] }
                args += ["-vf", "scale=\(w):\(h),setsar=1", "-r", "30", "-c:v", "h264_videotoolbox",
                         "-allow_sw", "0", "-pix_fmt", "yuv420p", "-b:v", "\(bitrate)",
                         "-maxrate", "\(bitrate)", "-bufsize", "\(bitrate * 2)", "-g", "180",
                         "-force_key_frames", "expr:gte(t,n_forced*6)"]
                args += hasAudio ? ["-c:a", "aac", "-b:a", "128k", "-ac", "2"] : ["-an"]
                args += ["-sn", "-f", "hls", "-hls_time", "6", "-hls_playlist_type", "vod",
                         "-hls_flags", "single_file+independent_segments", "-hls_segment_filename", "\(target).ts", "\(target).m3u8"]
                try await run(executable, args, directory: directory)
                // Conservative peak includes audio and mux overhead for adaptive selection.
                master += "#EXT-X-STREAM-INF:BANDWIDTH=\(Int(Double(bitrate + 128_000) * 1.25)),RESOLUTION=\(w)x\(h),FRAME-RATE=30\n\(target).m3u8\n"
            }
            try master.write(to: directory.appendingPathComponent("master.m3u8"), atomically: true, encoding: .utf8)
            let files = sizes.flatMap { ["\($0).ts", "\($0).m3u8"] } + ["master.m3u8"]
            return Package(directory: directory, files: files)
        } catch {
            try? FileManager.default.removeItem(at: directory)
            throw error
        }
    }

    private static func run(_ executable: String, _ arguments: [String], directory: URL) async throws {
        let log = directory.appendingPathComponent("ffmpeg.log")
        FileManager.default.createFile(atPath: log.path, contents: nil)
        let handle = try FileHandle(forWritingTo: log)
        defer { try? handle.close() }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.currentDirectoryURL = directory
        process.standardOutput = FileHandle.nullDevice
        process.standardError = handle
        try process.run()
        do {
            while process.isRunning { try await Task.sleep(for: .milliseconds(200)) }
            try Task.checkCancellation()
        } catch {
            if process.isRunning { process.terminate() }
            // Do not remove the workspace while FFmpeg still owns its output files.
            while process.isRunning { await Task.detached { try? await Task.sleep(for: .milliseconds(50)) }.value }
            throw error
        }
        guard process.terminationStatus == 0 else {
            let detail = (try? String(contentsOf: log, encoding: .utf8)) ?? ""
            throw Failure.message("Hardware streaming conversion failed. Ensure FFmpeg supports h264_videotoolbox and this Mac supports hardware encoding. \(detail.suffix(1600))")
        }
    }

    enum Failure: LocalizedError {
        case message(String)
        var errorDescription: String? { if case .message(let text) = self { return text }; return nil }
    }
}
