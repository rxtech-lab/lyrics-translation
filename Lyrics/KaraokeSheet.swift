import SwiftUI

/// Full-height karaoke workspace: plays the linked Apple Music song with word-by-word subtitles,
/// and navigates to song search and word timing.
struct KaraokeSheet: View {
    @Binding var song: Song
    /// Document title, used as the Apple Music search term.
    var title = ""
    @Environment(\.dismiss) private var dismiss
    @State private var playback = MusicPlayback.shared
    @State private var path: [Route] = []
    @AppStorage("karaokeTrack") private var track = KaraokeTrack.original
    @AppStorage("karaokeDisplay") private var display = LyricDisplay.both
    @State private var status: String?
    @State private var error: String?
    @State private var export: SubtitleFormat?
    @State private var detecting = false
    @FocusState private var focused: Bool

    enum Route: Hashable { case search, timing }

    var body: some View {
        NavigationStack(path: $path) {
            Group {
                if let music = song.appleMusic {
                    VStack(spacing: 0) {
                        SongHeader(music: music, progress: song.timedCount(track), onAutoDetect: { detecting = true }) { path.append(.timing) }
                        Divider()
                        KaraokeStage(song: song, track: track, display: display, playback: playback) { path.append(.timing) }
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                            // Clipping only affects drawing; moving lyric rows must not intercept
                            // clicks on the song header or playback controls outside the stage.
                            .contentShape(.rect)
                            .clipped()
                        Divider()
                        TransportBar(playback: playback, duration: music.duration ?? 0, report: report)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .focusable().focused($focused).focusEffectDisabled()
                    .onKeyPress(.space) { toggle(); return .handled }
                    .onAppear { focused = true }
                } else {
                    ContentUnavailableView {
                        Label("Sing along with Apple Music", systemImage: "music.mic")
                    } description: {
                        Text("Link the recording of this song, then hold Space as each word is sung to make word-by-word karaoke subtitles.")
                    } actions: {
                        Button("Choose Song") { path.append(.search) }.buttonStyle(.borderedProminent)
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .navigationTitle("Karaoke")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Done") { dismiss() } }
                ToolbarItemGroup(placement: .primaryAction) {
                    Picker("Subtitle", selection: $track) { ForEach(KaraokeTrack.allCases) { Text($0.rawValue).tag($0) } }
                        .pickerStyle(.segmented).help("Which text is timed as the karaoke subtitle")
                    Picker("Show", systemImage: "text.bubble", selection: $display) {
                        ForEach(LyricDisplay.allCases) { Text($0.title).tag($0) }
                    }
                    .pickerStyle(.menu).help("Which lyrics appear on the karaoke stage")
                    Button("Time Words", systemImage: "metronome") { path.append(.timing) }.disabled(song.appleMusic == nil)
                    Menu("More", systemImage: "ellipsis") {
                        Button(song.appleMusic == nil ? "Choose Song…" : "Change Song…", systemImage: "magnifyingglass") { path.append(.search) }
                        Divider()
                        Menu("Export Subtitles", systemImage: "square.and.arrow.up") {
                            ForEach(SubtitleFormat.allCases) { format in Button(format.title) { export = format } }
                        }.disabled(song.timedCount(track).timed == 0)
                    }
                }
            }
            .navigationDestination(for: Route.self) { route in
                switch route {
                case .search:
                    AppleMusicSearchView(playback: playback, current: song.appleMusic, suggestion: title) { music in
                        if song.appleMusic?.id != music.id { playback.pause() }
                        song.appleMusic = music
                        path.removeAll()
                        report("Linked “\(music.title)”")
                    }
                case .timing:
                    KaraokeTimingView(song: $song, track: $track, playback: playback, report: report)
                }
            }
        }
        .frame(minWidth: 880, idealWidth: 980, maxWidth: .infinity, minHeight: 680, idealHeight: 780, maxHeight: .infinity)
        .overlay(alignment: .bottom) { StatusOverlay(status: $status).padding(.bottom, 80) }
        .alert("Apple Music", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) { Button("OK") { error = nil } } message: { Text(error ?? "") }
        .fileExporter(isPresented: Binding(get: { export != nil }, set: { if !$0 { export = nil } }),
                      document: SubtitleFile(text: export?.render(song, track: track) ?? ""),
                      contentType: export?.type ?? .plainText,
                      defaultFilename: "\(song.appleMusic?.title ?? "Lyrics") (\(track.rawValue))") { result in
            switch result {
            case .success(let url): report("Exported \(url.lastPathComponent)")
            case .failure(let failure): error = failure.localizedDescription
            }
        }
        .sheet(isPresented: $detecting) {
            AutoTimingSheet(lines: song.lines.map { $0.words(track) }, trackName: track.rawValue,
                            sampleText: song.lines.prefix(20).map { $0.text(track) }.joined(separator: "\n"),
                            appleMusicDuration: song.appleMusic?.duration, playback: playback) { lines in
                song.checkpoint("Before detecting \(track.rawValue.lowercased()) timings")
                for index in song.lines.indices where lines.indices.contains(index) { song.lines[index].setWords(lines[index], track) }
                report("Detected timings applied")
            }
        }
        .task(id: song.appleMusic?.id) {
            guard let music = song.appleMusic else { return }
            do { try await playback.load(music) } catch { self.error = error.localizedDescription }
        }

    }

    func report(_ message: String) {
        if message.hasPrefix("!") { error = String(message.dropFirst()) } else { status = message }
    }

    func toggle() {
        Task { do { try await playback.toggle() } catch { self.error = error.localizedDescription } }
    }
}

// MARK: Header and stage

private struct SongHeader: View {
    let music: AppleMusicTrack
    let progress: (timed: Int, total: Int)
    var onAutoDetect: () -> Void
    var onEditTiming: () -> Void

    var body: some View {
        HStack(spacing: 14) {
            Artwork(url: music.artworkURL, size: 56)
            VStack(alignment: .leading, spacing: 3) {
                Text(music.title).font(.headline).lineLimit(1)
                Text([music.artist, music.album].compactMap { $0 }.joined(separator: " · ")).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 4) {
                Text("\(progress.timed) of \(progress.total) words timed").font(.caption).foregroundStyle(.secondary)
                ProgressView(value: Double(progress.timed), total: Double(max(progress.total, 1))).frame(width: 160)
            }
            Button(action: onAutoDetect) {
                Label("Auto-Detect", systemImage: "wand.and.stars")
            }
            .buttonStyle(.bordered)
            .fixedSize()
            .help("Detect word timings automatically from your copy of the recording")
            Button(action: onEditTiming) {
                Label("Edit Timing", systemImage: "pencil")
            }
            .buttonStyle(.bordered)
            .fixedSize()
            .help("Edit word timings for the selected subtitle track")
            if let url = music.url { Link(destination: url) { Image(systemName: "arrow.up.forward.app") }.help("Open in Music") }
        }
        .padding(.horizontal, 20).padding(.vertical, 12)
    }
}

/// Karaoke preview in the style of Apple Music lyrics: the sung line sits in the upper third, the lines
/// scroll up with a cascading spring, words fill with a soft edge, and duet partners sit on opposite sides.
/// Lines whose timings overlap are grouped and scroll into focus together.
private struct KaraokeStage: View {
    let song: Song
    let track: KaraokeTrack
    let display: LyricDisplay
    let playback: MusicPlayback
    var onTime: () -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var following = true
    /// Line the stage scrolls to: the topmost line in focus.
    @State private var target = 0
    @State private var scroll = ScrollPosition(edge: .top)
    /// Top of each line within the scroll content, used to place the focus line exactly.
    @State private var rowTops: [Int: CGFloat] = [:]
    nonisolated static let space = "karaoke-stage"
    /// Where the focus line sits, as a fraction of the stage height from the top.
    static let focusPoint: CGFloat = 0.3
    @State private var playbackError: String?

    static let spacing: CGFloat = 36
    /// Bring the next line into focus half a second before its first word.
    static let lead = 0.5

    var body: some View {
        let lines = song.lines.compactMap { line in line.span(track).map { (line: line, span: $0) } }
        if lines.isEmpty {
            ContentUnavailableView {
                Label("No word timings yet", systemImage: "metronome")
            } description: {
                Text("Time the \(track.rawValue.lowercased()) lyrics by holding Space while each word is sung.")
            } actions: {
                Button("Time Words", action: onTime).buttonStyle(.borderedProminent)
            }
        } else {
            let sides = speakerSides()
            let groups = Self.groups(lines.map(\.span))
            // Lines in the order they are laid out on screen.
            let order = groups.flatMap(\.lines)
            // Name the singer when it changes from the line shown just above (on screen, not in lyric order),
            // and always within lines sung together so each part is labelled.
            // Lines that join a line already being sung are drawn smaller, like backing vocals.
            let joined = Self.joined(lines.map(\.span))
            let showTag: Set<Int> = {
                var result = Set<Int>()
                var previous: String??
                for group in groups {
                    for index in group.lines {
                        let tag = lines[index].line.tag
                        if group.lines.count > 1 || previous == nil || previous! != tag { result.insert(index) }
                        previous = .some(tag)
                    }
                }
                return result
            }()
            // The list itself stays still between frames so clicks on any line register reliably; only each
            // line's words redraw per frame, and a lightweight clock below decides where to scroll.
            GeometryReader { geometry in
                let height = geometry.size.height
                Group {
                    ScrollView(.vertical) {
                        VStack(alignment: .leading, spacing: Self.spacing) {
                            ForEach(groups.indices, id: \.self) { group in
                                VStack(alignment: .leading, spacing: Self.groupSpacing) {
                                    ForEach(groups[group].lines, id: \.self) { index in
                                        let item = lines[index]
                                        Button {
                                            following = true
                                            playback.seek(to: item.span.lowerBound)
                                            target = index
                                            scrollTo(index, height: height)
                                            Task {
                                                do { try await playback.play() }
                                                catch { playbackError = error.localizedDescription }
                                            }
                                        } label: {
                                            TimelineView(.animation) { _ in
                                                let time = playback.time
                                                line(item.line, span: item.span, time: time, state: Self.state(item.span, time: time),
                                                     side: sides[item.line.speaker ?? ""] ?? .leading, showTag: showTag.contains(index),
                                                     joined: joined.contains(index))
                                            }
                                            .frame(maxWidth: .infinity, alignment: .leading)
                                            .contentShape(.rect)
                                        }
                                        .buttonStyle(.plain)
                                        .help("Play from this line")
                                        .onGeometryChange(for: CGFloat.self) { $0.frame(in: .named(Self.space)).minY } action: { rowTops[index] = $0 }
                                    }
                                }
                            }
                        }
                        .padding(.horizontal, 56)
                        // Real padding rather than content margins: on macOS, lines scrolled into a content
                        // margin don't receive clicks.
                        .padding(.top, height * Self.focusPoint)
                        .padding(.bottom, height * 0.65)
                        .coordinateSpace(.named(Self.space))
                    }
                    .scrollPosition($scroll)
                    .scrollIndicators(.hidden)
                    .onScrollPhaseChange { _, phase in
                        if phase == .tracking || phase == .interacting { following = false }
                    }
                    .background {
                        // Scroll clock: recomputes the focus line a few dozen times a second without
                        // rebuilding the list.
                        TimelineView(.animation(minimumInterval: 1 / 30)) { _ in
                            let focus = Self.focusLine(lines.map(\.span), order: order, time: playback.time)
                            Color.clear.onChange(of: focus, initial: true) { _, new in target = new }
                        }
                    }
                    .onAppear { DispatchQueue.main.async { scrollTo(target, height: height, animated: false) } }
                    .onChange(of: target) { _, new in
                        if following { scrollTo(new, height: height) }
                    }
                    .overlay(alignment: .bottomTrailing) {
                        if !following {
                            Button("Follow Playback", systemImage: "location.fill") {
                                following = true
                                scrollTo(target, height: height)
                            }
                            .buttonStyle(.borderedProminent)
                            .padding(20)
                        }
                    }
                }
            }
            .alert("Playback Failed", isPresented: Binding(get: { playbackError != nil }, set: { if !$0 { playbackError = nil } })) {
                Button("OK") { playbackError = nil }
            } message: { Text(playbackError ?? "") }
        }
    }

    enum LineState { case past, current, upcoming }

    /// Preview the line early, but keep word highlighting on the actual playback time.
    /// Overlapping lines remain in focus until their own last word ends.
    static func state(_ span: ClosedRange<Double>, time: Double) -> LineState {
        if span.lowerBound <= time + lead && time < span.upperBound { return .current }
        return span.upperBound <= time ? .past : .upcoming
    }

    /// The topmost line in focus: lines sung at the same time stay in view together below it, and the view
    /// advances line by line as each one actually finishes, even when overlapping lines chain into one long
    /// group. Between lines, stay on the line that started last.
    static func focusLine(_ spans: [ClosedRange<Double>], order: [Int], time: Double) -> Int {
        order.first { state(spans[$0], time: time) == .current }
            ?? order.last { spans[$0].lowerBound <= time + lead }
            ?? order.first ?? 0
    }

    /// Scrolls so the line's top sits at the focus point of the stage.
    func scrollTo(_ index: Int, height: CGFloat, animated: Bool = true) {
        guard let top = rowTops[index] else { return }
        let y = max(0, top - height * Self.focusPoint)
        if animated { withAnimation(scrollAnimation) { scroll.scrollTo(y: y) } } else { scroll.scrollTo(y: y) }
    }

    /// Gap between lines sung at the same time, tighter than between groups.
    static let groupSpacing: CGFloat = 14

    /// Groups lines sung at the same time (e.g. two singers at once), wherever they sit in the lyrics:
    /// lines are walked in time order and a line joins the group when it starts before the group's latest end.
    /// Groups are in time order, and so are the lines inside a group.
    static func groups(_ spans: [ClosedRange<Double>]) -> [(lines: [Int], span: ClosedRange<Double>)] {
        var groups: [(lines: [Int], span: ClosedRange<Double>)] = []
        let byTime = spans.indices.sorted { (spans[$0].lowerBound, $0) < (spans[$1].lowerBound, $1) }
        for index in byTime {
            let span = spans[index]
            if let last = groups.last, span.lowerBound < last.span.upperBound {
                groups[groups.count - 1] = (last.lines + [index], last.span.lowerBound...max(last.span.upperBound, span.upperBound))
            } else {
                groups.append(([index], span))
            }
        }
        // Within a group, lines appear in the order they start, so a joining line sits below the one it joins.
        return groups
    }

    /// Lines sung together with one that started earlier: they overlap it by at least a second, or by half
    /// their own length if shorter. Brief overlaps where one line runs into the next don't count.
    static func joined(_ spans: [ClosedRange<Double>]) -> Set<Int> {
        Set(spans.indices.filter { index in
            let span = spans[index]
            let needed = min(1, (span.upperBound - span.lowerBound) * 0.5)
            return spans.indices.contains { other in
                guard other != index, (spans[other].lowerBound, other) < (span.lowerBound, index) else { return false }
                let overlap = min(span.upperBound, spans[other].upperBound) - max(span.lowerBound, spans[other].lowerBound)
                return overlap >= needed
            }
        })
    }

    var scrollAnimation: Animation {
        if reduceMotion { return .easeInOut(duration: 0.2) }
        // Start immediately and settle without bounce within the next line's lead-in.
        return .smooth(duration: 0.5, extraBounce: 0)
    }

    /// Alternates sides by order of first appearance: the first singer on the left, the next on the right.
    func speakerSides() -> [String: HorizontalAlignment] {
        var sides: [String: HorizontalAlignment] = [:]
        for speaker in song.lines.compactMap(\.speaker) where sides[speaker] == nil {
            sides[speaker] = sides.count.isMultiple(of: 2) ? .leading : .trailing
        }
        return sides
    }

    func line(_ line: LyricLine, span: ClosedRange<Double>, time: Double, state: LineState, side: HorizontalAlignment, showTag: Bool, joined: Bool = false) -> some View {
        // The large, word-highlighted text: the timed track, or the single language chosen to show.
        let main = display.single ?? track
        let words = line.words(main)
        let ranges = ranges(words, fallback: span)
        let companion = display.single == nil ? line.text(track.other) : ""
        let alignment: Alignment = side == .trailing ? .trailing : .leading
        let textAlignment: TextAlignment = side == .trailing ? .trailing : .leading
        return VStack(alignment: side, spacing: 10) {
            if showTag, let tag = line.tag {
                Text(tag).font(.callout.weight(.semibold)).foregroundStyle(.secondary)
            }
            FlowLayout(alignment: side, lineSpacing: 6) {
                ForEach(Array(words.enumerated()), id: \.offset) { index, word in
                    KaraokeWord(text: word.text + (word.space ? " " : ""), progress: progress(ranges[index], time: time),
                                font: joined ? KaraokeWord.joinedFont : KaraokeWord.lyricFont)
                }
            }
            if !companion.isEmpty {
                Text(companion).font(joined ? .title3.weight(.semibold) : .title2.weight(.semibold)).foregroundStyle(.secondary).multilineTextAlignment(textAlignment)
            }
        }
        .frame(maxWidth: .infinity, alignment: alignment)
        // Sung lines dim back to the same grey as unsung text; only the current line is bright and sharp.
        .opacity(state == .past ? 0.3 : 1)
        .blur(radius: state == .current || reduceMotion ? 0 : 1.2)
        .animation(.easeInOut(duration: 0.5), value: state)
    }

    /// Word ranges from the text's own timings; untimed text sweeps evenly across the line's span.
    func ranges(_ words: [TimedWord], fallback span: ClosedRange<Double>) -> [ClosedRange<Double>?] {
        let timed = TimedWord.resolve(words)
        guard !words.isEmpty, timed.allSatisfy({ $0 == nil }) else { return timed }
        let step = (span.upperBound - span.lowerBound) / Double(words.count)
        return words.indices.map { index in
            let start = span.lowerBound + step * Double(index)
            return start...(start + step)
        }
    }

    func progress(_ range: ClosedRange<Double>?, time: Double) -> Double {
        guard let range else { return 0 }
        guard range.upperBound > range.lowerBound else { return time >= range.lowerBound ? 1 : 0 }
        return min(1, max(0, (time - range.lowerBound) / (range.upperBound - range.lowerBound)))
    }
}

/// A word that fills from left to right as it is sung, with a feathered edge and a slight lift.
private struct KaraokeWord: View {
    static let lyricFont = Font.system(size: 40, weight: .bold)
    /// Smaller size for a line that joins in while another is being sung.
    static let joinedFont = Font.system(size: 28, weight: .bold)
    /// Width of the soft fill edge, as a fraction of the word.
    static let feather = 0.35

    let text: String
    let progress: Double
    var font: Font = KaraokeWord.lyricFont

    var body: some View {
        let eased = progress * progress * (3 - 2 * progress)
        // Linear fill keeps the sweep moving at an even speed across word boundaries.
        let edge = progress * (1 + Self.feather)
        Text(text).font(font).foregroundStyle(.primary.opacity(0.3))
            .overlay {
                Text(text).font(font).foregroundStyle(.primary)
                    .mask {
                        LinearGradient(stops: [.init(color: .black, location: min(1, max(0, edge - Self.feather))),
                                               .init(color: .clear, location: min(1, max(0, edge)))],
                                       startPoint: .leading, endPoint: .trailing)
                    }
                    .opacity(progress > 0 ? 1 : 0)
            }
            .offset(y: -2 * eased)
    }
}

// MARK: Transport

/// Play, pause, seek and speed controls for the Apple Music player.
struct TransportBar: View {
    let playback: MusicPlayback
    let duration: Double
    var report: (String) -> Void
    @State private var scrub: Double?

    var body: some View {
        TimelineView(.periodic(from: .now, by: 0.1)) { _ in
            let time = scrub ?? playback.time
            HStack(spacing: 14) {
                Button("Back 5 Seconds", systemImage: "gobackward.5") { playback.seek(to: playback.time - 5) }.labelStyle(.iconOnly)
                Button(playback.isPlaying ? "Pause" : "Play", systemImage: playback.isPlaying ? "pause.fill" : "play.fill") {
                    Task { do { try await playback.toggle() } catch { report("!" + error.localizedDescription) } }
                }
                .labelStyle(.iconOnly).font(.title2).frame(width: 28).disabled(playback.loading)
                Button("Forward 5 Seconds", systemImage: "goforward.5") { playback.seek(to: playback.time + 5) }.labelStyle(.iconOnly)
                Text(KaraokeClock.display(time)).monospacedDigit().foregroundStyle(.secondary).frame(width: 56, alignment: .trailing)
                Slider(value: Binding(get: { min(time, max(duration, 1)) }, set: { scrub = $0 }), in: 0...max(duration, 1)) { editing in
                    if !editing, let scrub { playback.seek(to: scrub); self.scrub = nil }
                }
                Text(KaraokeClock.display(duration)).monospacedDigit().foregroundStyle(.secondary).frame(width: 56, alignment: .leading)
                Picker("Speed", selection: Binding(get: { playback.rate }, set: { playback.rate = $0 })) {
                    Text("0.5×").tag(Float(0.5)); Text("0.75×").tag(Float(0.75)); Text("1×").tag(Float(1))
                }
                .pickerStyle(.menu).fixedSize().help("Slow the song down to time words more precisely")
                if playback.loading { ProgressView().controlSize(.small) }
            }
            .buttonStyle(.borderless)
            .padding(.horizontal, 20).padding(.vertical, 12)
        }
    }
}

struct Artwork: View {
    let url: URL?
    let size: CGFloat

    var body: some View {
        AsyncImage(url: url) { image in image.resizable().scaledToFill() } placeholder: {
            Image(systemName: "music.note").foregroundStyle(.secondary).frame(maxWidth: .infinity, maxHeight: .infinity).background(.quaternary)
        }
        .frame(width: size, height: size).clipShape(.rect(cornerRadius: size / 8))
    }
}

/// Capsule that briefly shows the result of an action.
struct StatusOverlay: View {
    @Binding var status: String?

    var body: some View {
        Group {
            if let status {
                Label(status, systemImage: "checkmark.circle.fill")
                    .padding(.horizontal, 16).padding(.vertical, 10)
                    .background(.regularMaterial, in: Capsule())
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(.spring(duration: 0.3), value: status)
        .task(id: status) {
            guard status != nil else { return }
            try? await Task.sleep(for: .seconds(2.5))
            if !Task.isCancelled { status = nil }
        }
    }
}

// MARK: Search

/// Searches the Apple Music catalog for the recording to link.
private struct AppleMusicSearchView: View {
    let playback: MusicPlayback
    let current: AppleMusicTrack?
    let suggestion: String
    var onPick: (AppleMusicTrack) -> Void
    @State private var query = ""
    @State private var results: [AppleMusicTrack] = []
    @State private var searching = false
    @State private var error: String?

    var body: some View {
        Group {
            if let error {
                ContentUnavailableView("Can’t search Apple Music", systemImage: "exclamationmark.triangle", description: Text(error))
            } else if results.isEmpty {
                if searching { ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity) }
                else if query.isEmpty {
                    ContentUnavailableView("Search Apple Music", systemImage: "magnifyingglass", description: Text("Find the recording to sing along with by title, artist or a line of the lyrics. Playing full songs needs an Apple Music subscription."))
                } else {
                    ContentUnavailableView.search(text: query)
                }
            } else {
                List(results) { music in
                    Button { onPick(music) } label: {
                        HStack(spacing: 12) {
                            Artwork(url: music.artworkURL, size: 44)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(music.title).lineLimit(1)
                                Text([music.artist, music.album].compactMap { $0 }.joined(separator: " · ")).font(.callout).foregroundStyle(.secondary).lineLimit(1)
                            }
                            Spacer()
                            if let duration = music.duration { Text(Duration.seconds(duration).formatted(.time(pattern: .minuteSecond))).monospacedDigit().foregroundStyle(.secondary) }
                            if music.id == current?.id { Image(systemName: "checkmark").foregroundStyle(.tint) }
                        }
                        .contentShape(.rect)
                    }
                    .buttonStyle(.plain).padding(.vertical, 4)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .navigationTitle("Choose Song")
        .searchable(text: $query, placement: .toolbar, prompt: "Song, artist or lyrics")
        .onAppear { if query.isEmpty { query = suggestion } }
        .task(id: query) {
            let term = query.trimmingCharacters(in: .whitespaces)
            guard !term.isEmpty else { results = []; return }
            try? await Task.sleep(for: .milliseconds(350))
            guard !Task.isCancelled else { return }
            searching = true
            defer { searching = false }
            do { results = try await playback.search(term); error = nil }
            catch is CancellationError {}
            catch { if !Task.isCancelled { self.error = error.localizedDescription } }
        }
    }
}

// MARK: Timing

/// Word timing: hold Space while each word is sung. Release marks its end and moves to the next word.
private struct KaraokeTimingView: View {
    @Binding var song: Song
    @Binding var track: KaraokeTrack
    let playback: MusicPlayback
    var report: (String) -> Void
    @State private var cursor = Cursor(line: 0, word: 0)
    @State private var holding: Cursor?
    @State private var timingHistory: [Cursor] = []
    @State private var confirmClear = false
    /// Working copy of every line's words for the track. Key presses read and write this synchronously,
    /// so a fast press–release never reads a stale document value and drops the other half of the timing.
    @State private var draft: [[TimedWord]] = []
    /// The track `draft` was loaded for, so pending saves land on the right text after switching tracks.
    @State private var draftTrack = KaraokeTrack.original
    /// Lines edited in `draft` but not yet written to the document. Writing the document re-renders the
    /// whole studio window, so presses are batched and saved once the user pauses.
    @State private var dirty: Set<Int> = []
    @State private var flushTask: Task<Void, Never>?
    @State private var detecting = false
    @State private var confirmFill = false
    @AppStorage("karaoke.closeGapsWhileRecording") private var closeGapsWhileRecording = false
    /// Line open in the precise editor.
    @State private var editingLine: Int?
    @FocusState private var focused: Bool

    struct Cursor: Hashable { var line: Int; var word: Int }

    var offset: Double { song.timingOffset ?? 0 }
    var finished: Bool { cursor.line >= song.lines.count }

    var body: some View {
        VStack(spacing: 0) {
            if song.lines.allSatisfy({ $0.text(track).isEmpty }) {
                ContentUnavailableView("No \(track.rawValue.lowercased()) lyrics", systemImage: "text.badge.xmark", description: Text(track == .translation ? "Translate the lyrics first, or time the original instead." : "Add the original lyrics first."))
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 8) {
                            ForEach(song.lines.indices, id: \.self) { index in row(index).id(index) }
                        }
                        .padding(20)
                    }
                    .onChange(of: cursor.line) { _, line in withAnimation { proxy.scrollTo(line, anchor: .center) } }
                    .onAppear { proxy.scrollTo(cursor.line, anchor: .center) }
                }
            }
            Divider()
            Toggle("Close gaps while recording", isOn: $closeGapsWhileRecording)
                .help("Extend the preceding word to each new word’s start within the same line")
                .padding(.horizontal, 20).padding(.vertical, 8)
            HStack(spacing: 18) {
                hint("space", "Hold while a word is sung")
                hint("return", "Play or pause")
                Button(action: undo) { hint("delete.left", "Undo word") }
                    .buttonStyle(.plain)
                    .disabled(undoTarget == nil)
                hint("arrow.up", "Redo line")
                Button { finishHold(); editingLine = min(cursor.line, song.lines.count - 1) } label: { hint("e.square", "Precise edit") }
                    .buttonStyle(.plain)
                    .disabled(song.lines.isEmpty)
                    .help("Edit the current line’s timing precisely (E)")
                Button(action: advanceLine) { hint("arrow.right", "Next line") }
                    .buttonStyle(.plain)
                    .disabled(nextLine == nil)
                    .help("Move to the next lyric line (Right Arrow)")
                Spacer()
                if finished { Label("All words timed", systemImage: "checkmark.seal.fill").foregroundStyle(.green) }
                Menu {
                    Button("Detect from Recording…", systemImage: "waveform.badge.magnifyingglass") { detecting = true }
                    Button("Fill Gaps Between Timed Words…", systemImage: "arrow.left.and.right.text.vertical") { confirmFill = true }
                        .disabled(!hasTimedWords)
                } label: {
                    Label("Auto-Time", systemImage: "wand.and.stars")
                } primaryAction: {
                    finishHold(); detecting = true
                }
                .menuStyle(.button).buttonStyle(.bordered).fixedSize()
                .help("Click to detect timings from a recording; open the arrow to fill skipped words")
            }
            .font(.callout).foregroundStyle(.secondary).padding(.horizontal, 20).padding(.vertical, 10)
            Divider()
            TransportBar(playback: playback, duration: song.appleMusic?.duration ?? 0, report: report)
        }
        .focusable().focused($focused).focusEffectDisabled()
        .onKeyPress(.space, phases: [.down, .repeat, .up]) { press in
            switch press.phase {
            case .down: pressDown()
            case .up: release()
            default: break
            }
            return .handled
        }
        .onKeyPress(.return) { Task { do { try await playback.toggle() } catch { report("!" + error.localizedDescription) } }; return .handled }
        .onKeyPress(.delete) { undo(); return .handled }
        .onKeyPress(characters: CharacterSet(charactersIn: "\u{7f}\u{8}")) { _ in undo(); return .handled }
        .onKeyPress(.upArrow) { redoLine(); return .handled }
        .onKeyPress(.rightArrow) { advanceLine(); return .handled }
        .onKeyPress("e") {
            guard !song.lines.isEmpty else { return .ignored }
            finishHold()
            editingLine = min(cursor.line, song.lines.count - 1); return .handled
        }
        .navigationDestination(item: $editingLine) { line in
            WordTimingEditor(lineCount: song.lines.count,
                             text: { (song.lines[$0].text(track), song.lines[$0].tag) },
                             load: { words($0) },
                             save: { commit($0, $1, immediately: true) },
                             playback: playback,
                             duration: song.appleMusic?.duration ?? 0,
                             report: report,
                             line: line)
        }
        .onChange(of: editingLine) { _, line in if line == nil { reloadDraft(); focused = true } }
        .sheet(isPresented: $detecting) {
            AutoTimingSheet(lines: song.lines.indices.map(words), trackName: track.rawValue,
                            sampleText: song.lines.prefix(20).map { $0.text(track) }.joined(separator: "\n"),
                            appleMusicDuration: song.appleMusic?.duration, playback: playback) { lines in
                flush()
                song.checkpoint("Before detecting \(track.rawValue.lowercased()) timings")
                apply(lines)
                report("Detected timings applied")
            }
        }
        .onAppear { reloadDraft(); focused = true; cursor = firstUntimed() }
        .onDisappear { flush() }
        .onChange(of: track) { flush(); reloadDraft(); holding = nil; timingHistory = []; cursor = firstUntimed() }
        .navigationTitle("Time Words")
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                Picker("Subtitle", selection: $track) { ForEach(KaraokeTrack.allCases) { Text($0.rawValue).tag($0) } }.pickerStyle(.segmented)
                Picker("Reaction offset", selection: Binding(get: { song.timingOffset ?? 0 }, set: { song.timingOffset = $0 == 0 ? nil : $0 })) {
                    ForEach([0, -0.05, -0.1, -0.15, -0.2, -0.3], id: \.self) { value in Text(value == 0 ? "No offset" : "\(Int(value * 1000)) ms").tag(value) }
                }
                .pickerStyle(.menu).fixedSize().help("Shift each press earlier to make up for reaction time")
                Button("Clear Timings", systemImage: "eraser", role: .destructive) { confirmClear = true }.disabled(!hasTimedWords)
            }
        }
        .confirmationDialog("Clear all \(track.rawValue.lowercased()) word timings?", isPresented: $confirmClear) {
            Button("Clear Timings", role: .destructive) {
                flush()
                song.checkpoint("Before clearing \(track.rawValue.lowercased()) timings")
                for index in song.lines.indices { song.lines[index].setWords(TimedWord.split(song.lines[index].text(track)), track) }
                reloadDraft()
                holding = nil; timingHistory = []; cursor = firstUntimed(); report("Timings cleared")
            }
        } message: { Text("A copy is saved in Versions so you can restore it.") }
        .confirmationDialog("Fill untimed words between the words you’ve timed?", isPresented: $confirmFill) {
            Button("Fill Gaps") {
                flush()
                song.checkpoint("Before filling \(track.rawValue.lowercased()) timing gaps")
                let before = song.timedCount(track).timed
                apply(AutoTiming.interpolate(song.lines.indices.map(words)))
                report("Filled \(song.timedCount(track).timed - before) words")
            }
        } message: { Text("Each skipped word gets a share of the time between its timed neighbours, by syllables. Lines inside long pauses stay untimed. A copy is saved in Versions.") }
    }

    /// Replaces every line's words for the track, e.g. after automatic timing.
    func apply(_ lines: [[TimedWord]]) {
        flush()
        for index in song.lines.indices where lines.indices.contains(index) { song.lines[index].setWords(lines[index], track) }
        reloadDraft()
        holding = nil; timingHistory = []; cursor = firstUntimed()
    }

    func hint(_ symbol: String, _ text: String) -> some View {
        HStack(spacing: 5) {
            Image(systemName: symbol).font(.caption.weight(.semibold)).padding(.horizontal, 6).padding(.vertical, 3).background(.quaternary, in: .rect(cornerRadius: 4))
            Text(text)
        }
    }

    func row(_ index: Int) -> some View {
        let line = song.lines[index]
        return TimingRow(number: index + 1, tag: line.tag, words: words(index), companion: line.text(track.other),
                         cursorWord: cursor.line == index ? cursor.word : nil,
                         holdingWord: holding?.line == index ? holding?.word : nil,
                         loading: playback.loading,
                         onJump: { jump(to: Cursor(line: index, word: $0)) },
                         onPlay: { words in Task { do { try await playback.playLine(words) } catch { report("!" + error.localizedDescription) } } },
                         onEdit: { finishHold(); editingLine = index })
            .equatable()
    }

    // MARK: Actions

    var now: Double { max(0, playback.time + offset) }

    func words(_ line: Int) -> [TimedWord] {
        if draft.indices.contains(line) { return draft[line] }
        return song.lines.indices.contains(line) ? song.lines[line].words(track) : []
    }

    /// Reloads the working copy from the document, discarding unsaved edits (call `flush()` first to keep them).
    func reloadDraft() {
        flushTask?.cancel(); flushTask = nil
        dirty = []
        draftTrack = track
        draft = song.lines.map { $0.words(track) }
    }

    /// Whether any word of the track is timed, read from the working copy so it never lags behind presses.
    var hasTimedWords: Bool { draft.contains { $0.contains(where: \.isTimed) } }

    /// Saves one line's words to the working copy, and to the document after a short pause in editing.
    func commit(_ line: Int, _ words: [TimedWord], immediately: Bool = false) {
        if draft.count != song.lines.count { flush(); reloadDraft() }
        guard draft.indices.contains(line) else { return }
        draft[line] = words
        dirty.insert(line)
        if immediately { flush() } else { scheduleFlush() }
    }

    func scheduleFlush() {
        flushTask?.cancel()
        flushTask = Task { @MainActor in
            try? await Task.sleep(for: .seconds(1.2))
            guard !Task.isCancelled else { return }
            // Never interrupt a held word; try again once it is released.
            if holding != nil { scheduleFlush() } else { flush() }
        }
    }

    /// Writes every pending line to the document in a single change.
    func flush() {
        flushTask?.cancel(); flushTask = nil
        guard !dirty.isEmpty else { return }
        var lines = song.lines
        for index in dirty where lines.indices.contains(index) && draft.indices.contains(index) {
            lines[index].setWords(draft[index], draftTrack)
        }
        dirty = []
        song.lines = lines
    }

    func update(_ position: Cursor, _ change: (inout TimedWord) -> Void) {
        guard song.lines.indices.contains(position.line) else { return }
        var words = words(position.line)
        guard words.indices.contains(position.word) else { return }
        change(&words[position.word])
        commit(position.line, words)
    }

    func pressDown() {
        // A key-up can be missed (focus change, very fast taps): close the held word instead of ignoring the press.
        if holding != nil { release() }
        guard !finished, words(cursor.line).indices.contains(cursor.word) else { return }
        guard playback.isPlaying else {
            Task { do { try await playback.play() } catch { report("!" + error.localizedDescription) } }
            return
        }
        let time = now
        timingHistory.removeAll { $0 == cursor }
        timingHistory.append(cursor)
        update(cursor) { $0.start = time; $0.end = nil }
        if closeGapsWhileRecording, cursor.word > 0 {
            let previous = Cursor(line: cursor.line, word: cursor.word - 1)
            update(previous) { word in
                if let start = word.start, let end = word.end, start <= end, end < time {
                    word.end = time
                }
            }
        }
        holding = cursor
    }

    func release() {
        guard let held = holding else { return }
        let time = now
        update(held) { $0.end = max($0.start ?? time, time) }
        holding = nil
        // Keep the completed line selected until the user explicitly advances.
        cursor = Cursor(line: held.line, word: held.word + 1)
        if cursor.word == words(held.line).count {
            if nextLine == nil { cursor = Cursor(line: song.lines.count, word: 0) }
        }
        if finished { playback.pause(); report("All \(track.rawValue.lowercased()) words timed") }
    }

    /// Closes a word that is still held, so buttons and shortcuts work mid-press.
    func finishHold() { if holding != nil { release() } }

    var nextLine: Int? {
        guard !finished else { return nil }
        return song.lines.indices.first { $0 > cursor.line && !words($0).isEmpty }
    }

    func advanceLine() {
        finishHold()
        guard let line = nextLine else { return }
        cursor = Cursor(line: line, word: 0)
        focused = true
    }

    func previous(before position: Cursor) -> Cursor? {
        if position.word > 0, position.line < song.lines.count { return Cursor(line: position.line, word: position.word - 1) }
        var line = position.line - 1
        while line >= 0 { let count = words(line).count; if count > 0 { return Cursor(line: line, word: count - 1) }; line -= 1 }
        return nil
    }

    func firstUntimed() -> Cursor {
        for line in song.lines.indices {
            if let word = words(line).firstIndex(where: { !$0.isTimed }) { return Cursor(line: line, word: word) }
        }
        return Cursor(line: song.lines.count, word: 0)
    }

    var undoTarget: Cursor? {
        func isTimed(_ position: Cursor) -> Bool {
            guard song.lines.indices.contains(position.line) else { return false }
            let words = words(position.line)
            return words.indices.contains(position.word) && words[position.word].isTimed
        }
        if let recent = timingHistory.last(where: isTimed) { return recent }
        var position = previous(before: cursor)
        while let candidate = position {
            if isTimed(candidate) { return candidate }
            position = previous(before: candidate)
        }
        // Reopened documents may have gaps before their recorded words.
        return song.lines.indices.reversed().lazy.compactMap { line -> Cursor? in
            guard let word = words(line).lastIndex(where: \.isTimed) else { return nil }
            return Cursor(line: line, word: word)
        }.first
    }

    /// Clears the last timed word and rewinds a little before it so it can be timed again.
    func undo() {
        finishHold()
        guard let target = undoTarget else { return }
        timingHistory.removeAll { $0 == target }
        let word = words(target.line)[target.word]
        let start = word.start ?? word.end
        update(target) { $0.start = nil; $0.end = nil }
        cursor = target
        if let start { playback.seek(to: start - offset - 2) }
        focused = true
        report("Word timing cleared")
    }

    /// Clears the current line (or the previous one if no word of the current line is timed yet) and rewinds to just before it.
    func redoLine() {
        finishHold()
        var line = min(cursor.line, song.lines.count - 1)
        if cursor.word == 0, let previous = previous(before: cursor) { line = previous.line }
        guard line >= 0 else { return }
        let start = TimedWord.resolve(words(line)).compactMap { $0?.lowerBound }.min()
        commit(line, TimedWord.split(song.lines[line].text(track)))
        cursor = Cursor(line: line, word: 0)
        if let start { playback.seek(to: start - offset - 2) }
        report("Line \(line + 1) cleared")
    }

    func jump(to position: Cursor) {
        finishHold()
        cursor = position
        let word = words(position.line)[position.word]
        if let start = word.start ?? word.end { playback.seek(to: start - offset - 2) }
        focused = true
    }
}

/// One lyric line in the timing list. Equatable on its data so a key press only redraws the rows it changes.
private struct TimingRow: View, @MainActor Equatable {
    let number: Int
    let tag: String?
    let words: [TimedWord]
    let companion: String
    /// Index of the word under the cursor, when the cursor is on this line.
    let cursorWord: Int?
    /// Index of the word being held, when it is on this line.
    let holdingWord: Int?
    let loading: Bool
    var onJump: (Int) -> Void
    var onPlay: ([TimedWord]) -> Void
    var onEdit: () -> Void

    static func == (a: Self, b: Self) -> Bool {
        a.number == b.number && a.tag == b.tag && a.words == b.words && a.companion == b.companion
            && a.cursorWord == b.cursorWord && a.holdingWord == b.holdingWord && a.loading == b.loading
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text("\(number)").monospacedDigit().foregroundStyle(.tertiary).frame(width: 28, alignment: .trailing)
            VStack(alignment: .leading, spacing: 6) {
                if let tag { Text(tag).font(.caption.weight(.semibold)).foregroundStyle(.tint) }
                FlowLayout(spacing: 4, lineSpacing: 4) {
                    ForEach(Array(words.enumerated()), id: \.offset) { position, word in chip(word, at: position) }
                }
                if !companion.isEmpty { Text(companion).font(.callout).foregroundStyle(.secondary) }
            }
            Spacer(minLength: 0)
            if let start = TimedWord.resolve(words).compactMap({ $0?.lowerBound }).min() {
                Text(KaraokeClock.display(start)).font(.caption).monospacedDigit().foregroundStyle(.secondary)
            }
            if words.contains(where: \.isTimed) {
                Button("Play Line", systemImage: "play.circle.fill") { onPlay(words) }
                    .labelStyle(.iconOnly).buttonStyle(.borderless)
                    .disabled(loading)
                    .help("Play this line’s timed words")
            }
            Button("Edit Precisely", systemImage: "slider.horizontal.below.rectangle", action: onEdit)
                .labelStyle(.iconOnly).buttonStyle(.borderless).disabled(words.isEmpty)
                .help("Edit this line’s word timing precisely")
        }
        .padding(10)
        .background(cursorWord != nil ? AnyShapeStyle(.tint.opacity(0.08)) : AnyShapeStyle(.clear), in: .rect(cornerRadius: 10))
    }

    func chip(_ word: TimedWord, at position: Int) -> some View {
        let isCursor = position == cursorWord, isHolding = position == holdingWord
        return Text(word.text)
            .font(.title3.weight(isCursor ? .semibold : .regular))
            .padding(.horizontal, 7).padding(.vertical, 3)
            .foregroundStyle(isHolding ? AnyShapeStyle(.white) : word.isTimed ? AnyShapeStyle(.tint) : AnyShapeStyle(.primary))
            .background(isHolding ? AnyShapeStyle(.tint) : word.isTimed ? AnyShapeStyle(.tint.opacity(0.15)) : AnyShapeStyle(.clear), in: .rect(cornerRadius: 6))
            .overlay { if isCursor && !isHolding { RoundedRectangle(cornerRadius: 6).strokeBorder(.tint, lineWidth: 1.5) } }
            .help(word.isTimed ? "\(word.start.map(KaraokeClock.display) ?? "…") – \(word.end.map(KaraokeClock.display) ?? "…")" : "Not timed")
            .onTapGesture { onJump(position) }
    }
}
