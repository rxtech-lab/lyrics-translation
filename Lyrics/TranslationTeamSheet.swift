import SwiftUI

/// Full-height sheet summarising the translation team. Each agent opens its own settings page.
struct TranslationTeamSheet: View {
    @Binding var song: Song
    /// When true the primary action starts translating; otherwise the sheet only edits settings.
    var startsTranslation: Bool
    /// Called with `resume: true` to translate only lines without a translation yet.
    var onStart: (_ resume: Bool) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var path: [String] = []
    @State private var confirmApplyAll: AgentSetting?
    @State private var askingResume = false

    private var translatedCount: Int { song.lines.filter { !$0.translated.isEmpty }.count }
    private var remainingCount: Int { song.lines.count - translatedCount }

    private static let languages = ["English", "Traditional Chinese", "Simplified Chinese", "Japanese", "Korean", "Spanish", "French", "German", "Italian", "Portuguese"]
    private static let formattingID = "Formatting agent"

    var body: some View {
        NavigationStack(path: $path) {
            Form {
                Section {
                    LabeledContent("Target language") {
                        HStack(spacing: 6) {
                            TextField("Target language", text: $song.target, prompt: Text("e.g. Japanese"))
                                .labelsHidden()
                                .multilineTextAlignment(.trailing)
                                .textFieldStyle(.plain)
                            Menu {
                                ForEach(Self.languages, id: \.self) { language in
                                    Button(language) { song.target = language }
                                }
                            } label: { Image(systemName: "globe") }
                            .menuStyle(.borderlessButton)
                            .fixedSize()
                            .help("Common languages")
                        }
                    }
                } footer: {
                    Text("Every line is translated into this language, matched to the original's rhythm and rhyme.")
                }

                Section("Translation pipeline") {
                    ForEach(Array(song.agents.enumerated()), id: \.element.id) { index, agent in
                        NavigationLink(value: agent.id) { AgentRow(setting: agent, step: index + 1) }
                    }
                }

                Section("Preparation") {
                    NavigationLink(value: Self.formattingID) { AgentRow(setting: song.formatting, step: nil) }
                }
            }
            .formStyle(.grouped)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .navigationTitle("Translation Team")
            .navigationDestination(for: String.self) { id in agentDetail(id) }
            .toolbar {
                if startsTranslation {
                    ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Start Translation") {
                            if translatedCount > 0 { askingResume = true } else { dismiss(); onStart(false) }
                        }
                            .keyboardShortcut(.defaultAction)
                            .disabled(song.lines.isEmpty || song.target.trimmingCharacters(in: .whitespaces).isEmpty)
                    }
                } else {
                    ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() }.keyboardShortcut(.defaultAction) }
                }
            }
        }
        .frame(minWidth: 680, idealWidth: 740, maxWidth: .infinity, minHeight: 600, idealHeight: 680, maxHeight: .infinity)
        .confirmationDialog(remainingCount > 0 ? "Resume or start over?" : "Translate again from the start?", isPresented: $askingResume) {
            if remainingCount > 0 {
                Button("Resume · \(remainingCount) line\(remainingCount == 1 ? "" : "s") left") { dismiss(); onStart(true) }
                    .keyboardShortcut(.defaultAction)
            }
            Button("Start from Beginning", role: .destructive) { dismiss(); onStart(false) }
        } message: {
            Text(remainingCount > 0
                 ? "\(translatedCount) of \(song.lines.count) lines already have a translation. Resume keeps them and translates the rest. Starting from the beginning saves the current translations in Versions, clears them, and starts a fresh translation."
                 : "Every line already has a translation. Starting again saves the current translations in Versions, clears them, and starts a fresh translation.")
        }
    }

    @ViewBuilder private func agentDetail(_ id: String) -> some View {
        let binding: Binding<AgentSetting>? = id == Self.formattingID
            ? $song.formatting
            : song.agents.firstIndex(where: { $0.id == id }).map { $song.agents[$0] }
        if let binding {
            Form {
                Section { Text(AgentRole(id).summary).foregroundStyle(.secondary) }
                AgentModelPicker(setting: binding)
                Section {
                    Button("Use This Client and Model for All Agents", systemImage: "square.on.square") { confirmApplyAll = binding.wrappedValue }
                }
            }
            .formStyle(.grouped)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .navigationTitle(AgentRole(id).title)
            .confirmationDialog("Use \(binding.wrappedValue.provider) · \(binding.wrappedValue.model.isEmpty ? "Default model" : binding.wrappedValue.model) for every agent?",
                                isPresented: Binding(get: { confirmApplyAll != nil }, set: { if !$0 { confirmApplyAll = nil } })) {
                Button("Apply to All Agents") { if let source = confirmApplyAll { applyToAll(source) }; confirmApplyAll = nil }
            } message: { Text("This replaces the client and model of all six agents, including formatting.") }
        }
    }

    private func applyToAll(_ source: AgentSetting) {
        func copy(into target: inout AgentSetting) {
            target.provider = source.provider; target.model = source.model
            target.executable = source.executable; target.arguments = source.arguments
        }
        for index in song.agents.indices { copy(into: &song.agents[index]) }
        var formatting = song.formatting; copy(into: &formatting); song.formatting = formatting
    }
}

private struct AgentRow: View {
    var setting: AgentSetting
    var step: Int?
    var body: some View {
        let role = AgentRole(setting.id)
        HStack(spacing: 12) {
            Image(systemName: role.symbol)
                .font(.title3)
                .foregroundStyle(.tint)
                .frame(width: 32, height: 32)
                .background(.tint.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
            VStack(alignment: .leading, spacing: 2) {
                Text(step.map { "\($0). \(role.title)" } ?? role.title).font(.headline)
                Text(role.summary).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 12)
            VStack(alignment: .trailing, spacing: 2) {
                Text(setting.provider).font(.callout)
                Text(setting.model.isEmpty ? "Default model" : setting.model).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
        }
        .padding(.vertical, 4)
    }
}

private struct AgentRole {
    var title: String, symbol: String, summary: String
    init(_ id: String) {
        switch id {
        case "Direction": (title, symbol, summary) = ("Direction", "theatermasks", "Reads the whole song for emotion, voice and adaptation guidelines.")
        case "Rhythm and rhyme": (title, symbol, summary) = ("Rhythm & Rhyme", "waveform", "Estimates syllables, stress and rhymes for each line.")
        case "Translator": (title, symbol, summary) = ("Translator", "character.bubble", "Drafts a singable translation that fits the meter.")
        case "Reviewer": (title, symbol, summary) = ("Reviewer", "checklist", "Critiques each draft for singability, rhyme and fidelity.")
        case "Reviser": (title, symbol, summary) = ("Reviser", "pencil.and.outline", "Applies the review to produce the final line.")
        default: (title, symbol, summary) = ("Formatting", "text.alignleft", "Cleans up pasted lyrics into speakers, sections and lines.")
        }
    }
}
