import SwiftUI
import UniformTypeIdentifiers

extension UTType { static let lyricDocument = UTType(exportedAs: "app.rxlab.lyric-document", conformingTo: .data) }
struct Rhyme: Codable, Hashable { var words: String; var sound: String; var relatedLines: [Int] }
struct LyricLine: Codable, Identifiable, Hashable {
    var id = UUID()
    var original: String
    var speaker: String? = nil
    var section: String? = nil
    var translated = ""
    var syllables = 0
    var stress = ""
    var rhymes: [Rhyme] = []
    var review = ""
    var comment = ""
    var approved = false
    /// Word-level karaoke timing of the original text. Optional so older documents still open.
    var originalTiming: [TimedWord]?
    /// Word-level karaoke timing of the translated text.
    var translationTiming: [TimedWord]?
    /// Display tag such as "Chorus · Hamilton".
    var tag: String? { let parts = [section, speaker].compactMap { $0 }; return parts.isEmpty ? nil : parts.joined(separator: " · ") }
    /// Prompt prefix such as "[Chorus] Hamilton: ".
    var label: String { (section.map { "[\($0)] " } ?? "") + (speaker.map { "\($0): " } ?? "") }
}
struct AgentSetting: Codable, Identifiable {
    var id: String
    var provider = "Codex"
    var model = ""
    var executable = ""
    var arguments = ""
}
struct Revision: Codable, Identifiable {
    var id = UUID()
    var date = Date()
    var label: String
    var lines: [LyricLine]
    var direction: String
}
/// Tokens used by one agent call. Prices are not stored; they are applied live from Vercel AI Gateway.
struct UsageRecord: Codable, Identifiable, Hashable, Sendable {
    var id = UUID()
    var date = Date()
    var agent: String
    var provider: String
    /// Model the agent reported or was configured with; empty when the provider default was not reported.
    var model: String
    var step: String
    var input = 0
    var output = 0
    var cacheRead = 0
    var cacheWrite = 0
    /// Cost reported by the client itself (Claude Code), kept for reference.
    var reportedCostUSD: Double?
}
/// One formatting or translation run and every agent call it made.
struct UsageSession: Codable, Identifiable, Hashable, Sendable {
    var id = UUID()
    var date = Date()
    var title: String
    var records: [UsageRecord] = []
}
/// Cost of one agent call, computed in the background and saved so statistics open instantly.
struct PricedUsage: Codable, Hashable, Sendable {
    var cost: Double?
    /// AI Gateway model id the call was priced as.
    var gatewayModel: String?
}
/// Saved usage statistics: per-call prices and the price list they were computed with.
struct UsageStatsCache: Codable, Hashable, Sendable {
    var priceSignature = 0
    var pricedAt: Date?
    var records: [UUID: PricedUsage] = [:]
}
struct Song: Codable {
    var target = "English"
    var direction = ""
    var lines: [LyricLine] = []
    var versions: [Revision] = []
    var agents = ["Direction", "Rhythm and rhyme", "Translator", "Reviewer", "Reviser"].map { AgentSetting(id: $0) }
    /// Agent used to clean up pasted lyrics. Optional so older documents still open.
    var formatter: AgentSetting?
    /// Token usage per run. Optional so older documents still open.
    var usageLog: [UsageSession]?
    /// Cached usage statistics. Optional so older documents still open.
    var usageStats: UsageStatsCache?
    /// Apple Music recording used for playback and karaoke timing.
    var appleMusic: AppleMusicTrack?
    /// Seconds added to every Space press to compensate for reaction time.
    var timingOffset: Double?
    var usage: [UsageSession] {
        get { usageLog ?? [] }
        set { usageLog = newValue }
    }
    /// Formatting agent, falling back to the direction agent's client and model until the user picks one.
    var formatting: AgentSetting {
        get { formatter ?? { var base = agents.first ?? AgentSetting(id: ""); base.id = "Formatting agent"; return base }() }
        set { formatter = newValue }
    }
    /// Lyrics as editable text, with speaker and section tags restored where they change.
    var sourceText: String {
        var output: [String] = [], speaker: String?, section: String?
        for line in lines {
            if let next = line.section, next != section { if !output.isEmpty { output.append("") }; output.append("[\(next)]") }
            if let next = line.speaker, next != speaker { output.append("[\(next.uppercased())]") }
            speaker = line.speaker; section = line.section
            output.append(line.original)
        }
        return output.joined(separator: "\n")
    }
    mutating func checkpoint(_ label: String) { versions.append(Revision(label: label, lines: lines, direction: direction)) }
    /// Stores a fresh rhyme analysis for one line and keeps links symmetric: a partner that points here
    /// shows up on this line even if the model missed it, and this line's partners point back to it.
    /// `relatedLines` are 1-based; self-references (an internal rhyme) are dropped.
    mutating func setRhymes(_ rhymes: [Rhyme], at index: Int) {
        let number = index + 1
        var own = rhymes.map { r in
            var r = r; r.relatedLines = Array(Set(r.relatedLines)).filter { $0 != number && lines.indices.contains($0 - 1) }.sorted(); return r
        }
        // Partners that already link to this line.
        for (k, other) in lines.enumerated() where k != index {
            for r in other.rhymes where r.relatedLines.contains(number) && !own.contains(where: { $0.relatedLines.contains(k + 1) }) {
                own.append(Rhyme(words: r.words, sound: r.sound, relatedLines: [k + 1]))
            }
        }
        lines[index].rhymes = own
        // Make this line's partners link back.
        for r in own {
            for partner in r.relatedLines {
                let p = partner - 1
                guard p != index, lines.indices.contains(p) else { continue }
                if let i = lines[p].rhymes.firstIndex(where: { $0.sound == r.sound || $0.relatedLines.contains(number) }) {
                    if !lines[p].rhymes[i].relatedLines.contains(number) { lines[p].rhymes[i].relatedLines.append(number); lines[p].rhymes[i].relatedLines.sort() }
                } else {
                    lines[p].rhymes.append(Rhyme(words: r.words, sound: r.sound, relatedLines: [number]))
                }
            }
        }
    }
}
struct LyricDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.lyricDocument] }
    var song = Song()
    init() {}
    init(configuration: ReadConfiguration) throws {
        guard let data = configuration.file.regularFileContents else { throw CocoaError(.fileReadCorruptFile) }
        song = try JSONDecoder().decode(Song.self, from: data)
    }
    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: try JSONEncoder().encode(song))
    }
}
@main struct LyricStudioApp: App {
    var body: some Scene { DocumentGroup(newDocument: LyricDocument()) { file in StudioView(document: file.$document, title: file.fileURL?.deletingPathExtension().lastPathComponent ?? "") } }
}
