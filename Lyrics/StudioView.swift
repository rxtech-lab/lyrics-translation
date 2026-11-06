import SwiftUI
import RxAgentSDK

struct StudioView: View {
    @Binding var document: LyricDocument
    /// File name without extension; empty for untitled documents.
    var title = ""
    @State private var pipeline = Pipeline()
    @State private var selection: Set<UUID> = []
    @State private var pendingDelete: Set<UUID>?
    @State private var pendingClear: Set<UUID>?
    @State private var video = false
    @State private var sharing = false
    @State private var shareLineIDs: Set<UUID>?
    @State private var sheet: String?
    @State private var editingOriginal = false
    @State private var team: Bool?
    @State private var comment = ""
    @State private var edited = ""
    @State private var restore: Revision?
    @State private var chatting = false
    @State private var showingUsage = false
    @State private var karaoke = false
    @State private var musicError: String?
    @State private var musicScrub: Double?
    func backgroundPlayer(_ music: AppleMusicTrack) -> some View {
        TimelineView(.periodic(from: .now, by: 0.2)) { _ in
            let playback = MusicPlayback.shared
            let loaded = playback.loadedID == music.id
            let duration = max(0, music.duration ?? 0)
            let position = musicScrub ?? (loaded ? playback.time : 0)
            VStack(spacing: 8) {
                HStack(spacing: 12) {
                    Button { karaoke = true } label: {
                        HStack(spacing: 12) {
                            Artwork(url: music.artworkURL, size: 44)
                            VStack(alignment: .leading, spacing: 3) {
                                Text(music.title).font(.subheadline.bold()).lineLimit(1)
                                Text(music.artist).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                            }
                            Spacer()
                        }.contentShape(Rectangle())
                    }.accessibilityLabel("Expand Music Player")
                    let playing = playback.loadedID == music.id && playback.isPlaying
                    Button(playing ? "Pause" : "Play", systemImage: playing ? "pause.fill" : "play.fill") {
                        Task { @MainActor in
                            do { try await playback.load(music); try await playback.toggle() }
                            catch { musicError = error.localizedDescription }
                        }
                    }.labelStyle(.iconOnly).frame(width: 44, height: 44).disabled(playback.loading)
                    if playback.loading { ProgressView().controlSize(.small) }
                }
                HStack(spacing: 10) {
                    Text(KaraokeClock.display(position))
                        .frame(minWidth: 44, alignment: .trailing)
                    Slider(value: Binding(get: { min(max(position, 0), max(duration, 1)) }, set: { musicScrub = $0 }), in: 0...max(duration, 1)) { editing in
                        if !editing, let target = musicScrub {
                            if playback.loadedID == music.id { playback.seek(to: target) }
                            musicScrub = nil
                        }
                    }
                    .disabled(!loaded || duration <= 0 || playback.loading)
                    .accessibilityLabel("Playback progress")
                    Text(duration > 0 ? KaraokeClock.display(duration) : "–:––")
                        .frame(minWidth: 44, alignment: .leading)
                }
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain).padding(12)
            .glassEffect(.regular, in: .rect(cornerRadius: 24))
            .padding(.horizontal, 20).padding(.vertical, 8)
        }
        .onChange(of: music.id) { musicScrub = nil }
        .alert("Apple Music", isPresented: Binding(get: { musicError != nil }, set: { if !$0 { musicError = nil } })) {
            Button("OK") { musicError = nil }
        } message: { Text(musicError ?? "") }
    }

    var body: some View {
        NavigationSplitView {
            List(selection: $selection) {
                ForEach(Array(document.song.lines.enumerated()), id: \.element.id) { index, line in
                    VStack(alignment: .leading, spacing: 5) {
                        if let tag = line.tag {
                            Text(tag)
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(selection.contains(line.id) ? AnyShapeStyle(.primary) : AnyShapeStyle(.tint))
                        }
                        Text("\(index + 1)  \(line.original)").lineLimit(2)
                        Text(line.approved ? "Approved" : line.translated.isEmpty ? "Original" : "Awaiting review").font(.caption).foregroundStyle(.secondary)
                    }.padding(.vertical, 5).tag(line.id)
                }
            }
            .contextMenu(forSelectionType: UUID.self) { ids in
                if !ids.isEmpty {
                    Button(ids.count == 1 ? "Share Line…" : "Share \(ids.count) Lines…", systemImage: "square.and.arrow.up") {
                        shareLineIDs = ids
                        sharing = true
                    }
                    Divider()
                    let translated = translatedIDs(in: ids)
                    Button(translated.count == 1 ? "Delete Translation" : "Delete \(translated.count) Translations", systemImage: "eraser", role: .destructive) { pendingClear = translated }.disabled(translated.isEmpty || pipeline.running)
                    Button(ids.count == 1 ? "Delete Line" : "Delete \(ids.count) Lines", systemImage: "trash", role: .destructive) { pendingDelete = ids }.disabled(pipeline.running)
                    Divider()
                }
                Button("Delete All Lines", systemImage: "trash.slash", role: .destructive) { pendingDelete = Set(document.song.lines.map(\.id)) }.disabled(document.song.lines.isEmpty || pipeline.running)
            }
            .onDeleteCommand { if !selection.isEmpty, !pipeline.running { pendingDelete = selection } }
            .navigationTitle("Lyrics").navigationSplitViewColumnWidth(min: 220, ideal: 280)
        } detail: {
            VStack(spacing: 0) {
                if selection.count > 1 {
                    ContentUnavailableView {
                        Label("\(selection.count) lines selected", systemImage: "text.badge.checkmark")
                    } description: {
                        Text("Right-click to share the selected lines, or press Delete to remove them.")
                    } actions: {
                        let translated = translatedIDs(in: selection)
                        Button(translated.count == 1 ? "Delete Translation" : "Delete \(translated.count) Translations", role: .destructive) { pendingClear = translated }.disabled(translated.isEmpty || pipeline.running)
                        Button("Delete \(selection.count) Lines", role: .destructive) { pendingDelete = selection }.disabled(pipeline.running)
                    }
                } else if let index = document.song.lines.firstIndex(where: { selection.contains($0.id) }) {
                    let line = document.song.lines[index]
                    LineDetailView(line: line, number: index + 1, total: document.song.lines.count, lines: document.song.lines, busy: pipeline.running, music: document.song.appleMusic) {
                        comment = line.comment; edited = line.translated; sheet = "Review line"
                    } onTranslate: {
                        pipeline.start(song: $document.song, only: line.id)
                    } onDeleteTranslation: {
                        pendingClear = [line.id]
                    } onSelectLine: { number in
                        if document.song.lines.indices.contains(number - 1) { selection = [document.song.lines[number - 1].id] }
                    }
                } else {
                    ContentUnavailableView("Give your lyrics a new voice", systemImage: "music.note", description: Text("Add original lyrics, choose your agents, and shape a translation you can sing."))
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .safeAreaInset(edge: .bottom, spacing: 0) {
                if let music = document.song.appleMusic {
                    backgroundPlayer(music)
                }
            }
        }
        .frame(minWidth: 960, minHeight: 660)
        .toolbar {
            // Setup: everything that shapes the song before/around translation.
            ToolbarItem(placement: .primaryAction) {
                Menu("Song", systemImage: "doc.text") {
                    Button("Share Translation…", systemImage: "square.and.arrow.up") { shareLineIDs = nil; sharing = true }
                    Button("Edit Original Lyrics…", systemImage: "doc.text") { editingOriginal = true }
                    Button("Translation Agents…", systemImage: "person.3") { team = false }
                    Divider()
                    Button("Version History…", systemImage: "clock.arrow.circlepath") { sheet = "Versions" }
                }
                .disabled(pipeline.running)
                .help("Original lyrics, agents and versions")
            }
            // Insights: read-only views into what the agents did.
            ToolbarItem(placement: .primaryAction) {
                Menu("Insights", systemImage: "sparkles.rectangle.stack") {
                    Button("Agent Conversation", systemImage: "bubble.left.and.bubble.right") { chatting = true }
                    Button("Activity Log", systemImage: "list.bullet.rectangle") { sheet = "Activity" }
                    Button("Usage & Cost", systemImage: "chart.bar.xaxis") { showingUsage = true }
                }
                .help("Conversation, activity and usage")
            }
            ToolbarItem(placement: .primaryAction) {
                Button("Lyric Video", systemImage: "film") { video = true }
                Button("Karaoke", systemImage: "music.mic") { karaoke = true }
                    .disabled(document.song.lines.isEmpty)
                    .keyboardShortcut("k", modifiers: [.command, .shift])
                    .help("Time sung words to an Apple Music recording")
            }
            ToolbarSpacer(.fixed, placement: .primaryAction)
            // The one primary action, which turns into Stop while agents run.
            ToolbarItem(placement: .primaryAction) {
                if pipeline.running {
                    Button("Stop", systemImage: "stop.fill") { pipeline.stop() }
                        .keyboardShortcut(".", modifiers: .command)
                        .help("Stop the agents")
                } else {
                    Button("Translate All", systemImage: "play.fill") { team = true }
                        .buttonStyle(.borderedProminent)
                        .disabled(document.song.lines.isEmpty)
                        .keyboardShortcut("r", modifiers: .command)
                        .help("Choose agents and translate every line")
                }
            }
        }
        .overlay(alignment: .top) {
            if !pipeline.status.isEmpty {
                HStack { if pipeline.running { ProgressView().controlSize(.small) }; Text(pipeline.status); if pipeline.canRetryTranslation { Button("Retry", systemImage: "arrow.clockwise") { pipeline.retryTranslation(song: $document.song) } }; Button("Activity") { sheet = "Activity" } }
                    .padding().background(.regularMaterial, in: Capsule()).padding()
            }
        }
        .alert("Agent could not finish", isPresented: Binding(get: { pipeline.error != nil }, set: { if !$0 { pipeline.error = nil } })) {
            if pipeline.canRetryTranslation {
                Button("Retry Translation") { pipeline.retryTranslation(song: $document.song) }
            }
            Button("OK", role: .cancel) { pipeline.error = nil }
        } message: { Text(pipeline.error ?? "") }
        .confirmationDialog("Restore this version? Current work will be saved as a version first.", isPresented: Binding(get: { restore != nil }, set: { if !$0 { restore = nil } })) {
            Button("Restore version") {
                if let restore { document.song.checkpoint("Before restore"); document.song.lines = restore.lines; document.song.direction = restore.direction; pipeline.status = "Version restored" }
                restore = nil
            }
        }
        .confirmationDialog(deleteTitle, isPresented: Binding(get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } })) {
            Button(deleteTitle, role: .destructive) {
                if let ids = pendingDelete {
                    document.song.checkpoint("Before deleting \(ids.count) line\(ids.count == 1 ? "" : "s")")
                    document.song.lines.removeAll { ids.contains($0.id) }
                    selection.subtract(ids)
                    pipeline.status = "Deleted \(ids.count) line\(ids.count == 1 ? "" : "s")"
                }
                pendingDelete = nil
            }
        } message: { Text("A copy of the current lyrics is saved in Versions so you can restore them.") }
        .confirmationDialog(clearTitle, isPresented: Binding(get: { pendingClear != nil }, set: { if !$0 { pendingClear = nil } })) {
            Button(clearTitle, role: .destructive) {
                if let ids = pendingClear {
                    document.song.checkpoint("Before deleting \(ids.count) translation\(ids.count == 1 ? "" : "s")")
                    for index in document.song.lines.indices where ids.contains(document.song.lines[index].id) {
                        document.song.lines[index].translated = ""
                        document.song.lines[index].review = ""
                        document.song.lines[index].approved = false
                    }
                    pipeline.status = "Deleted \(ids.count) translation\(ids.count == 1 ? "" : "s")"
                }
                pendingClear = nil
            }
        } message: { Text("The original lyrics stay. A copy of the current translations is saved in Versions so you can restore them.") }
        .sheet(isPresented: Binding(get: { sheet != nil }, set: { if !$0 { sheet = nil } })) {
            NavigationStack {
                sheetContent.frame(maxWidth: .infinity, maxHeight: .infinity)
                    .navigationTitle(sheet ?? "")
                    .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Done") { sheet = nil } } }
            }.frame(minWidth: 740, idealWidth: 860, maxWidth: .infinity, minHeight: 640, idealHeight: 760, maxHeight: .infinity)
        }
        .sheet(isPresented: $editingOriginal) {
            OriginalLyricsSheet(song: $document.song) { source in
                document.song.checkpoint("Before editing original")
                document.song.lines = source.components(separatedBy: .newlines).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }.map { LyricLine(original: $0) }
                selection = Set(document.song.lines.prefix(1).map(\.id)); pipeline.status = "Original saved"
            } onFormat: { source in
                pipeline.format(source, song: $document.song) { selection = Set([$0].compactMap { $0 }) }
            }
        }
        .sheet(isPresented: Binding(get: { team != nil }, set: { if !$0 { team = nil } })) {
            TranslationTeamSheet(song: $document.song, startsTranslation: team ?? false) { resume in pipeline.start(song: $document.song, resume: resume) }
        }
        .sheet(isPresented: $chatting) { ConversationSheet(song: document.song) }
        .sheet(isPresented: $sharing) { ShareLyricsSheet(song: $document.song, title: title, initialLineIDs: shareLineIDs) }
        .sheet(isPresented: $showingUsage) { UsageSheet(song: $document.song) }
        .sheet(isPresented: $video) { LyricVideoSheet(song: document.song, title: title) }
        .sheet(isPresented: $karaoke) { KaraokeSheet(song: $document.song, title: title) }
        .onDisappear { pipeline.stop() }
    }
    @ViewBuilder var sheetContent: some View {
        switch sheet {
        case "Review line":
            VStack(alignment: .leading) {
                Text("Translation").font(.headline); TextEditor(text: $edited)
                Text("Direction for retranslation").font(.headline); TextEditor(text: $comment)
                HStack {
                    Button("Approve") { saveReview(approve: true) }
                    Button("Save feedback and retranslate") { saveReview(approve: false); pipeline.start(song: $document.song, only: selection.first) }
                }
            }.padding()
        case "Versions":
            List(document.song.versions.reversed()) { version in
                HStack { VStack(alignment: .leading) { Text(version.label); Text(version.date.formatted()).font(.caption) }; Spacer(); Button("Restore") { restore = version } }
            }
        default:
            ActivityContent(transcript: pipeline.transcript, running: pipeline.running, status: pipeline.status)
        }
    }
    var deleteTitle: String {
        let count = pendingDelete?.count ?? 0
        return count == document.song.lines.count && count > 1 ? "Delete All \(count) Lines" : count == 1 ? "Delete Line" : "Delete \(count) Lines"
    }
    var clearTitle: String {
        let count = pendingClear?.count ?? 0
        return count == 1 ? "Delete Translation" : "Delete \(count) Translations"
    }
    func translatedIDs(in ids: Set<UUID>) -> Set<UUID> {
        Set(document.song.lines.filter { ids.contains($0.id) && !$0.translated.isEmpty }.map(\.id))
    }
    func saveReview(approve: Bool) {
        guard let index = document.song.lines.firstIndex(where: { selection.contains($0.id) }) else { return }
        document.song.checkpoint("Before user review")
        document.song.lines[index].translated = edited
        document.song.lines[index].comment = comment
        document.song.lines[index].approved = approve
        sheet = nil; pipeline.status = approve ? "Line approved" : "Feedback saved"
    }
}


/// A readable activity feed, with one Markdown response per agent invocation.
private struct ActivityContent: View {
    let transcript: String
    let running: Bool
    let status: String

    private struct Entry: Identifiable {
        let id: Int
        let title: String
        var body: String
    }

    private var entries: [Entry] {
        var result: [Entry] = []
        for line in transcript.components(separatedBy: "\n") {
            if line.hasPrefix("— "), line.hasSuffix(" —"), line.count > 4 {
                result.append(Entry(id: result.count, title: String(line.dropFirst(2).dropLast(2)), body: ""))
            } else if !result.isEmpty {
                result[result.count - 1].body += line + "\n"
            } else if !line.trimmingCharacters(in: .whitespaces).isEmpty {
                result.append(Entry(id: 0, title: "Activity", body: line + "\n"))
            }
        }
        return result
    }

    var body: some View {
        Group {
            if entries.isEmpty {
                ContentUnavailableView("No activity yet", systemImage: "sparkles", description: Text("Agent direction, translations, and reviews will appear here when you run your team."))
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 20) {
                        ForEach(entries) { entry in
                            VStack(alignment: .leading, spacing: 18) {
                                HStack(spacing: 10) {
                                    Image(systemName: "sparkles")
                                        .foregroundStyle(.tint)
                                        .frame(width: 36, height: 36)
                                        .background(.tint.opacity(0.12), in: RoundedRectangle(cornerRadius: 10))
                                    Text(entry.title).font(.headline)
                                    Spacer()
                                    Text("\(entry.id + 1)").font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                                }
                                Divider()
                                if entry.body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                                    Text(running ? "Waiting for response…" : "No response text.").foregroundStyle(.secondary)
                                } else {
                                    MarkdownView(text: entry.body, style: MarkdownStyle(bodyFontSize: 15, lineSpacing: 5, blockSpacing: 14))
                                        .textSelection(.enabled)
                                        .fixedSize(horizontal: false, vertical: true)
                                }
                            }
                            .padding(24)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(.background.secondary, in: RoundedRectangle(cornerRadius: 18))
                            .overlay(RoundedRectangle(cornerRadius: 18).strokeBorder(.separator.opacity(0.5)))
                        }
                    }
                    .frame(maxWidth: 820)
                    .padding(28)
                    .padding(.bottom, running ? 64 : 0)
                    .frame(maxWidth: .infinity)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .overlay(alignment: .bottom) {
            if running {
                HStack(spacing: 10) {
                    ProgressView().controlSize(.small)
                    Text(status.isEmpty ? "Agents are working…" : status).font(.callout).lineLimit(2)
                }
                .padding(.horizontal, 18).padding(.vertical, 12)
                .background(.regularMaterial, in: Capsule())
                .padding(20)
            }
        }
    }
}
