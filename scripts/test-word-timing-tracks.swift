// Compile with WordTimingTracks (WordTimingEditor.swift) and TimedWord (Karaoke.swift).
import Foundation

@main struct WordTimingTracksTests {
    static func main() throws {
        precondition(WordTimingTracks([]).count == 1)
        let touching = WordTimingTracks([(0, 0, 1), (1, 1, 2), (2, 3, 4)])
        precondition(touching.count == 1 && touching.rows.values.allSatisfy { $0 == 0 })

        // Out-of-order lyrics and a long word spanning several shorter words.
        let nested = WordTimingTracks([(3, 2, 3), (0, 0, 4), (2, 1, 2), (1, 0, 1)])
        precondition(nested.count == 2)
        precondition(nested.rows == [0: 0, 1: 1, 2: 1, 3: 1])

        let simultaneous = WordTimingTracks([(2, 1, 3), (0, 1, 3), (1, 1, 3)])
        precondition(simultaneous.count == 3 && simultaneous.rows == [0: 0, 1: 1, 2: 2])

        // The screenshot's parenthetical phrase stays on Track 2 after the overlap ends.
        let phrase = [(index: 0, start: 0.0, end: 0.2), (1, 0.2, 0.6), (2, 0.6, 1.6), (3, 1.2, 1.7), (4, 1.7, 2.1)]
        precondition(WordTimingTracks(phrase).rows == [0: 0, 1: 0, 2: 0, 3: 1, 4: 1])
        precondition(WordTimingTracks.activeIndices(phrase, at: 1.4) == [2, 3])
        precondition(WordTimingTracks.activeIndices(phrase, at: 1.7) == [4])
        precondition(WordTimingTracks.activeIndices(phrase, at: 2.1).isEmpty)

        // Successive overlaps reuse earlier tracks; the rest of each phrase stays together.
        let alternating = WordTimingTracks([
            (0, 0, 2), (1, 1, 3), (2, 3, 5), (3, 4, 6), (4, 6, 8), (5, 7, 9)
        ])
        precondition(alternating.count == 2)
        precondition(alternating.rows == [0: 0, 1: 1, 2: 1, 3: 0, 4: 0, 5: 1])

        // A free earlier track reserved for an explicitly grouped word cannot be reused.
        let reserved = WordTimingTracks([(0, 0, 2), (1, 1, 4), (2, 3, 5), (3, 3, 5)], overrides: [3: 0])
        precondition(reserved.rows == [0: 0, 1: 1, 2: 2, 3: 0])

        let merged = WordTimingTracks(phrase, overrides: [0: 0, 1: 0, 2: 0, 3: 1, 4: 0])
        precondition(merged.rows == [0: 0, 1: 0, 2: 0, 3: 1, 4: 0])
        // If later timing edits create an overlap on an explicitly assigned row, keep words visible.
        let edited = WordTimingTracks([(0, 0, 2), (1, 1, 3)], overrides: [0: 0, 1: 0])
        precondition(edited.rows == [0: 0, 1: 1])

        // Dense, out-of-time-order lyrics must still never cover another word on their track.
        let spans: [(index: Int, start: Double, end: Double)] = (0..<100).map { index in
            let start = Double(index % 17)
            let length = Double(index % 7 + 1)
            return (index, start, start + length)
        }
        let dense = WordTimingTracks(spans)
        for left in spans {
            for right in spans where left.index < right.index && left.start < right.end && right.start < left.end {
                precondition(dense.rows[left.index] != dense.rows[right.index])
            }
        }
        // All song lines participate, retaining word addresses even across untimed words.
        let song = SongWordTimeline(lines: [
            [TimedWord(text: "first", start: 1, end: 3), TimedWord(text: "untimed")],
            [TimedWord(text: "overlap", start: 2, end: 4), TimedWord(text: "later", start: 80, end: 81)]
        ], pointsPerSecond: 260)
        precondition(song.entries.map(\.id) == [0, 2, 3])
        precondition(song.entries.map(\.line) == [0, 1, 1])
        precondition(song.entries.map(\.word) == [0, 0, 1])
        precondition(song.tracks.rows == [0: 0, 2: 1, 3: 1])
        precondition(song.entries.last?.end == 81)
        precondition(SongWordTimeline(lines: [[], [TimedWord(text: "untimed")]], pointsPerSecond: 60).entries.isEmpty)

        let legacy = Data(#"{"text":"York","space":false,"start":0.6,"end":1.6}"#.utf8)
        var saved = try JSONDecoder().decode(TimedWord.self, from: legacy)
        precondition(saved.timingTrack == nil)
        saved.timingTrack = 1
        let reopened = try JSONDecoder().decode(TimedWord.self, from: JSONEncoder().encode(saved))
        precondition(reopened == saved && reopened.timingTrack == 1)
        print("Word timing tracks: all checks passed")
    }
}
