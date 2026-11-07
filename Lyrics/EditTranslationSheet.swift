import SwiftUI

/// Hand-edit the translation of one lyric line.
struct EditTranslationSheet: View {
    let line: LyricLine
    let number: Int
    var onSave: (_ translation: String, _ approve: Bool) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var translation: String
    @State private var approve: Bool

    init(line: LyricLine, number: Int, onSave: @escaping (String, Bool) -> Void) {
        self.line = line
        self.number = number
        self.onSave = onSave
        _translation = State(initialValue: line.translated)
        _approve = State(initialValue: true)
    }

    private var trimmed: String { translation.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var changed: Bool { trimmed != line.translated || approve != line.approved }
    private var retimes: Bool { line.translationTiming != nil && trimmed != line.translated }

    var body: some View {
        NavigationStack {
            Form {
                Section("Original") {
                    if let tag = line.tag { Text(tag).font(.caption.weight(.semibold)).foregroundStyle(.tint) }
                    Text(line.original).textSelection(.enabled)
                }
                Section {
                    TextEditor(text: $translation).font(.title3).frame(minHeight: 140)
                } header: {
                    Text("Translation")
                } footer: {
                    if retimes {
                        Label("Karaoke word timing for this translation is cleared and needs to be retimed.", systemImage: "info.circle")
                            .foregroundStyle(.secondary)
                    } else {
                        Text("Your words replace the agent’s translation. A copy is saved in Version History.")
                    }
                }
                Section { Toggle("Mark line as approved", isOn: $approve) }
            }
            .formStyle(.grouped)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .navigationTitle("Edit Translation · Line \(number)")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { onSave(trimmed, approve); dismiss() }
                        .disabled(!changed)
                        .keyboardShortcut(.defaultAction)
                }
            }
        }
        .frame(minWidth: 560, idealWidth: 640, maxWidth: .infinity, minHeight: 480, idealHeight: 560, maxHeight: .infinity)
    }
}
