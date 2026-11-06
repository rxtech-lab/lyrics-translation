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
                        KaraokeStage(song: song, track: track, playback: playback) { path.append(.timing) }
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
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
                        .pickerStyle(.segmented).help("Which text is shown and timed as the karaoke subtitle")
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

/// Karaoke preview: all simultaneously sung lines, their companion text, and the next cue.
private struct KaraokeStage: View {
    let song: Song
    let track: KaraokeTrack
    let playback: MusicPlayback
    var onTime: () -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let lines = song.lines.compactMap { line in line.span(track).map { (line: line, words: line.words(track), span: $0) } }
        if lines.isEmpty {
            ContentUnavailableView {
                Label("No word timings yet", systemImage: "metronome")
            } description: {
                Text("Time the \(track.rawValue.lowercased()) lyrics by holding Space while each word is sung.")
            } actions: {
                Button("Time Words", action: onTime).buttonStyle(.borderedProminent)
            }
        } else {
            TimelineView(.animation) { _ in
                let time = playback.time
                // Use each line's complete span: another singer starting must not hide it.
                let active = lines.indices.filter {
                    lines[$0].span.lowerBound <= time && time < lines[$0].span.upperBound
                }
                let upcoming = lines.indices.filter { lines[$0].span.lowerBound > time }
                    .min { lines[$0].span.lowerBound < lines[$1].span.lowerBound }
                GeometryReader { geometry in
                    ScrollView {
                        VStack(spacing: 28) {
                            ForEach(active, id: \.self) { index in
                                let item = lines[index]
                                VStack(spacing: 16) {
                                    if let tag = item.line.tag {
                                        Text(tag).font(.callout.weight(.semibold)).foregroundStyle(.tint)
                                    }
                                    FlowLayout(alignment: .center, lineSpacing: 10) {
                                        let ranges = TimedWord.resolve(item.words)
                                        ForEach(Array(item.words.enumerated()), id: \.offset) { index, word in
                                            KaraokeWord(text: word.text + (word.space ? " " : ""), progress: progress(ranges[index], time: time))
                                        }
                                    }
                                    let companion = item.line.text(track.other)
                                    if !companion.isEmpty {
                                        Text(companion).font(.title2).foregroundStyle(.secondary).multilineTextAlignment(.center)
                                    }
                                }
                                .transition(lineTransition)
                            }
                            if let upcoming {
                                Text(lines[upcoming].line.text(track))
                                    .font(.title3).foregroundStyle(.tertiary)
                                    .multilineTextAlignment(.center)
                                    .id(upcoming)
                                    .transition(lineTransition)
                            }
                        }
                        .padding(40)
                        .frame(maxWidth: .infinity, minHeight: geometry.size.height)
                        .animation(.easeInOut(duration: reduceMotion ? 0.15 : 0.35), value: active)
                        .animation(.easeInOut(duration: reduceMotion ? 0.15 : 0.35), value: upcoming)
                    }
                }
            }
        }
    }

    private var lineTransition: AnyTransition {
        reduceMotion ? .opacity : .asymmetric(
            insertion: .offset(y: 32).combined(with: .opacity),
            removal: .offset(y: -32).combined(with: .opacity)
        )
    }

    func progress(_ range: ClosedRange<Double>?, time: Double) -> Double {
        guard let range else { return 0 }
        guard range.upperBound > range.lowerBound else { return time >= range.lowerBound ? 1 : 0 }
        return min(1, max(0, (time - range.lowerBound) / (range.upperBound - range.lowerBound)))
    }
}

/// A word that fills with the accent colour from left to right as it is sung.
private struct KaraokeWord: View {
    let text: String
    let progress: Double

    var body: some View {
        Text(text).font(.system(size: 40, weight: .bold, design: .rounded)).foregroundStyle(.tertiary)
            .overlay(alignment: .leading) {
                Text(text).font(.system(size: 40, weight: .bold, design: .rounded)).foregroundStyle(.tint)
                    .mask(alignment: .leading) { GeometryReader { proxy in Rectangle().frame(width: proxy.size.width * progress) } }
            }
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
                    .disabled(holding != nil || undoTarget == nil)
                hint("arrow.up", "Redo line")
                Button { editingLine = min(cursor.line, song.lines.count - 1) } label: { hint("e.square", "Precise edit") }
                    .buttonStyle(.plain)
                    .disabled(holding != nil || song.lines.isEmpty)
                    .help("Edit the current line’s timing precisely (E)")
                Button(action: advanceLine) { hint("arrow.right", "Next line") }
                    .buttonStyle(.plain)
                    .disabled(holding != nil || nextLine == nil)
                    .help("Move to the next lyric line (Right Arrow)")
                Spacer()
                if finished { Label("All words timed", systemImage: "checkmark.seal.fill").foregroundStyle(.green) }
                Menu {
                    Button("Detect from Recording…", systemImage: "waveform.badge.magnifyingglass") { detecting = true }
                    Button("Fill Gaps Between Timed Words…", systemImage: "arrow.left.and.right.text.vertical") { confirmFill = true }
                        .disabled(song.timedCount(track).timed == 0)
                } label: {
                    Label("Auto-Time", systemImage: "wand.and.stars")
                } primaryAction: {
                    detecting = true
                }
                .menuStyle(.button).buttonStyle(.bordered).fixedSize()
                .disabled(holding != nil)
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
            guard holding == nil, !song.lines.isEmpty else { return .ignored }
            editingLine = min(cursor.line, song.lines.count - 1); return .handled
        }
        .navigationDestination(item: $editingLine) { line in
            WordTimingEditor(lineCount: song.lines.count,
                             text: { (song.lines[$0].text(track), song.lines[$0].tag) },
                             load: { words($0) },
                             save: { commit($0, $1) },
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
                song.checkpoint("Before detecting \(track.rawValue.lowercased()) timings")
                apply(lines)
                report("Detected timings applied")
            }
        }
        .onAppear { reloadDraft(); focused = true; cursor = firstUntimed() }
        .onChange(of: track) { reloadDraft(); holding = nil; timingHistory = []; cursor = firstUntimed() }
        .navigationTitle("Time Words")
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                Picker("Subtitle", selection: $track) { ForEach(KaraokeTrack.allCases) { Text($0.rawValue).tag($0) } }.pickerStyle(.segmented)
                Picker("Reaction offset", selection: Binding(get: { song.timingOffset ?? 0 }, set: { song.timingOffset = $0 == 0 ? nil : $0 })) {
                    ForEach([0, -0.05, -0.1, -0.15, -0.2, -0.3], id: \.self) { value in Text(value == 0 ? "No offset" : "\(Int(value * 1000)) ms").tag(value) }
                }
                .pickerStyle(.menu).fixedSize().help("Shift each press earlier to make up for reaction time")
                Button("Clear Timings", systemImage: "eraser", role: .destructive) { confirmClear = true }.disabled(song.timedCount(track).timed == 0)
            }
        }
        .confirmationDialog("Clear all \(track.rawValue.lowercased()) word timings?", isPresented: $confirmClear) {
            Button("Clear Timings", role: .destructive) {
                song.checkpoint("Before clearing \(track.rawValue.lowercased()) timings")
                for index in song.lines.indices { song.lines[index].setWords(TimedWord.split(song.lines[index].text(track)), track) }
                reloadDraft()
                holding = nil; timingHistory = []; cursor = firstUntimed(); report("Timings cleared")
            }
        } message: { Text("A copy is saved in Versions so you can restore it.") }
        .confirmationDialog("Fill untimed words between the words you’ve timed?", isPresented: $confirmFill) {
            Button("Fill Gaps") {
                song.checkpoint("Before filling \(track.rawValue.lowercased()) timing gaps")
                let before = song.timedCount(track).timed
                apply(AutoTiming.interpolate(song.lines.indices.map(words)))
                report("Filled \(song.timedCount(track).timed - before) words")
            }
        } message: { Text("Each skipped word gets a share of the time between its timed neighbours, by syllables. Lines inside long pauses stay untimed. A copy is saved in Versions.") }
    }

    /// Replaces every line's words for the track, e.g. after automatic timing.
    func apply(_ lines: [[TimedWord]]) {
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
        let words = words(index)
        let active = index == cursor.line
        return HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text("\(index + 1)").monospacedDigit().foregroundStyle(.tertiary).frame(width: 28, alignment: .trailing)
            VStack(alignment: .leading, spacing: 6) {
                if let tag = line.tag { Text(tag).font(.caption.weight(.semibold)).foregroundStyle(.tint) }
                FlowLayout(spacing: 4, lineSpacing: 4) {
                    ForEach(Array(words.enumerated()), id: \.offset) { position, word in
                        chip(word, at: Cursor(line: index, word: position))
                    }
                }
                let companion = line.text(track.other)
                if !companion.isEmpty { Text(companion).font(.callout).foregroundStyle(.secondary) }
            }
            Spacer(minLength: 0)
            if let start = TimedWord.resolve(words).compactMap({ $0?.lowerBound }).min() { Text(KaraokeClock.display(start)).font(.caption).monospacedDigit().foregroundStyle(.secondary) }
            if words.contains(where: \.isTimed) {
                Button("Play Line", systemImage: "play.circle.fill") {
                    Task { do { try await playback.playLine(words) } catch { report("!" + error.localizedDescription) } }
                }
                .labelStyle(.iconOnly).buttonStyle(.borderless)
                .disabled(holding != nil || playback.loading)
                .help("Play this line’s timed words")
            }
            Button("Edit Precisely", systemImage: "slider.horizontal.below.rectangle") { editingLine = index }
                .labelStyle(.iconOnly).buttonStyle(.borderless).disabled(words.isEmpty || holding != nil)
                .help("Edit this line’s word timing precisely")
        }
        .padding(10)
        .background(active ? AnyShapeStyle(.tint.opacity(0.08)) : AnyShapeStyle(.clear), in: .rect(cornerRadius: 10))
    }

    func chip(_ word: TimedWord, at position: Cursor) -> some View {
        let isCursor = position == cursor, isHolding = position == holding
        return Text(word.text)
            .font(.title3.weight(isCursor ? .semibold : .regular))
            .padding(.horizontal, 7).padding(.vertical, 3)
            .foregroundStyle(isHolding ? AnyShapeStyle(.white) : word.isTimed ? AnyShapeStyle(.tint) : AnyShapeStyle(.primary))
            .background(isHolding ? AnyShapeStyle(.tint) : word.isTimed ? AnyShapeStyle(.tint.opacity(0.15)) : AnyShapeStyle(.clear), in: .rect(cornerRadius: 6))
            .overlay { if isCursor && !isHolding { RoundedRectangle(cornerRadius: 6).strokeBorder(.tint, lineWidth: 1.5) } }
            .help(word.isTimed ? "\(word.start.map(KaraokeClock.display) ?? "…") – \(word.end.map(KaraokeClock.display) ?? "…")" : "Not timed")
            .onTapGesture { jump(to: position) }
    }

    // MARK: Actions

    var now: Double { max(0, playback.time + offset) }

    func words(_ line: Int) -> [TimedWord] {
        if draft.indices.contains(line) { return draft[line] }
        return song.lines.indices.contains(line) ? song.lines[line].words(track) : []
    }

    func reloadDraft() { draft = song.lines.map { $0.words(track) } }

    /// Saves one line's words to the working copy and the document.
    func commit(_ line: Int, _ words: [TimedWord]) {
        if draft.count != song.lines.count { reloadDraft() }
        draft[line] = words
        song.lines[line].setWords(words, track)
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
            if nextLine == nil {
                cursor = Cursor(line: song.lines.count, word: 0)
            } else {
                report("Line complete · Press → for the next line")
            }
        }
        if finished { playback.pause(); report("All \(track.rawValue.lowercased()) words timed") }
    }

    var nextLine: Int? {
        guard !finished else { return nil }
        return song.lines.indices.first { $0 > cursor.line && !words($0).isEmpty }
    }

    func advanceLine() {
        guard holding == nil, let line = nextLine else { return }
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
        guard holding == nil, let target = undoTarget else { return }
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
        guard holding == nil else { return }
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
        guard holding == nil else { return }
        cursor = position
        let word = words(position.line)[position.word]
        if let start = word.start ?? word.end { playback.seek(to: start - offset - 2) }
        focused = true
    }
}
