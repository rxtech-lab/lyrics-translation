import SwiftUI
import Security

/// Credentials stay in this Mac's Keychain and are never included in songs, prompts or MCP tool arguments.
enum ArtworkKeychain {
    static func account(_ config: ArtworkConfiguration) -> String { config.baseURL.trimmingCharacters(in: .whitespacesAndNewlines) }
    private static func query(_ config: ArtworkConfiguration) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: "app.rxlab.LyricStudio.artwork", kSecAttrAccount as String: account(config)]
    }
    static func read(_ config: ArtworkConfiguration) -> String {
        var query = query(config); query[kSecReturnData as String] = true
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess, let data = result as? Data else { return "" }
        return String(decoding: data, as: UTF8.self)
    }
    static func save(_ key: String, for config: ArtworkConfiguration) throws {
        let query = query(config)
        if key.isEmpty { let status = SecItemDelete(query as CFDictionary); guard [errSecSuccess, errSecItemNotFound].contains(status) else { throw ArtworkError("Could not remove the saved image API key.") }; return }
        let data = Data(key.utf8)
        var status = SecItemUpdate(query as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if status == errSecItemNotFound {
            var item = query; item[kSecValueData as String] = data; item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            status = SecItemAdd(item as CFDictionary, nil)
        }
        guard status == errSecSuccess else { throw ArtworkError("Could not save the image API key to Keychain.") }
    }
}

struct ArtworkSettingsSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State private var config = ArtworkConfiguration.load()
    @State private var key = ""
    @State private var models: [ArtworkModel] = []
    @State private var loading = false
    @State private var saving = false
    @State private var error: String?
    @State private var catalogLoaded = false
    var onSave: () -> Void

    var body: some View {
        NavigationStack {
            Form {
                Section("Image Provider") {
                    Picker("Generate with", selection: $config.provider) {
                        ForEach(ArtworkConfiguration.Provider.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                    }
                    if config.provider == .codex {
                        Text("Uses the Codex CLI signed in on this Mac. Claude Code and other directors can call it through the same Generate Image tool.")
                        Text("Run codex login in Terminal if you have not signed in.").font(.caption).foregroundStyle(.secondary)
                    } else {
                        if config.provider == .endpoint { TextField("API base URL", text: $config.endpoint) }
                        else { LabeledContent("Endpoint", value: config.baseURL) }
                        SecureField("API key (optional with environment authentication)", text: $key)
                        Text("Stored in Keychain. An empty key uses AI_GATEWAY_API_KEY / VERCEL_OIDC_TOKEN for Gateway, or OPENAI_API_KEY for a compatible endpoint.")
                            .font(.caption).foregroundStyle(.secondary)
                        Picker("Image model", selection: Binding(get: { config.model?.id ?? "" }, set: { id in config.model = models.first { $0.id == id } })) {
                            Text("Choose a model").tag("")
                            if let model = config.model, !models.contains(model) { Text(model.name + " (saved)").tag(model.id) }
                            ForEach(models) { Text($0.name).tag($0.id) }
                        }
                        Button("Load Image Models", systemImage: "arrow.clockwise") { loadModels() }.disabled(loading)
                        if catalogLoaded && models.isEmpty { Text("No image output models were advertised by this endpoint.").foregroundStyle(.secondary) }
                    }
                }
                Section("Layer Backgrounds") {
                    Text("Cutouts default to transparency. Codex and GPT Image request native alpha; other models render on pure green and the app removes the green background. Full scene plates remain opaque when the director requests it.")
                }
            }
            .formStyle(.grouped)
            .disabled(saving)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .navigationTitle("Artwork Settings")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() }.disabled(saving) }
                ToolbarItem(placement: .confirmationAction) { Button("Save") { save() }.disabled(saving || loading || config.provider != .codex && config.model == nil) }
            }
            .overlay { if saving { ProgressView("Saving artwork settings…").padding(24).background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14)) } }
            .alert("Artwork Settings", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
                Button("OK", role: .cancel) { error = nil }
            } message: { Text(error ?? "") }
        }
        .frame(width: 640, height: 560)
        .onAppear { key = ArtworkKeychain.read(config) }
        .onChange(of: config.provider) { changedEndpoint() }
        .onChange(of: config.endpoint) { changedEndpoint() }
    }

    private func changedEndpoint() {
        models = []; catalogLoaded = false; config.model = nil; key = ArtworkKeychain.read(config)
    }
    private func loadModels() {
        let snapshot = config, credential = key
        loading = true
        Task {
            defer { loading = false }
            do {
                let loaded = try await ArtworkAPI(configuration: snapshot, key: credential).models()
                guard snapshot.baseURL == config.baseURL, snapshot.provider == config.provider else { return }
                models = loaded; catalogLoaded = true
                if let selected = config.model { config.model = loaded.first { $0.id == selected.id } }
            } catch { self.error = error.localizedDescription }
        }
    }
    private func save() {
        saving = true
        Task { @MainActor in
            defer { saving = false }
            do {
                if config.provider != .codex { try ArtworkKeychain.save(key.trimmingCharacters(in: .whitespacesAndNewlines), for: config) }
                try config.save(); onSave(); dismiss()
            } catch { self.error = error.localizedDescription }
        }
    }
}
