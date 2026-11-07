import SwiftUI

/// Break one long lyric line into several: each line of the text becomes its own lyric line.
struct SplitLineSheet: View {
    let line: LyricLine
    let number: Int
    var onSplit: (_ originals: [String], _ translations: [String]) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var original: String
    @State private var translated: String

    init(line: LyricLine, number: Int, onSplit: @escaping ([String], [String]) -> Void) {
        self.line = line
        self.number = number
        self.onSplit = onSplit
        _original = State(initialValue: Self.breakAtPunctuation(line.original))
        _translated = State(initialValue: Self.breakAtPunctuation(line.translated))
    }

    private static func parts(_ text: String) -> [String] {
        text.components(separatedBy: .newlines).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }
    private var originals: [String] { Self.parts(original) }
    private var translations: [String] { Self.parts(translated) }
    private var mismatch: Bool { !translations.isEmpty && translations.count != originals.count }

    /// Suggests break points after commas and sentence punctuation.
    static func breakAtPunctuation(_ text: String) -> String {
        var result = ""
        for character in text {
            result.append(character)
            if ",.;!?，。；！？、".contains(character) { result.append("\n") }
        }
        return parts(result).joined(separator: "\n")
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextEditor(text: $original).font(.body).frame(minHeight: 120)
                    Button("Break at Punctuation", systemImage: "text.insert") { original = Self.breakAtPunctuation(original.replacingOccurrences(of: "\n", with: " ")) }
                } header: {
                    Text("Original · \(originals.count) line\(originals.count == 1 ? "" : "s")")
                } footer: {
                    Text("Press Return where the line should break. Each line becomes its own lyric line.")
                }
                if !line.translated.isEmpty {
                    Section {
                        TextEditor(text: $translated).font(.body).frame(minHeight: 120)
                    } header: {
                        Text("Translation · \(translations.count) line\(translations.count == 1 ? "" : "s")")
                    } footer: {
                        if mismatch {
                            Label("Break the translation into \(originals.count) lines to keep it, or the new lines start untranslated.", systemImage: "exclamationmark.triangle")
                                .foregroundStyle(.orange)
                        } else {
                            Text("Break the translation the same way to keep it with each new line.")
                        }
                    }
                }
                if line.originalTiming != nil || line.translationTiming != nil {
                    Section { Label("Karaoke word timing for this line is cleared and needs to be retimed.", systemImage: "info.circle").foregroundStyle(.secondary) }
                }
            }
            .formStyle(.grouped)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .navigationTitle("Split Line \(number)")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button(originals.count > 1 ? "Split into \(originals.count) Lines" : "Split") {
                        onSplit(originals, mismatch ? [] : translations)
                        dismiss()
                    }
                    .disabled(originals.count < 2)
                    .keyboardShortcut(.defaultAction)
                }
            }
        }
        .frame(minWidth: 560, idealWidth: 640, maxWidth: .infinity, minHeight: 520, idealHeight: 620, maxHeight: .infinity)
    }
}
