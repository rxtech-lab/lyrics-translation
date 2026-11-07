import SwiftUI

/// Pick one or more lines and (re)translate them, optionally with extra instructions.
struct TranslateLinesSheet: View {
    let lines: [LyricLine]
    var onTranslate: (Set<UUID>, String) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var picked: Set<UUID>
    @State private var instruction = ""

    init(lines: [LyricLine], initial: Set<UUID>, onTranslate: @escaping (Set<UUID>, String) -> Void) {
        self.lines = lines
        self.onTranslate = onTranslate
        _picked = State(initialValue: initial)
    }

    private var hasTranslations: Bool { lines.contains { picked.contains($0.id) && !$0.translated.isEmpty } }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextEditor(text: $instruction)
                        .font(.body)
                        .frame(minHeight: 90)
                        .overlay(alignment: .topLeading) {
                            if instruction.isEmpty {
                                Text("Optional, e.g. “Keep the rhyme on -ang”, “Make it more casual”, or a suggested wording")
                                    .foregroundStyle(.tertiary).padding(.top, 1).padding(.leading, 5).allowsHitTesting(false)
                            }
                        }
                } header: {
                    Text("Instructions")
                } footer: {
                    Text("Applied to every selected line on top of the song’s direction and each line’s feedback.")
                }
                Section {
                    ForEach(Array(lines.enumerated()), id: \.element.id) { index, line in
                        Toggle(isOn: Binding(get: { picked.contains(line.id) },
                                             set: { if $0 { picked.insert(line.id) } else { picked.remove(line.id) } })) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("\(index + 1)  \(line.original)").lineLimit(1)
                                Text(line.translated.isEmpty ? "Not translated" : line.translated)
                                    .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                            }
                        }
                    }
                } header: {
                    HStack {
                        Text("Lines · \(picked.count) selected")
                        Spacer()
                        Button("Select All") { picked = Set(lines.map(\.id)) }.buttonStyle(.link)
                        Button("Untranslated") { picked = Set(lines.filter { $0.translated.isEmpty }.map(\.id)) }.buttonStyle(.link)
                        Button("None") { picked = [] }.buttonStyle(.link)
                    }
                }
            }
            .formStyle(.grouped)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .navigationTitle("Translate Lines")
            .navigationSubtitle(hasTranslations ? "Current translations are saved in Versions first" : "")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button(picked.count == 1 ? "Translate Line" : "Translate \(picked.count) Lines") {
                        onTranslate(picked, instruction)
                        dismiss()
                    }
                    .disabled(picked.isEmpty)
                    .keyboardShortcut(.defaultAction)
                }
            }
        }
        .frame(minWidth: 620, idealWidth: 720, maxWidth: .infinity, minHeight: 600, idealHeight: 720, maxHeight: .infinity)
    }
}
