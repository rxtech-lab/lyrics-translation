import SwiftUI
import AppKit

/// Full-height sheet for pasting or editing the original lyrics, with an optional agent clean-up pass.
struct OriginalLyricsSheet: View {
    @Binding var song: Song
    var onSavePlain: (String) -> Void
    var onFormat: (String) -> Void
    @Environment(\.dismiss) private var dismiss
    @AppStorage("formatWithAgent") private var formatWithAgent = true
    @State private var text: String
    @State private var showingAgent = false
    @State private var confirmClear = false
    @FocusState private var editorFocused: Bool

    init(song: Binding<Song>, onSavePlain: @escaping (String) -> Void, onFormat: @escaping (String) -> Void) {
        _song = song
        self.onSavePlain = onSavePlain
        self.onFormat = onFormat
        _text = State(initialValue: song.wrappedValue.sourceText)
    }

    private var rawLines: [String] {
        text.components(separatedBy: .newlines).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }
    /// Lines that look like `[HAMILTON]`, `(Chorus)` or `WASHINGTON:` — handled by the agent, not sung.
    private var tagCount: Int {
        rawLines.filter { line in
            (line.hasPrefix("[") && line.hasSuffix("]")) || (line.hasPrefix("(") && line.hasSuffix(")"))
                || (line.hasSuffix(":") && line == line.uppercased() && line.count < 40)
        }.count
    }
    private var isEmpty: Bool { rawLines.isEmpty }
    private var modelLabel: String {
        let setting = song.formatting
        return "\(setting.provider) · \(setting.model.isEmpty ? "Default model" : setting.model)"
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                editor
                Divider()
                footer
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .navigationTitle("Original Lyrics")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItemGroup(placement: .primaryAction) {
                    Button("Paste", systemImage: "doc.on.clipboard") {
                        if let pasted = NSPasteboard.general.string(forType: .string) { text = pasted }
                    }
                    .help("Replace with clipboard contents")
                    Button("Clear", systemImage: "eraser") { confirmClear = true }
                        .help("Clear all lyrics")
                        .disabled(text.isEmpty)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(formatWithAgent ? "Format & Save" : "Save") {
                        dismiss()
                        if formatWithAgent { onFormat(text) } else { onSavePlain(text) }
                    }
                    .keyboardShortcut(.defaultAction)
                    .disabled(isEmpty)
                }
            }
            .confirmationDialog("Clear all lyrics in this editor?", isPresented: $confirmClear) {
                Button("Clear", role: .destructive) { text = "" }
            } message: { Text("Nothing is saved until you choose Save.") }
            .navigationDestination(isPresented: $showingAgent) { agentSettings }
        }
        .frame(minWidth: 760, idealWidth: 820, maxWidth: .infinity, minHeight: 620, idealHeight: 720, maxHeight: .infinity)
        .onAppear { editorFocused = true }
    }

    private var editor: some View {
        ZStack(alignment: .topLeading) {
            TextEditor(text: $text)
                .font(.system(.title3, design: .serif))
                .lineSpacing(6)
                .scrollContentBackground(.hidden)
                .focused($editorFocused)
            if text.isEmpty {
                VStack(alignment: .leading, spacing: 10) {
                    Text("Paste or type the lyrics as you have them.")
                    Text("[Verse 1]\n[HAMILTON]\nMr. President, you asked to see me?")
                        .font(.system(.body, design: .monospaced))
                }
                .font(.system(.title3, design: .serif))
                .foregroundStyle(.tertiary)
                .padding(.leading, 5)
                .allowsHitTesting(false)
            }
        }
        .padding(.horizontal, 32)
        .padding(.top, 24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.background)
    }

    private var footer: some View {
        HStack(alignment: .center, spacing: 16) {
            Toggle(isOn: $formatWithAgent) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Clean up with agent")
                    Text("Turns tags like [HAMILTON] or [Chorus] into speakers and sections, and removes blank lines.")
                        .font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .toggleStyle(.switch)
            .frame(maxWidth: 380, alignment: .leading)

            if formatWithAgent {
                Button { showingAgent = true } label: {
                    Label(modelLabel, systemImage: "cpu").lineLimit(1)
                }
                .buttonStyle(.bordered)
                .help("Choose the client and model used for formatting")
            }

            Spacer(minLength: 0)

            Text(stats).font(.callout.monospacedDigit()).foregroundStyle(.secondary)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
        .background(.bar)
        .animation(.snappy, value: formatWithAgent)
    }

    private var stats: String {
        let lines = rawLines.count - (formatWithAgent ? tagCount : 0)
        var parts = ["\(max(lines, 0)) line\(lines == 1 ? "" : "s")"]
        if formatWithAgent && tagCount > 0 { parts.append("\(tagCount) tag\(tagCount == 1 ? "" : "s")") }
        return parts.joined(separator: " · ")
    }

    private var agentSettings: some View {
        Form {
            AgentModelPicker(setting: $song.formatting)
            Section {
                Text("The formatting agent only restructures your lyrics. It keeps every sung word in order, never translates, and your current lines are saved to Versions before they are replaced.")
                    .font(.callout).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .navigationTitle("Formatting Agent")
    }
}
