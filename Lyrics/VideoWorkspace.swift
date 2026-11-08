import Foundation
import RxAgentSDK
import RxRemotion

/// Project folder the video director edits through sandboxed file tools, plus a check that compiles and test-renders it.
///
/// Layout: `src/index.tsx` (app entry) and `src/song.json` (timings) belong to the app; everything else under
/// `src/` belongs to the agent, with `src/video.tsx` exporting the root `Video` component.
@MainActor final class VideoWorkspace {
    nonisolated static let toolNames: Set<String> = ["list_files", "read_file", "write_file", "edit_file", "delete_file", "check_video"]
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

    init(root: URL, probeFrame: Int) {
        self.root = root.resolvingSymlinksInPath()
        self.probeFrame = probeFrame
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
                     description: "Read a file from src/ (including song.json, the timing data).",
                     inputSchema: ["type": "object", "properties": ["path": path], "required": ["path"]],
                     annotations: .readOnly) { [self] arguments, _ in
                await self.read(arguments["path"]?.stringValue ?? "")
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
        return .text(rows.isEmpty ? "src/ is empty." : rows.joined(separator: "\n"))
    }

    private func read(_ raw: String) -> AgentToolResult {
        do {
            let url = try resolve(raw, writing: false)
            onActivity?("Reading \(url.lastPathComponent)")
            return .text(try String(contentsOf: url, encoding: .utf8))
        } catch { return .error("Cannot read \(raw): \(error.localizedDescription)") }
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
        guard request.toolName != "Bash", request.toolInput["command"] == nil,
              let data = try? JSONEncoder().encode(request.toolInput),
              let text = String(data: data, encoding: .utf8) else { return .deny }
        // Codex routes MCP tool approval through a generic request that names this app's tool server.
        if text.contains(LocalToolServer.serverName) || VideoWorkspace.toolNames.contains(where: { text.contains($0) }) { return .allow }
        let paths = ["file_path", "path", "notebook_path"].compactMap { request.toolInput[$0]?.stringValue }
        let inside = !paths.isEmpty && paths.allSatisfy { path in
            let resolved = URL(fileURLWithPath: path).resolvingSymlinksInPath().standardizedFileURL.path
            return resolved.hasPrefix(root + "/src/") && !resolved.hasSuffix("/src/index.tsx") && !resolved.hasSuffix("/src/song.json")
        }
        return inside ? .allow : .deny
    }
}
