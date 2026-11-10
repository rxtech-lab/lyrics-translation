// Extract WordTimingTracks from WordTimingEditor.swift and compile it with this file to run.
@main struct WordTimingTracksTests {
    static func main() {
        precondition(WordTimingTracks([]).count == 1)
        let touching = WordTimingTracks([(0, 0, 1), (1, 1, 2), (2, 3, 4)])
        precondition(touching.count == 1 && touching.rows.values.allSatisfy { $0 == 0 })

        // Out-of-order lyrics and a long word spanning several shorter words.
        let nested = WordTimingTracks([(3, 2, 3), (0, 0, 4), (2, 1, 2), (1, 0, 1)])
        precondition(nested.count == 2)
        precondition(nested.rows == [0: 0, 1: 1, 2: 1, 3: 1])

        let simultaneous = WordTimingTracks([(2, 1, 3), (0, 1, 3), (1, 1, 3)])
        precondition(simultaneous.count == 3 && simultaneous.rows == [0: 0, 1: 1, 2: 2])

        // A dense line must use exactly its maximum concurrent word count.
        let spans: [(index: Int, start: Double, end: Double)] = (0..<100).map { index in
            let start = Double(index % 17)
            let length = Double(index % 7 + 1)
            return (index, start, start + length)
        }
        let dense = WordTimingTracks(spans)
        let concurrency = spans.map { span in spans.filter { $0.start <= span.start && span.start < $0.end }.count }.max()!
        precondition(dense.count == concurrency)
        for left in spans {
            for right in spans where left.index < right.index && left.start < right.end && right.start < left.end {
                precondition(dense.rows[left.index] != dense.rows[right.index])
            }
        }
        print("Word timing tracks: all checks passed")
    }
}
