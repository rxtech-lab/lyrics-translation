import Foundation
import ImageIO
import RxAgentSDK
import RxRemotion

/// Project folder the video director edits through sandboxed file tools, plus a check that compiles and test-renders it.
///
/// Layout: `src/index.tsx` (app entry) and `src/song.json` (timings) belong to the app; everything else under
/// `src/` belongs to the agent, with `src/video.tsx` exporting the root `Video` component.
@MainActor final class VideoWorkspace {
    nonisolated static let toolNames: Set<String> = ["list_files", "read_file", "write_file", "edit_file", "delete_file", "import_image", "check_video"]
    static let reserved: Set<String> = ["index.tsx", "song.json"]
    static let extensions: Set<String> = ["tsx", "ts", "jsx", "js", "css"]
    private static let maxFileSize = 200_000, maxFiles = 24

    let root: URL
    var src: URL { root.appendingPathComponent("src", isDirectory: true) }
    /// Short description of each tool call, for the progress overlay.
    var onActivity: ((String) -> Void)?
    private(set) var checks = 0
    private let engine = RemotionEngine()
    private let probeFrame: Int
    private let requiresArtwork: Bool

    init(root: URL, probeFrame: Int, requiresArtwork: Bool = false) {
        self.root = root.resolvingSymlinksInPath()
        self.probeFrame = probeFrame
        self.requiresArtwork = requiresArtwork
    }

    func close() { engine.closeAll() }

    /// Agent-owned files keyed by path relative to src/.
    func files() -> [String: String] {
        guard let enumerator = FileManager.default.enumerator(at: src, includingPropertiesForKeys: [.isRegularFileKey]) else { return [:] }
        var result: [String: String] = [:]
        let base = src.resolvingSymlinksInPath().path + "/"
        for case let url as URL in enumerator {
            let path = url.resolvingSymlinksInPath().path
            guard path.hasPrefix(base), (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true else { continue }
            let relative = String(path.dropFirst(base.count))
            guard !Self.reserved.contains(relative), Self.extensions.contains(url.pathExtension.lowercased()),
                  let text = try? String(contentsOf: url, encoding: .utf8) else { continue }
            result[relative] = text
        }
        return result
    }

    func write(_ files: [String: String]) throws {
        for (path, text) in files {
            let url = try resolve(path, writing: true)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try text.write(to: url, atomically: true, encoding: .utf8)
        }
    }

    /// Images live outside src/ so Remotion can wait for them using Img + staticFile.
    var assetDirectory: URL { root.appendingPathComponent("public/scenes", isDirectory: true) }

    func assets() throws -> [String: Data] {
        guard FileManager.default.fileExists(atPath: assetDirectory.path) else { return [:] }
        var result: [String: Data] = [:]
        for url in try FileManager.default.contentsOfDirectory(at: assetDirectory, includingPropertiesForKeys: nil) {
            guard Self.validAssetName(url.lastPathComponent) else { continue }
            let resolved = url.resolvingSymlinksInPath()
            guard resolved.deletingLastPathComponent() == assetDirectory.resolvingSymlinksInPath() else {
                throw PipelineError.invalid("Scene assets must stay in public/scenes/.")
            }
            result[url.lastPathComponent] = try Data(contentsOf: resolved)
        }
        return result
    }

    static func validAssetName(_ name: String) -> Bool {
        !name.isEmpty && !name.hasPrefix(".") &&
        name.unicodeScalars.allSatisfy { CharacterSet.alphanumerics.contains($0) || "-_.".unicodeScalars.contains($0) } &&
        ["png", "jpg", "jpeg", "webp"].contains(URL(fileURLWithPath: name).pathExtension.lowercased())
    }

    static func writeAssets(_ assets: [String: Data], to root: URL) throws {
        let directory = root.appendingPathComponent("public/scenes", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        for (name, data) in assets {
            guard validAssetName(name) else { throw PipelineError.invalid("Invalid scene asset filename.") }
            let destination = directory.appendingPathComponent(name).resolvingSymlinksInPath()
            guard destination.deletingLastPathComponent() == directory.resolvingSymlinksInPath() else {
                throw PipelineError.invalid("Scene assets must stay in public/scenes/.")
            }
            try data.write(to: destination, options: .atomic)
        }
    }

    private func importImage(source: String, name: String) -> AgentToolResult {
        do {
            guard Self.validAssetName(name) else { return .error("Use a filename such as scene-01-background.png (PNG, JPEG or WebP).") }
            let sourceURL = URL(fileURLWithPath: source, relativeTo: root).standardizedFileURL.resolvingSymlinksInPath()
            let codexHome = ProcessInfo.processInfo.environment["CODEX_HOME"].map { URL(fileURLWithPath: $0) }
                ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex")
            let generated = codexHome.appendingPathComponent("generated_images").resolvingSymlinksInPath()
            guard [root, generated].contains(where: { sourceURL.path.hasPrefix($0.path + "/") }) else {
                return .error("Import only generated images from this project or CODEX_HOME/generated_images/. Pass the image tool's saved local path.")
            }
            let size = (try sourceURL.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey]))
            guard size.isRegularFile == true, let bytes = size.fileSize, bytes <= 20_000_000 else {
                return .error("Each scene layer must be a regular image file under 20 MB.")
            }
            let data = try Data(contentsOf: sourceURL)
            guard let image = CGImageSourceCreateWithData(data as CFData, nil), CGImageSourceGetCount(image) == 1,
                  CGImageSourceCreateImageAtIndex(image, 0, nil) != nil else {
                return .error("The generated file is not a supported still image.")
            }
            let saved = try assets()
            guard saved[name] == nil else { return .error("That layer already exists. Import a new version with a different filename.") }
            guard saved.count < 80, saved.values.reduce(data.count, { $0 + $1.count }) <= 256_000_000 else {
                return .error("Scene artwork is limited to 80 layers and 256 MB per video; reuse existing layers.")
            }
            onActivity?("Saving scene layer \(name)")
            try Self.writeAssets([name: data], to: root)
            return .text("Saved public/scenes/\(name). Render with <Img src={staticFile('scenes/\(name)')} /> from remotion. The app preserves this layer for reopening, revisions and export.")
        } catch { return .error(error.localizedDescription) }
    }

    /// Maps an agent path ("video.tsx", "src/parts/Title.tsx") into src/, refusing escapes and app-owned files.
    private func resolve(_ raw: String, writing: Bool) throws -> URL {
        var path = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if path.hasPrefix(root.path + "/") { path.removeFirst(root.path.count + 1) }
        while path.hasPrefix("./") { path.removeFirst(2) }
        if path.hasPrefix("src/") { path.removeFirst(4) }
        guard !path.isEmpty, !path.hasPrefix("/"), !path.split(separator: "/").contains("..") else {
            throw PipelineError.invalid("Use a path inside src/, e.g. \"video.tsx\" or \"parts/Title.tsx\".")
        }
        let url = src.appendingPathComponent(path).standardizedFileURL
        guard url.path.hasPrefix(src.standardizedFileURL.path + "/") else { throw PipelineError.invalid("Paths must stay inside src/.") }
        if writing {
            guard !Self.reserved.contains(path) else { throw PipelineError.invalid("src/\(path) is managed by the app and is read-only.") }
            guard Self.extensions.contains(url.pathExtension.lowercased()) else {
                throw PipelineError.invalid("Only .tsx, .ts, .jsx, .js and .css files are allowed.")
            }
        }
        return url
    }

    /// Compiles the project and renders a frame inside the first sung line; nil means it passed.
    func check() async -> String? {
        checks += 1
        engine.close(projectURL: root)
        do {
            if requiresArtwork {
                guard try assets().count >= 3 else {
                    return "Anime Layers requires generated raster artwork: import the environment, transparent character and foreground layers with import_image. Use native Codex image generation; do not substitute SVG scenery or people. If it is unavailable, report the limitation."
                }
                guard FileManager.default.fileExists(atPath: src.appendingPathComponent("scenes.ts").path) else {
                    return "Create src/scenes.ts with the lyric-timed scene plan and layer filenames (rule 18)."
                }
            }
            guard FileManager.default.fileExists(atPath: src.appendingPathComponent("video.tsx").path) else {
                return "src/video.tsx does not exist. Create it and export the root component: export const Video = () => …"
            }
            let project = try await engine.prepare(projectURL: root, entryPoint: "src/index.tsx")
            let compositions = try await engine.compositions(in: project)
            guard let main = compositions.first(where: { $0.id == "Main" }) else { return "No composition was registered." }
            try await engine.renderStill(project: project, frame: min(probeFrame, main.durationInFrames - 1),
                                         to: root.appendingPathComponent("probe.png"))
            engine.close(projectURL: root)
            return nil
        } catch {
            engine.close(projectURL: root)
            return error.localizedDescription
        }
    }

    var tools: [AnyAgentTool] {
        let path: JSONValue = ["type": "string", "description": "Path inside src/, e.g. \"video.tsx\" or \"parts/Title.tsx\"."]
        return [
            .dynamic(name: "list_files",
                     description: "List the files in the video project's src/ folder with their sizes. song.json and index.tsx are app-owned and read-only.",
                     inputSchema: ["type": "object", "properties": [:]],
                     annotations: .readOnly) { [self] _, _ in
                await self.list()
            },
            .dynamic(name: "read_file",
                     description: "Read a file from src/ with line numbers. Long files come back in pages; pass offset (1-based line) to continue. song.json returns a short sample because its shape and all lyrics are already in your brief.",
                     inputSchema: ["type": "object", "properties": [
                        "path": path,
                        "offset": ["type": "integer", "description": "First line to return (1-based). Defaults to 1."]
                     ], "required": ["path"]],
                     annotations: .readOnly) { [self] arguments, _ in
                await self.read(arguments["path"]?.stringValue ?? "", offset: arguments["offset"]?.intValue ?? 1)
            },
            .dynamic(name: "write_file",
                     description: "Create or replace a file in src/ with the full content. Use it to create files; prefer edit_file for changes to existing files.",
                     inputSchema: ["type": "object", "properties": [
                        "path": path,
                        "content": ["type": "string", "description": "The complete file content."]
                     ], "required": ["path", "content"]]) { [self] arguments, _ in
                await self.writeTool(arguments["path"]?.stringValue ?? "", arguments["content"]?.stringValue ?? "")
            },
            .dynamic(name: "edit_file",
                     description: "Replace exact text in a file in src/. old_string must match the file exactly (including indentation) and be unique unless replace_all is true.",
                     inputSchema: ["type": "object", "properties": [
                        "path": path,
                        "old_string": ["type": "string", "description": "Exact text to replace."],
                        "new_string": ["type": "string", "description": "Replacement text."],
                        "replace_all": ["type": "boolean", "description": "Replace every occurrence. Defaults to false."]
                     ], "required": ["path", "old_string", "new_string"]]) { [self] arguments, _ in
                await self.edit(arguments["path"]?.stringValue ?? "", old: arguments["old_string"]?.stringValue ?? "",
                                new: arguments["new_string"]?.stringValue ?? "", all: arguments["replace_all"]?.boolValue ?? false)
            },
            .dynamic(name: "delete_file",
                     description: "Delete a file you created in src/.",
                     inputSchema: ["type": "object", "properties": ["path": path], "required": ["path"]],
                     annotations: .destructive) { [self] arguments, _ in
                await self.delete(arguments["path"]?.stringValue ?? "")
            },
            .dynamic(name: "import_image",
                     description: "Copy a generated raster layer into public/scenes/ for durable preview and export. Call the native Codex image generation tool first, then pass its saved local path. Never send base64. Use transparent PNG for characters and foreground objects.",
                     inputSchema: ["type": "object", "properties": [
                        "source_path": ["type": "string", "description": "Local path returned by native image generation."],
                        "name": ["type": "string", "description": "Unique scene-layer filename, e.g. scene-01-character.png."]
                     ], "required": ["source_path", "name"]]) { [self] arguments, _ in
                await self.importImage(source: arguments["source_path"]?.stringValue ?? "", name: arguments["name"]?.stringValue ?? "")
            },
            .dynamic(name: "check_video",
                     description: "Compile the project and test-render a frame during the first sung line. Returns OK or the compiler/runtime error. Call it after your edits and keep fixing until it returns OK.",
                     inputSchema: ["type": "object", "properties": [:]],
                     annotations: .readOnly) { [self] _, _ in
                await self.checkTool()
            },
        ]
    }

    private func list() -> AgentToolResult {
        onActivity?("Listing files")
        let names = (try? FileManager.default.subpathsOfDirectory(atPath: src.path))?.sorted() ?? []
        let rows = names.compactMap { name -> String? in
            let url = src.appendingPathComponent(name)
            var directory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: url.path, isDirectory: &directory), !directory.boolValue else { return nil }
            let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int) ?? 0
            return "src/\(name) · \(size) bytes\(Self.reserved.contains(name) ? " · read-only" : "")"
        }
        let images = ((try? assets()) ?? [:]).keys.sorted().map { "public/scenes/\($0) · image" }
        return .text((rows + images).isEmpty ? "Project is empty." : (rows + images).joined(separator: "\n"))
    }

    /// Characters per read_file page. Claude Code rejects tool results over ~25k tokens and the agent then
    /// stalls trying to work around it, so every result stays well under that.
    private static let readPageSize = 40_000

    private func read(_ raw: String, offset: Int) -> AgentToolResult {
        do {
            let url = try resolve(raw, writing: false)
            onActivity?("Reading \(url.lastPathComponent)")
            let text = try String(contentsOf: url, encoding: .utf8)
            if relative(url) == "song.json" { return .text(Self.songSample(text)) }
            let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
            let start = max(1, offset)
            guard start <= max(1, lines.count) else { return .error("src/\(relative(url)) has only \(lines.count) lines.") }
            var page = "", line = start
            while line <= lines.count {
                let row = "\(line)\t\(lines[line - 1].prefix(2_000))\n"
                if !page.isEmpty && page.count + row.count > Self.readPageSize { break }
                page += row; line += 1
            }
            if line <= lines.count { page += "… \(lines.count - line + 1) more lines. Call read_file with offset \(line) to continue." }
            return .text(page)
        } catch { return .error("Cannot read \(raw): \(error.localizedDescription)") }
    }

    /// Top-level fields plus the first two lines of song.json (the full file is ~60 KB on one line).
    private static func songSample(_ text: String) -> String {
        guard let json = try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any] else {
            return "song.json follows the DATA CONTRACT in your brief."
        }
        let lines = json["lines"] as? [[String: Any]] ?? []
        var sample = json
        sample["lines"] = Array(lines.prefix(2))
        let body = (try? JSONSerialization.data(withJSONObject: sample, options: [.prettyPrinted, .sortedKeys]))
            .flatMap { String(data: $0, encoding: .utf8) } ?? ""
        return """
        song.json is large (\(text.utf8.count / 1000) KB, \(lines.count) lines), so this is a sample: every top-level field and the first \(min(2, lines.count)) lines. \
        The rest follows the same DATA CONTRACT, and every lyric with its start time is in your brief. Import it; do not try to read it in full.
        \(body)
        """
    }

    private func writeTool(_ raw: String, _ content: String) -> AgentToolResult {
        do {
            let url = try resolve(raw, writing: true)
            guard content.utf8.count <= Self.maxFileSize else { return .error("Files are limited to \(Self.maxFileSize / 1000) KB; split it up.") }
            if !FileManager.default.fileExists(atPath: url.path), files().count >= Self.maxFiles {
                return .error("The project is limited to \(Self.maxFiles) files.")
            }
            onActivity?("Writing \(url.lastPathComponent)")
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try content.write(to: url, atomically: true, encoding: .utf8)
            return .text("Wrote src/\(relative(url)) (\(content.split(separator: "\n", omittingEmptySubsequences: false).count) lines).")
        } catch { return .error(error.localizedDescription) }
    }

    private func edit(_ raw: String, old: String, new: String, all: Bool) -> AgentToolResult {
        do {
            let url = try resolve(raw, writing: true)
            let text = try String(contentsOf: url, encoding: .utf8)
            guard !old.isEmpty else { return .error("old_string is empty; use write_file to create a file.") }
            let count = text.components(separatedBy: old).count - 1
            guard count > 0 else { return .error("old_string was not found in src/\(relative(url)). Read the file and copy the text exactly.") }
            guard count == 1 || all else { return .error("old_string appears \(count) times; add surrounding context or set replace_all.") }
            onActivity?("Editing \(url.lastPathComponent)")
            let updated = all ? text.replacingOccurrences(of: old, with: new) : text.replacingCharacters(in: text.range(of: old)!, with: new)
            guard updated.utf8.count <= Self.maxFileSize else { return .error("The edit would make the file too large.") }
            try updated.write(to: url, atomically: true, encoding: .utf8)
            return .text("Edited src/\(relative(url)) (\(all ? count : 1) replacement\(all && count > 1 ? "s" : "")).")
        } catch { return .error(error.localizedDescription) }
    }

    private func delete(_ raw: String) -> AgentToolResult {
        do {
            let url = try resolve(raw, writing: true)
            onActivity?("Deleting \(url.lastPathComponent)")
            try FileManager.default.removeItem(at: url)
            return .text("Deleted src/\(relative(url)).")
        } catch { return .error(error.localizedDescription) }
    }

    private func checkTool() async -> AgentToolResult {
        onActivity?("Test-rendering the video")
        if let failure = await check() { return .error("check_video failed:\n\(failure)") }
        return .text("OK — the video compiles and renders.")
    }

    private func relative(_ url: URL) -> String {
        String(url.standardizedFileURL.path.dropFirst(src.standardizedFileURL.path.count + 1))
    }
}

/// Allows the workspace tools, and native file tools only inside the project folder; never shell commands.
struct VideoToolPermissions: PermissionResolving {
    let root: String

    func resolve(_ request: PermissionRequest) async -> PermissionDecision {
        if VideoWorkspace.toolNames.contains(MCPToolName.bare(request.toolName)) { return .allow }
        // Only the native image tool, never a shell or arbitrary external image service.
        if ["imagegen", "image_gen", "image_generation"].contains(MCPToolName.bare(request.toolName)) { return .allow }
        guard request.toolName != "Bash", request.toolInput["command"] == nil,
              let data = try? JSONEncoder().encode(request.toolInput),
              let text = String(data: data, encoding: .utf8) else { return .deny }
        // Codex routes MCP tool approval through a generic request that names this app's tool server.
        if text.contains(LocalToolServer.serverName) || VideoWorkspace.toolNames.contains(where: { text.contains($0) }) { return .allow }
        // Codex asks before applying a patch with only item ids (no paths). Its workspace-write sandbox already confines
        // writes to the project folder, which is its working directory, so allow those unless it asks to widen the root.
        if request.toolInput["itemId"] != nil, request.toolInput["serverName"] == nil,
           request.toolInput["grantRoot"]?.stringValue == nil { return .allow }
        let paths = ["file_path", "path", "notebook_path"].compactMap { request.toolInput[$0]?.stringValue }
        let inside = !paths.isEmpty && paths.allSatisfy { path in
            let resolved = URL(fileURLWithPath: path).resolvingSymlinksInPath().standardizedFileURL.path
            return resolved.hasPrefix(root + "/src/") && !resolved.hasSuffix("/src/index.tsx") && !resolved.hasSuffix("/src/song.json")
        }
        return inside ? .allow : .deny
    }
}
