import SwiftUI
import RxAgentSDK

/// Detail page for a single lyric line: original, translation, estimated meter and rhymes.
struct LineDetailView: View {
    let line: LyricLine
    let number: Int
    let total: Int
    let lines: [LyricLine]
    let busy: Bool
    var music: AppleMusicTrack? = nil
    @State private var playbackError: String?
    @State private var startingPlayback = false
    var onReview: () -> Void
    var onTranslate: () -> Void
    var onDeleteTranslation: () -> Void
    var onSelectLine: (Int) -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                header
                lyricCard
                actions
                HStack(alignment: .top, spacing: 16) {
                    meterCard
                    rhymeCard
                }
                if !line.review.isEmpty { reviewCard }
            }
            .padding(.horizontal, 40).padding(.vertical, 32)
            .frame(maxWidth: 900, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        .scrollContentBackground(.hidden)
        .alert("Apple Music", isPresented: Binding(get: { playbackError != nil }, set: { if !$0 { playbackError = nil } })) {
            Button("OK") { playbackError = nil }
        } message: { Text(playbackError ?? "") }
    }

    // MARK: Header

    var header: some View {
        HStack(spacing: 10) {
            Text("Line \(number)").font(.subheadline.weight(.semibold)).monospacedDigit()
            Text("of \(total)").font(.subheadline).foregroundStyle(.secondary)
            if let section = line.section { Pill(text: section, systemImage: "rectangle.3.group", tint: .purple) }
            if let speaker = line.speaker { Pill(text: speaker, systemImage: "person.fill", tint: .blue) }
            Spacer()
            Pill(text: status.title, systemImage: status.icon, tint: status.tint)
        }
    }

    var status: (title: String, icon: String, tint: Color) {
        if line.approved { return ("Approved", "checkmark.seal.fill", .green) }
        if line.translated.isEmpty { return ("Original", "doc.text", .secondary) }
        return ("Awaiting review", "hourglass", .orange)
    }

    // MARK: Lyrics

    var lyricCard: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 10) {
                HStack { SectionLabel(title: "Original", systemImage: "text.quote"); Spacer(); linePlayButton(.original) }
                Text(line.original).font(.system(size: 30, weight: .semibold)).textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(24)
            Divider().padding(.horizontal, 24)
            VStack(alignment: .leading, spacing: 10) {
                HStack { SectionLabel(title: "Translation", systemImage: "character.bubble"); Spacer(); linePlayButton(.translation) }
                if line.translated.isEmpty {
                    HStack(spacing: 10) {
                        Image(systemName: "sparkles").foregroundStyle(.tint)
                        Text("Your singable translation will appear here.").foregroundStyle(.secondary)
                    }
                    .font(.title3)
                } else {
                    Text(line.translated).font(.system(size: 24, weight: .medium)).foregroundStyle(.tint).textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(24)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(.separator.opacity(0.6)))
    }

    @ViewBuilder
    func linePlayButton(_ track: KaraokeTrack) -> some View {
        if let music, line.words(track).contains(where: \.isTimed) {
            TimelineView(.periodic(from: .now, by: 0.1)) { _ in
                let playback = MusicPlayback.shared
                let playing = playback.loadedID == music.id && playback.isPlaying
                Button(playing ? "Pause" : "Play Line", systemImage: playing ? "pause.circle.fill" : "play.circle.fill") {
                    if playback.loadedID == music.id && playback.isPlaying {
                        playback.pause()
                    } else {
                        startingPlayback = true
                        Task { @MainActor in
                            defer { startingPlayback = false }
                            do {
                                try await playback.load(music)
                                try await playback.playLine(line.words(track))
                            } catch { playbackError = error.localizedDescription }
                        }
                    }
                }
                .labelStyle(.iconOnly).buttonStyle(.borderless).font(.title2)
                .disabled(startingPlayback || playback.loading)
                .help(playing ? "Pause Apple Music playback" : "Play this line’s timed \(track.rawValue.lowercased()) words")
            }
        }
    }

    var actions: some View {
        HStack(spacing: 10) {
            Button(action: onTranslate) {
                Label(line.translated.isEmpty ? "Translate line" : "Retranslate", systemImage: "wand.and.sparkles")
            }
            .buttonStyle(.borderedProminent)
            Button(action: onReview) { Label("Review line", systemImage: "checkmark.bubble") }
                .buttonStyle(.bordered)
            Spacer()
            if !line.translated.isEmpty {
                Button(role: .destructive, action: onDeleteTranslation) { Label("Delete translation", systemImage: "eraser") }
                    .buttonStyle(.borderless)
            }
        }
        .controlSize(.large)
        .disabled(busy)
    }

    // MARK: Meter

    var meterCard: some View {
        Card {
            HStack(alignment: .firstTextBaseline) {
                SectionLabel(title: "Estimated meter", systemImage: "waveform")
                Spacer()
                Text("\(line.syllables)").font(.title2.weight(.semibold)).monospacedDigit()
                Text(line.syllables == 1 ? "syllable" : "syllables").font(.caption).foregroundStyle(.secondary)
            }
            if line.stress.isEmpty {
                Text("Translate the line to analyze its rhythm.").font(.callout).foregroundStyle(.secondary)
            } else {
                HStack(alignment: .bottom, spacing: 8) {
                    ForEach(Array(line.stress.enumerated()), id: \.offset) { index, beat in
                        let stressed = beat == "1"
                        VStack(spacing: 6) {
                            RoundedRectangle(cornerRadius: 4, style: .continuous)
                                .fill(stressed ? AnyShapeStyle(.tint) : AnyShapeStyle(.quaternary))
                                .frame(width: 18, height: stressed ? 44 : 20)
                            Text("\(index + 1)").font(.caption2).monospacedDigit().foregroundStyle(.secondary)
                        }
                    }
                }
                .frame(height: 64, alignment: .bottom)
                .accessibilityElement()
                .accessibilityLabel("Stress pattern \(line.stress)")
                HStack(spacing: 14) {
                    Legend(style: AnyShapeStyle(.tint), title: "Stressed")
                    Legend(style: AnyShapeStyle(.quaternary), title: "Unstressed")
                }
            }
        }
    }

    // MARK: Rhymes

    var rhymeCard: some View {
        Card {
            HStack {
                SectionLabel(title: "Original rhymes", systemImage: "link")
                Spacer()
                if !line.rhymes.isEmpty { Text("\(line.rhymes.count)").font(.caption.weight(.semibold)).foregroundStyle(.secondary) }
            }
            if line.rhymes.isEmpty {
                Text("No rhymes detected yet.").font(.callout).foregroundStyle(.secondary)
            } else {
                VStack(spacing: 0) {
                    ForEach(Array(line.rhymes.enumerated()), id: \.offset) { index, rhyme in
                        if index > 0 { Divider() }
                        RhymePopoverRow(rhyme: rhyme, lines: lines, onSelectLine: onSelectLine)
                        .padding(.vertical, 10)
                    }
                }
            }
        }
    }

    // MARK: Review

    var reviewCard: some View {
        Card {
            SectionLabel(title: "Agent review", systemImage: "text.bubble")
            MarkdownView(text: line.review)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

private struct Card<Content: View>: View {
    @ViewBuilder var content: Content
    var body: some View {
        VStack(alignment: .leading, spacing: 14) { content }
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .topLeading)
            .background(.background.secondary, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(.separator.opacity(0.6)))
    }
}

private struct SectionLabel: View {
    let title: String
    let systemImage: String
    var body: some View {
        Label(title.uppercased(), systemImage: systemImage)
            .font(.caption.weight(.semibold)).tracking(0.6).foregroundStyle(.secondary)
    }
}

private struct Pill: View {
    let text: String
    let systemImage: String
    let tint: Color
    var body: some View {
        Label(text, systemImage: systemImage)
            .font(.caption.weight(.medium))
            .padding(.horizontal, 10).padding(.vertical, 5)
            .foregroundStyle(tint)
            .background(tint.opacity(0.14), in: Capsule())
    }
}

private struct Legend: View {
    let style: AnyShapeStyle
    let title: String
    var body: some View {
        HStack(spacing: 6) {
            RoundedRectangle(cornerRadius: 2).fill(style).frame(width: 10, height: 10)
            Text(title).font(.caption).foregroundStyle(.secondary)
        }
    }
}

private struct RhymePopoverRow: View {
    let rhyme: Rhyme
    let lines: [LyricLine]
    let onSelectLine: (Int) -> Void
    @State private var presented = false

    private var related: [Int] {
        Array(Set(rhyme.relatedLines)).sorted().filter { lines.indices.contains($0 - 1) }
    }

    var body: some View {
        Button { presented = true } label: {
            HStack {
                Text("/\(rhyme.sound)/").font(.callout.monospaced()).foregroundStyle(.tint)
                Text(rhyme.words).lineLimit(2)
                Spacer()
                Image(systemName: "text.bubble")
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("Show related lyric lines")
        .popover(isPresented: $presented) {
            VStack(alignment: .leading, spacing: 12) {
                Text("\(rhyme.words) · /\(rhyme.sound)/").font(.headline)
                Text("Original rhyme · related lines").font(.caption).foregroundStyle(.secondary)
                if related.isEmpty {
                    Text("No related lines recorded. This may be an internal rhyme.")
                } else {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 16) {
                            ForEach(related, id: \.self) { number in
                                let partner = lines[number - 1]
                                VStack(alignment: .leading, spacing: 6) {
                                    Button("Line \(number) \(partner.label)") {
                                        presented = false
                                        onSelectLine(number)
                                    }
                                    Text(partner.original).textSelection(.enabled)
                                    Text(partner.translated.isEmpty ? "Not translated yet" : partner.translated)
                                        .foregroundStyle(.secondary).textSelection(.enabled)
                                }
                                .frame(maxWidth: .infinity, alignment: .leading)
                            }
                        }
                    }
                    .frame(maxHeight: 340)
                }
            }
            .padding(20)
            .frame(width: 380)
        }
    }
}
