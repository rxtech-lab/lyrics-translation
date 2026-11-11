import Foundation
import RxAgentSDK

/// Uses the user's signed-in Codex CLI, following FineText's short-lived app-server image adapter.
/// The nested session cannot execute shell commands or access the director's MCP tools.
enum CodexArtwork {
    static func generate(prompt: String, reference: URL?) async throws -> Data {
        guard let binary = await ShellEnvironment.shared.findBinary(named: "codex") else {
            throw ArtworkError("Codex is not installed. Install it and run codex login, or choose an API image provider.")
        }
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("LyricArtwork-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        var input: [JSONValue] = [["type": "text", "text": .string(prompt), "text_elements": []]]
        if let reference {
            let target = folder.appendingPathComponent("reference.png")
            try FileManager.default.copyItem(at: reference, to: target)
            input.append(["type": "localImage", "path": .string(target.path)])
        }
        let process = try ManagedProcess.launch(executable: binary,
            arguments: ["-c", "features.image_generation=true", "app-server"],
            environment: await ShellEnvironment.shared.environment(), workingDirectory: folder.path)
        let connection = JSONRPCConnection(process: process)
        let (events, continuation) = AsyncStream<(String, JSONValue)>.makeStream()
        await connection.start(onRequest: { _, _ in .failure(.methodNotFound) }, onNotification: { method, params in
            continuation.yield((method, params))
        })
        let monitor = Task { _ = await process.waitForExit(); continuation.finish() }
        do {
            let runInput = input
            let data = try await withThrowingTaskGroup(of: Data.self) { group in
                group.addTask {
                    try await connection.request("initialize", params: [
                        "clientInfo": ["name": "lyricstudio-artwork", "version": "1.0"],
                        "capabilities": ["experimentalApi": true]
                    ])
                    try await connection.notify("initialized", params: [:])
                    let result = try await connection.request("thread/start", params: [
                        "cwd": .string(folder.path), "approvalPolicy": "never", "sandbox": "read-only", "ephemeral": true,
                        "config": ["mcp_servers": [:]],
                        "developerInstructions": "You are an image generator. Call your native image generation tool exactly once, then stop. Use attached images as references. Honor transparency requests. Never run shell commands, browse, read or edit files, call MCP tools or ask questions."
                    ])
                    guard let id = result["thread"]?["id"]?.stringValue else { throw ArtworkError("Codex returned no image session.") }
                    try await connection.request("turn/start", params: ["threadId": .string(id), "input": .array(runInput)])
                    var failure: String?
                    for await (method, params) in events {
                        try Task.checkCancellation()
                        if method == "item/completed", let item = params["item"], item["type"]?.stringValue == "imageGeneration" {
                            if let result = item["result"]?.stringValue, let image = decode(result) { return image }
                            if let path = item["savedPath"]?.stringValue {
                                let url = URL(fileURLWithPath: path).resolvingSymlinksInPath()
                                let codexHome = ProcessInfo.processInfo.environment["CODEX_HOME"].map { URL(fileURLWithPath: $0) }
                                    ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex")
                                let roots = [folder, codexHome.appendingPathComponent("generated_images")].map { $0.resolvingSymlinksInPath().path + "/" }
                                if roots.contains(where: { url.path.hasPrefix($0) }),
                                   let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize, size <= 20_000_000 {
                                    return try Data(contentsOf: url)
                                }
                            }
                            if item["failure"] != nil { failure = "Codex image generation failed or its image allowance was reached." }
                        }
                        if method == "error", params["willRetry"]?.boolValue != true { throw ArtworkError("Codex image generation failed. Check your Codex login and image allowance.") }
                        if method == "turn/completed" { throw ArtworkError(failure ?? "Codex completed without an image. Check that the signed-in account supports native image generation.") }
                    }
                    throw ArtworkError("Codex exited before returning an image.")
                }
                group.addTask {
                    try await Task.sleep(for: .seconds(600))
                    throw ArtworkError("Codex image generation timed out.")
                }
                defer { group.cancelAll() }
                return try await group.next()!
            }
            await connection.close(); await process.terminate(); continuation.finish(); monitor.cancel()
            return data
        } catch {
            await connection.close(); await process.terminate(); continuation.finish(); monitor.cancel()
            throw error
        }
    }

    static func decode(_ value: String) -> Data? {
        let payload = value.hasPrefix("data:") ? value.split(separator: ",", maxSplits: 1).last.map(String.init) ?? "" : value
        guard payload.count <= 28_000_000 else { return nil }
        return Data(base64Encoded: payload)
    }
}
