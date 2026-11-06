import SwiftUI
import RxAgentSDK

struct AgentModelPicker: View {
    @Binding var setting: AgentSetting
    @State private var models: [AgentModelOption] = []
    @State private var loading = false
    @State private var message: String?
    @State private var refresh = 0
    private var identity: String { "\(setting.provider)|\(setting.executable)|\(setting.arguments)|\(refresh)" }

    var body: some View {
        Section(setting.id) {
            Picker("Client", selection: $setting.provider) {
                ForEach(["Codex", "Claude Code", "ACP"], id: \.self) { Text($0) }
            }
            .onChange(of: setting.provider) { setting.model = "" }
            if setting.provider == "ACP" {
                TextField("Executable absolute path", text: $setting.executable)
                    .onChange(of: setting.executable) { setting.model = "" }
                TextField("Arguments, one per line", text: $setting.arguments, axis: .vertical)
                    .onChange(of: setting.arguments) { setting.model = "" }
            }
            Picker("Model", selection: $setting.model) {
                Text("Provider default").tag("")
                if !setting.model.isEmpty && !models.contains(where: { $0.id == setting.model }) {
                    Text("\(setting.model) (saved selection)").tag(setting.model)
                }
                ForEach(models) { model in Text(model.displayName).tag(model.id) }
            }.disabled(loading)
            if let description = models.first(where: { $0.id == setting.model })?.modelDescription {
                Text(description).font(.caption).foregroundStyle(.secondary)
            }
            if let message { Text(message).font(.caption).foregroundStyle(.secondary) }
            Button("Reload models", systemImage: "arrow.clockwise") { refresh += 1 }.disabled(loading)
        }
        .overlay(alignment: .trailing) { if loading { ProgressView().controlSize(.small).padding() } }
        .task(id: identity) {
            let snapshot = setting
            models = []; message = nil; loading = true
            do {
                // Debounce edits to ACP launch settings.
                try await Task.sleep(for: .milliseconds(350))
                if snapshot.provider == "ACP" && !snapshot.executable.hasPrefix("/") {
                    message = "Enter the ACP executable’s absolute path to load models."
                    loading = false
                    return
                }
                guard await snapshot.client().isAvailable() else {
                    message = "Client unavailable. Install and authenticate it, then reload models."
                    loading = false
                    return
                }
                let result = try await ProviderModels.load(snapshot)
                try Task.checkCancellation()
                models = result
                if result.isEmpty { message = "This client returned no models. Provider default remains available." }
                loading = false
            } catch {
                guard !Task.isCancelled else { return }
                message = "Could not load models: \(error.localizedDescription)"
                loading = false
            }
        }
    }
}

enum ProviderModels {
    static func load(_ setting: AgentSetting) async throws -> [AgentModelOption] {
        guard setting.provider == "ACP" else { return await setting.client().availableModels() }
        let process = try ManagedProcess.launch(executable: setting.executable,
            arguments: setting.arguments.split(separator: "\n").map(String.init),
            environment: await ShellEnvironment.shared.environment(),
            workingDirectory: FileManager.default.temporaryDirectory.path)
        let connection = JSONRPCConnection(process: process)
        await connection.start()
        do {
            let result = try await withThrowingTaskGroup(of: JSONValue.self) { group in
                group.addTask {
                    try await connection.request("initialize", params: .object([
                        "protocolVersion": .number(1), "clientCapabilities": .object([:])
                    ]))
                    return try await connection.request("session/new", params: .object([
                        "cwd": .string(FileManager.default.temporaryDirectory.path), "mcpServers": .array([])
                    ]))
                }
                group.addTask {
                    try await Task.sleep(for: .seconds(30))
                    throw PipelineError.invalid("ACP model discovery timed out.")
                }
                defer { group.cancelAll() }
                return try await group.next()!
            }
            await connection.close(); await process.terminate()
            return parse(result)
        } catch {
            await connection.close(); await process.terminate()
            throw error
        }
    }

    static func parse(_ result: JSONValue) -> [AgentModelOption] {
        var options: [AgentModelOption] = []
        for config in result["configOptions"]?.arrayValue ?? [] {
            guard config["category"]?.stringValue == "model", config["type"]?.stringValue == "select" else { continue }
            options = (config["options"]?.arrayValue ?? []).flatMap { entry in
                (entry["options"]?.arrayValue ?? [entry]).compactMap { value in
                    guard let id = value["value"]?.stringValue, !id.isEmpty else { return nil }
                    return AgentModelOption(id: id, displayName: value["name"]?.stringValue ?? id, modelDescription: value["description"]?.stringValue)
                }
            }
            if !options.isEmpty { break }
        }
        if options.isEmpty {
            options = (result["models"]?["availableModels"]?.arrayValue ?? []).compactMap { value in
                guard let id = value["modelId"]?.stringValue, !id.isEmpty else { return nil }
                return AgentModelOption(id: id, displayName: value["name"]?.stringValue ?? id, modelDescription: value["description"]?.stringValue)
            }
        }
        var seen = Set<String>()
        return options.filter { seen.insert($0.id).inserted }
    }
}
