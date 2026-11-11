import SwiftUI
import AppKit
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
/// One translation run over a set of lines, kept so it can be resumed.
struct TranslationJob: Codable, Identifiable, Hashable {
    enum State: String, Codable { case running, stopped, failed, completed }
    var id = UUID()
    var created = Date()
    var updated = Date()
    var title: String
    var instruction = ""
    /// Every line in the job, in song order.
    var lineIDs: [UUID]
    /// Lines not translated yet.
    var pendingIDs: [UUID] = []
    var state = State.running
    var status = "Starting"
    var error: String?

    init(title: String, instruction: String, lineIDs: [UUID]) {
        self.title = title
        self.instruction = instruction
        self.lineIDs = lineIDs
        self.pendingIDs = lineIDs
    }
}
struct AgentSetting: Codable, Identifiable {
    var id: String
    var provider = "Codex"
    var model = ""
    var executable = ""
    var arguments = ""
}
/// Remotion project written by the video director agent; it reads timings from song.json at render time.
struct LyricVideoScript: Codable, Identifiable {
    var id = UUID()
    var track: String
    /// Single-file script from earlier versions; `files` supersedes it.
    var source = ""
    /// Agent-owned files under src/, keyed by relative path, e.g. "video.tsx".
    var files: [String: String]?
    /// Generated raster layers, keyed by filename under public/scenes/.
    var assets: [String: Data]?
    var style: String
    var agent: String
    var created = Date()

    init(track: String, files: [String: String], assets: [String: Data]? = nil, style: String, agent: String) {
        self.track = track; self.files = files; self.assets = assets; self.style = style; self.agent = agent
    }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        track = try c.decode(String.self, forKey: .track)
        source = try c.decodeIfPresent(String.self, forKey: .source) ?? ""
        files = try c.decodeIfPresent([String: String].self, forKey: .files)
        assets = try c.decodeIfPresent([String: Data].self, forKey: .assets)
        style = try c.decodeIfPresent(String.self, forKey: .style) ?? "Director’s cut"
        agent = try c.decodeIfPresent(String.self, forKey: .agent) ?? ""
        created = try c.decodeIfPresent(Date.self, forKey: .created) ?? Date()
    }
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
    var publicationID: UUID?
    /// Stable id for the locally saved chat-agent conversation. Optional so older documents still open.
    var conversationID: UUID?
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
    /// Translation runs, newest first, so stopped or interrupted ones can be resumed. Optional so older documents still open.
    var translationJobs: [TranslationJob]?
    /// Single saved lyric video from an earlier build; read once into `videoHistory`.
    var lyricVideo: LyricVideoScript?
    /// Agent-written lyric videos, newest first. Optional so older documents still open.
    var videoScripts: [LyricVideoScript]?
    var videoHistory: [LyricVideoScript] {
        get { videoScripts ?? lyricVideo.map { [$0] } ?? [] }
        set { videoScripts = Array(newValue.prefix(12)); lyricVideo = nil }
    }
    /// Lyric video director agent. Optional so older documents still open.
    var videoDirector: AgentSetting?
    var jobs: [TranslationJob] {
        get { translationJobs ?? [] }
        set { translationJobs = newValue }
    }
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
    /// Joins the given lines, in song order, into one line at the first one's position. Returns the merged line's id.
    @discardableResult mutating func merge(_ ids: Set<UUID>) -> UUID? {
        let indices = lines.indices.filter { ids.contains(lines[$0].id) }
        guard let first = indices.first, indices.count > 1 else { return nil }
        let parts = indices.map { lines[$0] }
        func join(_ texts: [String]) -> String {
            texts.filter { !$0.isEmpty }.reduce("") { result, next in
                guard let last = result.last, let head = next.first else { return result + next }
                // No space between CJK characters; a space everywhere else.
                return result + (last.isCJK && head.isCJK ? "" : " ") + next
            }
        }
        var merged = parts[0]
        merged.original = join(parts.map(\.original))
        merged.translated = parts.allSatisfy { !$0.translated.isEmpty } ? join(parts.map(\.translated)) : ""
        merged.review = ""
        merged.comment = parts.map(\.comment).filter { !$0.isEmpty }.joined(separator: "\n")
        merged.approved = false
        merged.syllables = 0; merged.stress = ""; merged.rhymes = []
        merged.originalTiming = parts.allSatisfy { $0.originalTiming != nil } ? parts.flatMap { $0.originalTiming ?? [] } : nil
        merged.translationTiming = !merged.translated.isEmpty && parts.allSatisfy { $0.translationTiming != nil } ? parts.flatMap { $0.translationTiming ?? [] } : nil
        for index in indices.reversed() { lines.remove(at: index) }
        lines.insert(merged, at: first)
        return merged.id
    }
    /// Replaces one line with several. Translations are kept only when there is one per new line.
    @discardableResult mutating func split(_ id: UUID, originals: [String], translations: [String]) -> [UUID] {
        guard let index = lines.firstIndex(where: { $0.id == id }), originals.count > 1 else { return [] }
        let source = lines[index]
        let keep = translations.count == originals.count
        let pieces = originals.enumerated().map { offset, text in
            LyricLine(original: text, speaker: source.speaker, section: source.section, translated: keep ? translations[offset] : "", comment: source.comment)
        }
        lines.replaceSubrange(index...index, with: pieces)
        return pieces.map(\.id)
    }
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
    @StateObject private var updates = AppUpdates()
    init() {
        NSWindow.allowsAutomaticWindowTabbing = true
    }

    var body: some Scene { DocumentGroup(newDocument: LyricDocument()) { file in
        StudioView(document: file.$document, title: file.fileURL?.deletingPathExtension().lastPathComponent ?? "")
            .background(DocumentWindowTabs())
    }
        .commands { CommandGroup(after: .appInfo) { Button("Check for Updates…") { updates.check() }.disabled(!updates.available) } }
        Settings { AppSettingsView() }
    }
}

/// Configure the document window before display so AppKit supplies its native tab bar.
private struct DocumentWindowTabs: NSViewRepresentable {
    func makeNSView(context: Context) -> TabConfigurationView { TabConfigurationView() }
    func updateNSView(_ nsView: TabConfigurationView, context: Context) {}

    final class TabConfigurationView: NSView {
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            guard let window else { return }
            window.tabbingIdentifier = "app.rxlab.LyricStudio.documents"
            window.tabbingMode = .preferred
        }
    }
}

private extension Character {
    /// Han, kana and hangul, which are written without spaces between words.
    var isCJK: Bool {
        unicodeScalars.contains { (0x3040...0x30FF).contains($0.value) || (0x3400...0x9FFF).contains($0.value) || (0xAC00...0xD7AF).contains($0.value) || (0xF900...0xFAFF).contains($0.value) }
    }
}
