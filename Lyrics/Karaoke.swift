import SwiftUI
import UniformTypeIdentifiers

/// One sung word (or CJK character) with the time it starts and stops, in seconds into the recording.
struct TimedWord: Codable, Hashable {
    var text: String
    /// Whether a space follows the word when the line is written out.
    var space = false
    var start: Double?
    var end: Double?
    /// Explicit editor track, saved only when the user groups words onto a track.
    var timingTrack: Int?
}

/// Apple Music catalog song linked to the document.
struct AppleMusicTrack: Codable, Hashable, Identifiable {
    var id: String
    var title: String
    var artist: String
    var album: String?
    var artworkURL: URL?
    var duration: Double?
    var url: URL?
}

/// Which text of each line is timed and shown as the karaoke subtitle.
enum KaraokeTrack: String, CaseIterable, Identifiable {
    case original = "Original", translation = "Translation"
    var id: Self { self }
    var other: KaraokeTrack { self == .original ? .translation : .original }
}

/// Which lyrics the karaoke stage shows.
enum LyricDisplay: String, CaseIterable, Identifiable {
    case both, original, translation
    var id: Self { self }
    var title: String {
        switch self {
        case .both: "Original + Translation"
        case .original: "Original"
        case .translation: "Translation"
        }
    }
    /// The only track shown, or nil when both are.
    var single: KaraokeTrack? {
        switch self {
        case .both: nil
        case .original: .original
        case .translation: .translation
        }
    }
}

extension TimedWord {
    /// Splits text into timeable words. Spaced scripts split on whitespace; Chinese and Japanese split per character,
    /// keeping punctuation attached to the character before it.
    static func split(_ text: String) -> [TimedWord] {
        var words: [TimedWord] = []
        for chunk in text.split(whereSeparator: \.isWhitespace) {
            var pieces: [String] = [], buffer = ""
            for character in chunk {
                if character.isCJK {
                    if buffer.contains(where: { $0.isLetter || $0.isNumber }) { pieces.append(buffer); buffer = "" }
                    pieces.append(buffer + String(character)); buffer = ""
                } else if buffer.isEmpty, character.isPunctuation, !"「『（(“‘《〈[{".contains(character), let last = pieces.last, last.last?.isCJK == true || last.last?.isPunctuation == true {
                    pieces[pieces.count - 1].append(character)
                } else {
                    buffer.append(character)
                }
            }
            if !buffer.isEmpty {
                if !buffer.contains(where: { $0.isLetter || $0.isNumber }), !pieces.isEmpty { pieces[pieces.count - 1] += buffer } else { pieces.append(buffer) }
            }
            words += pieces.enumerated().map { TimedWord(text: $0.element, space: $0.offset == pieces.count - 1) }
        }
        if !words.isEmpty { words[words.count - 1].space = false }
        return words
    }

    /// Extend completed words to the next adjacent word's start without moving onsets,
    /// crossing untimed words, shortening overlaps, or changing the final word.
    static func closingGaps(_ words: [TimedWord]) -> [TimedWord] {
        var result = words
        for index in words.indices.dropLast() {
            guard let start = words[index].start, let end = words[index].end,
                  let next = words[index + 1].start,
                  start <= end, end < next else { continue }
            result[index].end = next
        }
        return result
    }

    /// Whether the word has any recorded time.
    var isTimed: Bool { start != nil || end != nil }

    /// Start and end of each word. A missing end is filled with the next word's start; a missing start
    /// (a word saved with only an end) begins where the previous word stopped.
    static func resolve(_ words: [TimedWord]) -> [ClosedRange<Double>?] {
        var ranges: [ClosedRange<Double>?] = []
        var previousEnd: Double?
        for index in words.indices {
            let word = words[index]
            guard word.isTimed else { ranges.append(nil); previousEnd = nil; continue }
            var start = word.start ?? previousEnd ?? max(0, (word.end ?? 0) - 0.4)
            if let end = word.end, word.start == nil { start = min(start, end) }
            // If the next word only has an end, it shares this word's span: split it halfway.
            let next = words[(index + 1)...].lazy.compactMap { $0.start ?? $0.end.map { (start + $0) / 2 } }.first
            let end = word.end ?? next.map { min($0, start + 1.5) } ?? start + 0.5
            let range = start...max(start, end)
            ranges.append(range)
            previousEnd = range.upperBound
        }
        return ranges
    }
}

private extension Character {
    var isCJK: Bool {
        unicodeScalars.contains { scalar in
            switch scalar.value {
            case 0x3040...0x30FF, 0x3400...0x4DBF, 0x4E00...0x9FFF, 0xF900...0xFAFF, 0x20000...0x2FFFF: true
            default: false
            }
        }
    }
}

extension LyricLine {
    func text(_ track: KaraokeTrack) -> String { track == .original ? original : translated }

    /// Words of the track's current text, keeping saved times only while the text is unchanged.
    func words(_ track: KaraokeTrack) -> [TimedWord] {
        let fresh = TimedWord.split(text(track))
        let saved = (track == .original ? originalTiming : translationTiming) ?? []
        return saved.map(\.text) == fresh.map(\.text) ? saved : fresh
    }

    mutating func setWords(_ words: [TimedWord], _ track: KaraokeTrack) {
        let value = words.contains(where: \.isTimed) ? words : nil
        if track == .original { originalTiming = value } else { translationTiming = value }
    }

    /// When the line starts and stops, if any of its words are timed.
    func span(_ track: KaraokeTrack) -> ClosedRange<Double>? {
        let ranges = TimedWord.resolve(words(track)).compactMap { $0 }
        guard let start = ranges.map(\.lowerBound).min(), let end = ranges.map(\.upperBound).max() else { return nil }
        return start...end
    }
}

extension Song {
    func timedCount(_ track: KaraokeTrack) -> (timed: Int, total: Int) {
        let words = lines.flatMap { $0.words(track) }
        return (words.filter(\.isTimed).count, words.count)
    }
}

enum KaraokeClock {
    /// 1:05.3 for on-screen display.
    static func display(_ seconds: Double) -> String {
        let value = max(0, seconds)
        return String(format: "%d:%04.1f", Int(value) / 60, value.truncatingRemainder(dividingBy: 60))
    }
    /// 1:05.32 for the precise timing ruler.
    static func precise(_ seconds: Double) -> String {
        let centi = Int((max(0, seconds) * 100).rounded())
        return String(format: "%d:%02d.%02d", centi / 6000, centi / 100 % 60, centi % 100)
    }
    /// 01:05.32 for LRC.
    static func lrc(_ seconds: Double) -> String {
        let centi = Int((max(0, seconds) * 100).rounded())
        return String(format: "%02d:%02d.%02d", centi / 6000, centi / 100 % 60, centi % 100)
    }
    /// 00:01:05.320 for TTML.
    static func ttml(_ seconds: Double) -> String {
        let milli = Int((max(0, seconds) * 1000).rounded())
        return String(format: "%02d:%02d:%02d.%03d", milli / 3_600_000, milli / 60_000 % 60, milli / 1000 % 60, milli % 1000)
    }
}

// MARK: Export

extension UTType {
    static let lrc = UTType(filenameExtension: "lrc", conformingTo: .plainText) ?? .plainText
    static let ttml = UTType(filenameExtension: "ttml", conformingTo: .xml) ?? .xml
}

enum SubtitleFormat: String, CaseIterable, Identifiable {
    case lrc, ttml
    var id: Self { self }
    var title: String { self == .lrc ? "Enhanced LRC (.lrc)" : "Word-timed TTML (.ttml)" }
    var type: UTType { self == .lrc ? .lrc : .ttml }

    func render(_ song: Song, track: KaraokeTrack) -> String {
        self == .lrc ? Self.renderLRC(song, track: track) : Self.renderTTML(song, track: track)
    }

    /// Enhanced LRC with a `<mm:ss.xx>` stamp before each word and after the last one.
    private static func renderLRC(_ song: Song, track: KaraokeTrack) -> String {
        var output: [String] = []
        if let music = song.appleMusic { output += ["[ti:\(music.title)]", "[ar:\(music.artist)]"]; if let album = music.album { output.append("[al:\(album)]") } }
        output.append("[re:Lyric Studio]")
        for line in song.lines {
            let words = line.words(track)
            guard let span = line.span(track) else { continue }
            let ranges = TimedWord.resolve(words)
            var text = "[\(KaraokeClock.lrc(span.lowerBound))]"
            for (word, range) in zip(words, ranges) {
                if let range { text += "<\(KaraokeClock.lrc(range.lowerBound))>" }
                text += word.text + (word.space ? " " : "")
            }
            text += "<\(KaraokeClock.lrc(span.upperBound))>"
            output.append(text)
        }
        return output.joined(separator: "\n") + "\n"
    }

    /// TTML in the word-timed layout Apple Music uses, with the other track as an `x-translation` span.
    private static func renderTTML(_ song: Song, track: KaraokeTrack) -> String {
        let timed = song.lines.enumerated().compactMap { index, line in line.span(track).map { (index, line, $0) } }
        let end = timed.map(\.2.upperBound).max() ?? 0
        var body: [String] = []
        var section: String?? = .none
        for (index, line, span) in timed {
            if section != .some(line.section) {
                if section != nil { body.append("    </div>") }
                section = .some(line.section)
                let part = line.section.map { " itunes:song-part=\"\(escape($0))\"" } ?? ""
                body.append("    <div\(part)>")
            }
            let ranges = TimedWord.resolve(line.words(track))
            var spans = ""
            for (word, range) in zip(line.words(track), ranges) {
                if let range { spans += "<span begin=\"\(KaraokeClock.ttml(range.lowerBound))\" end=\"\(KaraokeClock.ttml(range.upperBound))\">\(escape(word.text))</span>" }
                else { spans += escape(word.text) }
                if word.space { spans += " " }
            }
            let companion = line.text(track.other)
            if !companion.isEmpty { spans += "<span ttm:role=\"x-translation\">\(escape(companion))</span>" }
            let agent = line.speaker.map { " ttm:agent=\"\(escape($0))\"" } ?? ""
            body.append("      <p begin=\"\(KaraokeClock.ttml(span.lowerBound))\" end=\"\(KaraokeClock.ttml(span.upperBound))\" itunes:key=\"L\(index + 1)\"\(agent)>\(spans)</p>")
        }
        if section != nil { body.append("    </div>") }
        let title = song.appleMusic.map { "\n    <metadata><ttm:title>\(escape($0.title))</ttm:title></metadata>" } ?? ""
        return """
        <?xml version="1.0" encoding="UTF-8"?>
        <tt xmlns="http://www.w3.org/ns/ttml" xmlns:ttm="http://www.w3.org/ns/ttml#metadata" xmlns:itunes="http://music.apple.com/lyric-ttml-internal" itunes:timing="Word">
          <head>\(title)
          </head>
          <body dur="\(KaraokeClock.ttml(end))">
        \(body.joined(separator: "\n"))
          </body>
        </tt>

        """
    }

    private static func escape(_ text: String) -> String {
        text.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;").replacingOccurrences(of: "\"", with: "&quot;")
    }
}

/// Plain text file handed to `fileExporter`.
struct SubtitleFile: FileDocument {
    static var readableContentTypes: [UTType] { [.plainText] }
    static var writableContentTypes: [UTType] { [.lrc, .ttml, .plainText] }
    var text = ""
    init(text: String) { self.text = text }
    init(configuration: ReadConfiguration) throws { text = String(decoding: configuration.file.regularFileContents ?? Data(), as: UTF8.self) }
    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper { FileWrapper(regularFileWithContents: Data(text.utf8)) }
}

// MARK: Layout

/// Wraps words onto rows like text, so each word can be its own view.
struct FlowLayout: Layout {
    var alignment: HorizontalAlignment = .leading
    var spacing: CGFloat = 0
    var lineSpacing: CGFloat = 6

    private func rows(_ subviews: Subviews, width: CGFloat) -> [(items: [(Int, CGSize)], width: CGFloat, height: CGFloat)] {
        var rows: [(items: [(Int, CGSize)], width: CGFloat, height: CGFloat)] = [([], 0, 0)]
        for (index, view) in subviews.enumerated() {
            let size = view.sizeThatFits(.unspecified)
            let needed = rows[rows.count - 1].items.isEmpty ? size.width : rows[rows.count - 1].width + spacing + size.width
            if needed > width, !rows[rows.count - 1].items.isEmpty { rows.append(([], 0, 0)) }
            let row = rows.count - 1
            rows[row].width += (rows[row].items.isEmpty ? 0 : spacing) + size.width
            rows[row].height = max(rows[row].height, size.height)
            rows[row].items.append((index, size))
        }
        return rows
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let rows = rows(subviews, width: proposal.width ?? .infinity)
        let height = rows.map(\.height).reduce(0, +) + lineSpacing * CGFloat(max(0, rows.count - 1))
        return CGSize(width: proposal.width ?? rows.map(\.width).max() ?? 0, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var y = bounds.minY
        for row in rows(subviews, width: bounds.width) {
            var x = switch alignment {
            case .center: bounds.minX + (bounds.width - row.width) / 2
            case .trailing: bounds.maxX - row.width
            default: bounds.minX
            }
            for (index, size) in row.items {
                subviews[index].place(at: CGPoint(x: x, y: y + (row.height - size.height) / 2), proposal: ProposedViewSize(size))
                x += size.width + spacing
            }
            y += row.height + lineSpacing
        }
    }
}
