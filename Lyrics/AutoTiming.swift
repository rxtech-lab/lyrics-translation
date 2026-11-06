import AVFoundation
import Foundation
import NaturalLanguage
import Speech

/// A word heard by the speech recogniser, in seconds into the audio file.
struct RecognizedWord: Sendable, Hashable {
    var text: String
    var start: Double
    var end: Double
}

enum AutoTimingError: LocalizedError {
    case unsupportedLanguage(String), unreadableAudio, nothingRecognized, capturePermission, silentCapture

    var errorDescription: String? {
        switch self {
        case .unsupportedLanguage(let name): "On-device speech recognition doesn’t support \(name) on this Mac."
        case .unreadableAudio: "This audio file can’t be read. Choose an unprotected file such as MP3, M4A, WAV or AIFF."
        case .nothingRecognized: "No sung words were recognised."
        case .capturePermission: "Lyric Studio can’t listen to the song. Allow it in System Settings › Privacy & Security › Screen & System Audio Recording, then try again."
        case .silentCapture: "Lyric Studio couldn’t hear the song. macOS may be blocking recording of this protected Apple Music stream, the volume may be muted, or the Screen & System Audio Recording permission is off. Try again with a local copy of the recording."
        }
    }
}

/// Automatic word timing.
///
/// - `transcribe` runs Apple's on-device `SpeechTranscriber` over a local recording and returns every recognised
///   word with its time range. The lyrics are passed as contextual strings so sung words are recognised more reliably.
/// - `align` matches the recognised words to the lyric words with a global sequence alignment (Needleman–Wunsch
///   over normalised tokens with fuzzy matching), so missed, extra or misheard words don’t shift the rest of the song.
/// - `interpolate` fills the words that weren’t matched (or weren’t pressed) between timed neighbours,
///   splitting the time by estimated sung syllables. It is also used on its own as “Fill Gaps”.
enum AutoTiming {
    /// Seconds per sung syllable used when a gap has no right-hand anchor.
    static let syllableDuration = 0.22

    // MARK: Speech recognition

    /// Most likely language of the given text, defaulting to English.
    static func language(of text: String) -> Locale {
        let recognizer = NLLanguageRecognizer()
        recognizer.processString(text)
        return Locale(identifier: recognizer.dominantLanguage?.rawValue ?? "en")
    }

    /// A transcriber for the language with word time ranges, downloading its model when needed.
    private static func makeTranscriber(_ locale: Locale, progress: @Sendable (Double, String) -> Void) async throws -> SpeechTranscriber {
        let name = Locale.current.localizedString(forIdentifier: locale.identifier) ?? locale.identifier
        guard let supported = await SpeechTranscriber.supportedLocale(equivalentTo: locale) else { throw AutoTimingError.unsupportedLanguage(name) }
        let transcriber = SpeechTranscriber(locale: supported, transcriptionOptions: [], reportingOptions: [], attributeOptions: [.audioTimeRange])
        if let request = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
            progress(0, "Downloading the \(name) speech model…")
            try await request.downloadAndInstall()
        }
        return transcriber
    }

    private static func context(_ hints: [String]) -> AnalysisContext {
        let context = AnalysisContext()
        context.contextualStrings[.general] = Array(hints.prefix(500))
        return context
    }

    static func transcribe(url: URL, locale: Locale, hints: [String], progress: @escaping @Sendable (Double, String) -> Void) async throws -> [RecognizedWord] {
        let transcriber = try await makeTranscriber(locale, progress: progress)
        let file: AVAudioFile
        do { file = try AVAudioFile(forReading: url) } catch { throw AutoTimingError.unreadableAudio }
        let duration = max(1, Double(file.length) / file.processingFormat.sampleRate)
        progress(0, "Listening for sung words…")

        let collector = Task { () throws -> [RecognizedWord] in
            var words: [RecognizedWord] = []
            for try await result in transcriber.results {
                words += recognizedWords(in: result.text)
                if let last = words.last { progress(min(1, last.end / duration), "Listening for sung words…") }
            }
            return words
        }
        do {
            _ = try await SpeechAnalyzer(inputAudioFile: file, modules: [transcriber], analysisContext: context(hints), finishAfterFile: true)
        } catch {
            collector.cancel()
            throw error
        }
        let words = try await withTaskCancellationHandler { try await collector.value } onCancel: { collector.cancel() }
        guard !words.isEmpty else { throw AutoTimingError.nothingRecognized }
        return words.sorted { $0.start < $1.start }
    }

    /// Recognises words live from captured audio until the capture stops. Word times are on the host clock
    /// (the clock captured audio is stamped with); map them to song time with the player clock.
    /// Throws `silentCapture` if nothing but silence arrives in the first seconds.
    static func transcribeLive(_ capture: SystemAudioCapture, locale: Locale, hints: [String],
                               progress: @escaping @Sendable (Double, String) -> Void,
                               heard: @escaping @Sendable (Int) -> Void) async throws -> [RecognizedWord] {
        let transcriber = try await makeTranscriber(locale, progress: progress)
        guard let format = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [transcriber]) else { throw AutoTimingError.silentCapture }
        let (inputs, feed) = AsyncStream<AnalyzerInput>.makeStream()
        let analyzer = SpeechAnalyzer(modules: [transcriber])
        try await analyzer.setContext(context(hints))
        try await analyzer.prepareToAnalyze(in: format)

        let collector = Task { () throws -> [RecognizedWord] in
            var words: [RecognizedWord] = []
            for try await result in transcriber.results {
                words += recognizedWords(in: result.text)
                heard(words.count)
            }
            return words
        }
        try await analyzer.start(inputSequence: inputs)
        progress(0, "Listening to Apple Music…")

        var origin: Double?
        var converter: AVAudioConverter?
        var seconds = 0.0, peak: Float = 0
        do {
            for await chunk in capture.audio {
                try Task.checkCancellation()
                let start = origin ?? chunk.hostTime
                origin = start
                let buffer = chunk.buffer
                if seconds < 10 {
                    peak = max(peak, level(buffer))
                    seconds += Double(buffer.frameLength) / buffer.format.sampleRate
                    if seconds >= 8, peak < 0.0005 { throw AutoTimingError.silentCapture }
                }
                if converter == nil || converter?.inputFormat != buffer.format { converter = AVAudioConverter(from: buffer.format, to: format) }
                guard let converter, let converted = convert(buffer, with: converter, to: format) else { continue }
                feed.yield(AnalyzerInput(buffer: converted, bufferStartTime: CMTime(seconds: chunk.hostTime - start, preferredTimescale: 48_000)))
            }
            feed.finish()
            try await analyzer.finalizeAndFinishThroughEndOfInput()
        } catch {
            feed.finish()
            await analyzer.cancelAndFinishNow()
            collector.cancel()
            throw error
        }
        let words = try await withTaskCancellationHandler { try await collector.value } onCancel: { collector.cancel() }
        guard !words.isEmpty, let origin else { throw AutoTimingError.nothingRecognized }
        return words.map { RecognizedWord(text: $0.text, start: $0.start + origin, end: $0.end + origin) }.sorted { $0.start < $1.start }
    }

    /// Peak absolute sample of a float buffer (0 when the format isn't float).
    private static func level(_ buffer: AVAudioPCMBuffer) -> Float {
        guard let channels = buffer.floatChannelData else { return 1 }
        var peak: Float = 0
        for channel in 0..<Int(buffer.format.channelCount) {
            for frame in 0..<Int(buffer.frameLength) { peak = max(peak, abs(channels[channel][frame])) }
        }
        return peak
    }

    private static func convert(_ buffer: AVAudioPCMBuffer, with converter: AVAudioConverter, to format: AVAudioFormat) -> AVAudioPCMBuffer? {
        if buffer.format == format { return buffer }
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * format.sampleRate / buffer.format.sampleRate) + 64
        guard let output = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: capacity) else { return nil }
        nonisolated(unsafe) var consumed = false
        var error: NSError?
        let status = converter.convert(to: output, error: &error) { _, state in
            if consumed { state.pointee = .noDataNow; return nil }
            consumed = true
            state.pointee = .haveData
            return buffer
        }
        return status == .error || output.frameLength == 0 ? nil : output
    }

    /// Splits a transcription into words. A run that covers several words shares its time by character count.
    private static func recognizedWords(in text: AttributedString) -> [RecognizedWord] {
        var words: [RecognizedWord] = []
        for run in text.runs {
            guard let range = run.audioTimeRange else { continue }
            let pieces = TimedWord.split(String(text[run.range].characters)).map(\.text)
            guard !pieces.isEmpty else { continue }
            let start = range.start.seconds, end = range.end.seconds
            guard start.isFinite, end.isFinite else { continue }
            let total = Double(pieces.reduce(0) { $0 + max(1, $1.count) })
            var cursor = start
            for piece in pieces {
                let length = (end - start) * Double(max(1, piece.count)) / total
                words.append(RecognizedWord(text: piece, start: cursor, end: cursor + length))
                cursor += length
            }
        }
        return words
    }

    // MARK: Alignment

    /// Lowercased letters and digits only, so punctuation and curly quotes don’t block matches.
    static func normalize(_ text: String) -> String {
        String(text.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: nil)
            .unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) }.map(Character.init))
    }

    /// Match score of a lyric word and a recognised word: 3 exact, 1 close (mishearing), otherwise a mismatch.
    static func similarity(_ a: String, _ b: String) -> Int {
        if a == b { return 3 }
        if a.count >= 3, b.count >= 3, a.hasPrefix(b) || b.hasPrefix(a) { return 1 }
        let longest = max(a.count, b.count)
        guard longest >= 3 else { return -2 }
        return 1 - Double(editDistance(a, b)) / Double(longest) >= 0.65 ? 1 : -2
    }

    static func editDistance(_ a: String, _ b: String) -> Int {
        let a = Array(a), b = Array(b)
        guard !a.isEmpty else { return b.count }
        guard !b.isEmpty else { return a.count }
        var previous = Array(0...b.count), current = Array(repeating: 0, count: b.count + 1)
        for i in 1...a.count {
            current[0] = i
            for j in 1...b.count {
                current[j] = min(previous[j] + 1, current[j - 1] + 1, previous[j - 1] + (a[i - 1] == b[j - 1] ? 0 : 1))
            }
            swap(&previous, &current)
        }
        return previous[b.count]
    }

    /// Global alignment of lyric tokens to recognised tokens. Returns, for each lyric token, the matched recognised index.
    static func alignTokens(_ lyrics: [String], _ heard: [String]) -> [Int?] {
        let n = lyrics.count, m = heard.count
        guard n > 0, m > 0 else { return Array(repeating: nil, count: n) }
        let gap = -1
        let width = m + 1
        var score = [Int32](repeating: 0, count: (n + 1) * width)
        // 0 diagonal, 1 skip lyric word (not heard), 2 skip heard word (extra)
        var move = [UInt8](repeating: 0, count: (n + 1) * width)
        for i in 1...n { score[i * width] = Int32(i * gap); move[i * width] = 1 }
        for j in 1...m { score[j] = Int32(j * gap); move[j] = 2 }
        for i in 1...n {
            for j in 1...m {
                let diagonal = score[(i - 1) * width + j - 1] + Int32(similarity(lyrics[i - 1], heard[j - 1]))
                let up = score[(i - 1) * width + j] + Int32(gap)
                let left = score[i * width + j - 1] + Int32(gap)
                if diagonal >= up, diagonal >= left { score[i * width + j] = diagonal; move[i * width + j] = 0 }
                else if up >= left { score[i * width + j] = up; move[i * width + j] = 1 }
                else { score[i * width + j] = left; move[i * width + j] = 2 }
            }
        }
        var result = [Int?](repeating: nil, count: n)
        var i = n, j = m
        while i > 0, j > 0 {
            switch move[i * width + j] {
            case 0:
                if similarity(lyrics[i - 1], heard[j - 1]) > 0 { result[i - 1] = j - 1 }
                i -= 1; j -= 1
            case 1: i -= 1
            default: j -= 1
            }
        }
        return result
    }

    struct Alignment {
        var lines: [[TimedWord]]
        var matched: Int
        var filled: Int
        var total: Int
    }

    /// Times every line from recognised words. With `keepExisting`, words already timed are left as they are
    /// and act as anchors; recognised times are shifted by `offset` seconds.
    static func align(lines: [[TimedWord]], recognized: [RecognizedWord], keepExisting: Bool, offset: Double) -> Alignment {
        var positions: [(line: Int, word: Int)] = []
        var tokens: [String] = []
        for (line, words) in lines.enumerated() {
            for (index, word) in words.enumerated() {
                let token = normalize(word.text)
                guard !token.isEmpty else { continue }
                positions.append((line, index)); tokens.append(token)
            }
        }
        let heard = recognized.map { normalize($0.text) }
        let matches = alignTokens(tokens, heard)

        var output = lines
        if !keepExisting { output = lines.map { $0.map { TimedWord(text: $0.text, space: $0.space) } } }
        var matched = 0
        var lastStart = -Double.infinity
        for (token, match) in matches.enumerated() {
            guard let match else { continue }
            let position = positions[token]
            guard !output[position.line][position.word].isTimed else { continue }
            let word = recognized[match]
            let start = max(0, word.start + offset), end = max(start + 0.05, word.end + offset)
            // Drop matches that would run backwards in time: they are almost always repeated words matched to the wrong place.
            guard start >= lastStart else { continue }
            lastStart = start
            output[position.line][position.word].start = start
            output[position.line][position.word].end = end
            matched += 1
        }
        let before = output.joined().filter(\.isTimed).count
        output = interpolate(output)
        let after = output.joined().filter(\.isTimed).count
        return Alignment(lines: output, matched: matched, filled: after - before, total: lines.joined().count)
    }

    // MARK: Interpolation

    /// Rough count of sung syllables: vowel groups for spaced scripts, one per CJK character.
    static func syllables(_ text: String) -> Double {
        let lower = text.lowercased()
        if lower.unicodeScalars.contains(where: { (0x3040...0x9FFF).contains($0.value) }) {
            return Double(max(1, lower.filter(\.isLetter).count))
        }
        var groups = 0, inVowel = false
        for character in lower {
            let vowel = "aeiouyàáâãäåèéêëìíîïòóôõöùúûü".contains(character)
            if vowel, !inVowel { groups += 1 }
            inVowel = vowel
        }
        if lower.hasSuffix("e"), !lower.hasSuffix("le"), groups > 1 { groups -= 1 }
        return Double(max(1, groups))
    }

    /// Gives every timed word a clean start and end, then fills untimed words between timed neighbours by syllables.
    /// Words in lines with no timed word at all stay untimed when there is a long pause around them.
    static func interpolate(_ lines: [[TimedWord]]) -> [[TimedWord]] {
        var lines = lines
        // 1. Normalise anchors (fill a missing start or end the same way playback does).
        for index in lines.indices {
            let ranges = TimedWord.resolve(lines[index])
            for word in lines[index].indices {
                guard let range = ranges[word] else { continue }
                lines[index][word].start = range.lowerBound
                lines[index][word].end = max(range.upperBound, range.lowerBound + 0.05)
            }
        }
        // 2. Walk the song as one sequence and fill each run of untimed words.
        let flat = lines.indices.flatMap { line in lines[line].indices.map { (line: line, word: $0) } }
        var index = 0
        while index < flat.count {
            guard !lines[flat[index].line][flat[index].word].isTimed else { index += 1; continue }
            var end = index
            while end < flat.count, !lines[flat[end].line][flat[end].word].isTimed { end += 1 }
            let run = Array(flat[index..<end])
            let left = index > 0 ? flat[index - 1] : nil
            let right = end < flat.count ? flat[end] : nil
            fill(run, left: left, right: right, in: &lines)
            index = end
        }
        // 3. Remove overlaps and backwards steps left over from rough manual presses.
        var previous: (line: Int, word: Int)?
        for position in flat where lines[position.line][position.word].isTimed {
            defer { previous = position }
            guard let previous, let previousStart = lines[previous.line][previous.word].start,
                  let previousEnd = lines[previous.line][previous.word].end,
                  var start = lines[position.line][position.word].start, var end = lines[position.line][position.word].end else { continue }
            if start < previousStart + 0.03 { start = min(previousEnd, previousStart + 0.03) }
            if previousEnd > start { lines[previous.line][previous.word].end = max(previousStart + 0.03, start) }
            end = max(end, start + 0.03)
            lines[position.line][position.word].start = start
            lines[position.line][position.word].end = end
        }
        return lines
    }

    private static func fill(_ run: [(line: Int, word: Int)], left: (line: Int, word: Int)?, right: (line: Int, word: Int)?, in lines: inout [[TimedWord]]) {
        let texts = lines.map { $0.map(\.text) }   // word text never changes here
        let weight = { (position: (line: Int, word: Int)) in syllables(texts[position.line][position.word]) }
        let leftEnd = left.flatMap { lines[$0.line][$0.word].end }
        let rightStart = right.flatMap { lines[$0.line][$0.word].start }
        let natural = run.reduce(0) { $0 + weight($1) } * syllableDuration

        if let leftEnd, let rightStart, rightStart - leftEnd <= natural * 2.5 {
            var from = leftEnd
            let room = rightStart - leftEnd
            if room < Double(run.count) * 0.08, let left {
                // No room after the previous word: borrow time from it.
                let previousStart = lines[left.line][left.word].start ?? leftEnd
                from = max(previousStart + 0.08, rightStart - natural)
                lines[left.line][left.word].end = from
            }
            distribute(run, from: from, to: rightStart, weight: weight, in: &lines)
            return
        }
        // Long pause between anchors: attach words to the anchor in their own line and leave whole lines alone.
        if let left, let leftEnd {
            let attached = run.prefix { $0.line == left.line }
            let duration = attached.reduce(0) { $0 + weight($1) } * syllableDuration
            var limit = leftEnd + duration
            if let right, let rightStart, right.line == left.line { limit = min(limit, rightStart) }
            distribute(Array(attached), from: leftEnd, to: limit, weight: weight, in: &lines)
        }
        if let right, let rightStart {
            let attached = Array(run.reversed().prefix { $0.line == right.line && $0.line != left?.line }.reversed())
            let duration = attached.reduce(0) { $0 + weight($1) } * syllableDuration
            distribute(attached, from: max(0, rightStart - duration), to: rightStart, weight: weight, in: &lines)
        }
    }

    private static func distribute(_ run: [(line: Int, word: Int)], from: Double, to: Double, weight: ((line: Int, word: Int)) -> Double, in lines: inout [[TimedWord]]) {
        guard !run.isEmpty, to > from else { return }
        let total = run.reduce(0) { $0 + weight($1) }
        var cursor = from
        for position in run {
            let length = (to - from) * weight(position) / total
            lines[position.line][position.word].start = cursor
            lines[position.line][position.word].end = cursor + length
            cursor += length
        }
    }
}
