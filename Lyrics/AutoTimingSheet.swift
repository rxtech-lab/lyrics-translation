import AVFoundation
import Speech
import SwiftUI
import UniformTypeIdentifiers

/// Detects word timings with on-device speech recognition, either by listening to the linked Apple Music song
/// while it plays or from a local copy of the recording, shows what was found, and applies it only when confirmed.
struct AutoTimingSheet: View {
    /// Current words of every line for the track being timed.
    let lines: [[TimedWord]]
    let trackName: String
    let sampleText: String
    let appleMusicDuration: Double?
    let playback: MusicPlayback
    var onApply: ([[TimedWord]]) -> Void
    @Environment(\.dismiss) private var dismiss

    @State private var source = Source.appleMusic
    @State private var fromStart = true
    @State private var capture: SystemAudioCapture?
    @State private var heardCount = 0
    @State private var listenEnd = 0.0
    @State private var file: URL?
    @State private var fileDuration: Double?
    @State private var importing = false
    @State private var locale = Locale(identifier: "en")
    @State private var locales: [Locale] = []
    @State private var keepExisting = true
    @State private var offset = 0.0
    @State private var phase = Phase.setup
    @State private var progress = 0.0
    @State private var message = ""
    @State private var task: Task<Void, Never>?

    enum Phase { case setup, running, listening, done(AutoTiming.Alignment), failed(String) }
    enum Source: String, CaseIterable, Identifiable { case appleMusic = "Apple Music", file = "Audio File"; var id: Self { self } }

    var canDetect: Bool { source == .appleMusic ? appleMusicDuration != nil : file != nil }

    var body: some View {
        NavigationStack {
            Group {
                switch phase {
                case .setup: setup
                case .running: running
                case .listening: listening
                case .done(let result): summary(result)
                case .failed(let error):
                    ContentUnavailableView {
                        Label("Couldn’t detect timings", systemImage: "exclamationmark.triangle")
                    } description: { Text(error) } actions: {
                        Button("Back") { phase = .setup }
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .navigationTitle("Detect Word Timing")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { cancel(); dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    switch phase {
                    case .setup: Button("Detect") { source == .appleMusic ? listen() : run() }.disabled(!canDetect)
                    case .listening: Button("Stop and Match") { Task { await capture?.stop() } }
                    case .done(let result): Button("Apply Timings") { onApply(result.lines); dismiss() }.disabled(result.matched + result.filled == 0)
                    default: EmptyView()
                    }
                }
            }
        }
        .frame(minWidth: 560, idealWidth: 600, maxWidth: .infinity, minHeight: 520, idealHeight: 560, maxHeight: .infinity)
        .fileImporter(isPresented: $importing, allowedContentTypes: [.audio]) { result in
            if case .success(let url) = result { choose(url) }
        }
        .task {
            locale = AutoTiming.language(of: sampleText)
            let supported = await SpeechTranscriber.supportedLocales
            locales = supported.sorted { name($0) < name($1) }
            if let match = await SpeechTranscriber.supportedLocale(equivalentTo: locale) { locale = match }
        }
        .onAppear { if appleMusicDuration == nil { source = .file } }
        .onDisappear { cancel() }
    }

    var setup: some View {
        Form {
            Section {
                Picker("Listen to", selection: $source) { ForEach(Source.allCases) { Text($0.rawValue).tag($0) } }
                    .pickerStyle(.segmented)
            } footer: {
                Text(source == .appleMusic
                     ? "The linked Apple Music song plays in real time while Lyric Studio listens to it on this Mac. macOS asks once for permission to record system audio."
                     : "Detection listens to your own copy of the same recording (MP3, M4A, WAV or AIFF). It’s faster than real time and isn’t affected by other sounds.")
            }
            if source == .appleMusic { appleMusicOptions } else { fileOptions }
            recognitionOptions
        }
        .formStyle(.grouped)
    }

    @ViewBuilder var appleMusicOptions: some View {
        Section("Apple Music") {
            if let appleMusicDuration {
                Picker("Start", selection: $fromStart) {
                    Text("From the beginning").tag(true)
                    Text("From the current position (\(KaraokeClock.display(playback.time)))").tag(false)
                }
                LabeledContent("Listening time", value: Duration.seconds(max(0, appleMusicDuration - (fromStart ? 0 : playback.time))).formatted(.time(pattern: .minuteSecond)))
                Label("Keep other sounds on your Mac quiet while it listens. You can stop early and match what was heard.", systemImage: "speaker.wave.2")
                    .font(.callout).foregroundStyle(.secondary)
            } else {
                Text("Link an Apple Music song first, or choose Audio File.").foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder var fileOptions: some View {
            Section {
                LabeledContent("Recording") {
                    HStack {
                        Text(file?.lastPathComponent ?? "None").foregroundStyle(file == nil ? .secondary : .primary).lineLimit(1).truncationMode(.middle)
                        Button(file == nil ? "Choose…" : "Change…") { importing = true }
                    }
                }
                if let mismatch = durationMismatch {
                    Label("This file is \(mismatch) than the Apple Music recording. Timings may need an offset.", systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.orange).font(.callout)
                }
            } header: {
                Text("Audio File")
            }
    }

    @ViewBuilder var recognitionOptions: some View {
            Section("Recognition") {
                Picker("Language", selection: $locale) {
                    if !locales.contains(locale) { Text(name(locale)).tag(locale) }
                    ForEach(locales, id: \.self) { Text(name($0)).tag($0) }
                }
                Toggle("Keep words I’ve already timed", isOn: $keepExisting)
                LabeledContent("Offset") {
                    HStack {
                        TextField("Offset", value: $offset, format: .number.precision(.fractionLength(2))).frame(width: 70).monospacedDigit()
                        Stepper("Offset", value: $offset, in: -10...10, step: 0.05).labelsHidden()
                        Text("seconds").foregroundStyle(.secondary)
                    }
                }
            }
            Section {
                Text("Sung words are matched to the \(trackName.lowercased()) lyrics even when some are missed or misheard. Words that can’t be heard are filled in between their neighbours by syllables. Long instrumental gaps are left untimed.")
                    .font(.callout).foregroundStyle(.secondary)
            }
    }

    var running: some View {
        VStack(spacing: 16) {
            ProgressView(value: progress).frame(width: 320)
            Text(message).foregroundStyle(.secondary)
            Text("\(Int(progress * 100))%").monospacedDigit().font(.title2.weight(.semibold))
        }
    }

    var listening: some View {
        TimelineView(.periodic(from: .now, by: 0.25)) { _ in
            let duration = max(1, listenEnd)
            VStack(spacing: 16) {
                Image(systemName: "waveform").font(.system(size: 44)).foregroundStyle(.tint).symbolEffect(.variableColor.iterative, isActive: playback.isPlaying)
                Text(message).foregroundStyle(.secondary)
                ProgressView(value: min(playback.time, duration), total: duration).frame(width: 320)
                Text("\(KaraokeClock.display(playback.time)) of \(KaraokeClock.display(duration))").monospacedDigit().foregroundStyle(.secondary)
                Text("\(heardCount) words heard").font(.title2.weight(.semibold)).monospacedDigit()
                Button("Stop and Match") { Task { await capture?.stop() } }.buttonStyle(.bordered)
            }
        }
    }

    func summary(_ result: AutoTiming.Alignment) -> some View {
        let timed = result.lines.joined().filter(\.isTimed).count
        return VStack(spacing: 20) {
            Image(systemName: "waveform.badge.magnifyingglass").font(.system(size: 44)).foregroundStyle(.tint)
            Text("\(timed) of \(result.total) words timed").font(.title2.weight(.semibold))
            Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 8) {
                GridRow { Text("Heard and matched"); Text("\(result.matched)").monospacedDigit().bold() }
                GridRow { Text("Filled between neighbours"); Text("\(result.filled)").monospacedDigit().bold() }
                GridRow { Text("Still untimed"); Text("\(result.total - timed)").monospacedDigit().bold() }
            }
            Text("A copy of the current timings is saved in Versions. Fine-tune any line with the precise editor.")
                .font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center).frame(maxWidth: 380)
        }
        .padding(30)
    }

    var durationMismatch: String? {
        guard let fileDuration, let appleMusicDuration, abs(fileDuration - appleMusicDuration) > 1.5 else { return nil }
        let difference = Duration.seconds(abs(fileDuration - appleMusicDuration)).formatted(.units(allowed: [.seconds], width: .abbreviated))
        return fileDuration > appleMusicDuration ? "\(difference) longer" : "\(difference) shorter"
    }

    func name(_ locale: Locale) -> String { Locale.current.localizedString(forIdentifier: locale.identifier) ?? locale.identifier }

    func choose(_ url: URL) {
        file = url
        fileDuration = (try? AVAudioFile(forReading: url)).map { Double($0.length) / $0.processingFormat.sampleRate }
    }

    /// Unique lyric words, passed to the recogniser as vocabulary hints.
    var hints: [String] {
        var seen = Set<String>()
        return lines.joined().map(\.text).map { $0.trimmingCharacters(in: .punctuationCharacters) }.filter { !$0.isEmpty && seen.insert($0.lowercased()).inserted }
    }

    func cancel() {
        task?.cancel()
        if let capture { Task { await capture.stop() } }
        capture = nil
    }

    /// Plays the Apple Music song and listens to it. Recognised words are stamped on the capture clock; the player
    /// clock is sampled against that clock while playing, and the median difference maps every word onto song time.
    func listen() {
        guard let duration = appleMusicDuration else { return }
        phase = .listening; heardCount = 0; message = "Starting…"
        listenEnd = duration
        let lines = lines, keepExisting = keepExisting, offset = offset, locale = locale, hints = hints
        let startAt = fromStart ? 0 : playback.time
        let previousRate = playback.rate
        let capture = SystemAudioCapture()
        self.capture = capture
        task = Task {
            var deltas: [Double] = []
            defer { playback.pause(); playback.rate = previousRate; self.capture = nil }
            do {
                try await capture.start()
                let recognition = Task {
                    try await AutoTiming.transcribeLive(capture, locale: locale, hints: hints) { _, text in
                        Task { @MainActor in message = text }
                    } heard: { count in
                        Task { @MainActor in heardCount = count }
                    }
                }
                playback.rate = 1
                playback.seek(to: startAt)
                try await playback.play()
                message = "Listening to Apple Music…"
                // Sample the clocks and stop at the end of the song (or when playback stops).
                let began = Date()
                while !Task.isCancelled {
                    try? await Task.sleep(for: .milliseconds(200))
                    if playback.isPlaying {
                        deltas.append(playback.time - SystemAudioCapture.hostNow)
                        if playback.time >= duration - 0.3 { break }
                    } else if Date().timeIntervalSince(began) > 3 {
                        break
                    }
                    if recognition.isCancelled { break }
                }
                await capture.stop()
                playback.pause()
                message = "Matching words to the lyrics…"
                let heard = try await withTaskCancellationHandler { try await recognition.value } onCancel: { recognition.cancel() }
                guard !Task.isCancelled else { return }
                deltas.sort()
                let delta = deltas.isEmpty ? 0 : deltas[deltas.count / 2]
                let songWords = heard.map { RecognizedWord(text: $0.text, start: $0.start + delta, end: $0.end + delta) }
                let result = await Task.detached(priority: .userInitiated) {
                    AutoTiming.align(lines: lines, recognized: songWords, keepExisting: keepExisting, offset: offset)
                }.value
                guard !Task.isCancelled else { return }
                phase = .done(result)
            } catch is CancellationError {
                await capture.stop()
            } catch {
                await capture.stop()
                if !Task.isCancelled { phase = .failed(error.localizedDescription) }
            }
        }
    }

    func run() {
        guard let file else { return }
        phase = .running; progress = 0; message = "Preparing…"
        let lines = lines, keepExisting = keepExisting, offset = offset, locale = locale, hints = hints
        task = Task {
            let scoped = file.startAccessingSecurityScopedResource()
            defer { if scoped { file.stopAccessingSecurityScopedResource() } }
            do {
                let heard = try await AutoTiming.transcribe(url: file, locale: locale, hints: hints) { value, text in
                    Task { @MainActor in progress = value; message = text }
                }
                message = "Matching words to the lyrics…"
                let result = await Task.detached(priority: .userInitiated) {
                    AutoTiming.align(lines: lines, recognized: heard, keepExisting: keepExisting, offset: offset)
                }.value
                guard !Task.isCancelled else { return }
                phase = .done(result)
            } catch is CancellationError {
            } catch {
                if !Task.isCancelled { phase = .failed(error.localizedDescription) }
            }
        }
    }
}
