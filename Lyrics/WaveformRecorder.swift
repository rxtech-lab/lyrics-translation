import AVFoundation
import Foundation

/// Builds a waveform for the loaded Apple Music song while it plays.
///
/// MusicKit never hands the app the song's samples, so the audio the Mac is playing is recorded with
/// `SystemAudioCapture` and its loudness is placed on the song's timeline. Only the parts of the song that
/// have played appear; the result is cached per song so each part only has to be heard once.
@MainActor @Observable final class WaveformRecorder {
    static let shared = WaveformRecorder()

    /// Loudness bins per second of song time.
    static let binsPerSecond: Double = 100
    /// Marks a bin that hasn't been heard yet.
    static let unheard: Float = -1

    /// Changes whenever the stored waveform changes, at most a few times a second; views read it to redraw.
    private(set) var revision = 0
    private(set) var listening = false
    /// Why the waveform can't be recorded, if it can't.
    private(set) var problem: String?

    /// Peak level (0…1) per bin for each song id.
    @ObservationIgnored private var peaks: [String: [Float]] = [:]
    @ObservationIgnored private var dirtyIDs: Set<String> = []
    @ObservationIgnored private var users = 0
    @ObservationIgnored private var capture: SystemAudioCapture?
    @ObservationIgnored private var captureTask: Task<Void, Never>?
    @ObservationIgnored private var clockTask: Task<Void, Never>?
    @ObservationIgnored private var lastSave = Date()
    @ObservationIgnored private var lastPublish = Date.distantPast
    @ObservationIgnored private var pendingPublish = false

    /// Samples of (capture clock, song time, speed) taken while playing; a `nil` song time marks a pause.
    /// Captured audio is placed on the song timeline from the most recent sample before it.
    private struct Anchor { var host: Double; var song: Double?; var rate: Double }
    @ObservationIgnored private var anchors: [Anchor] = []
    @ObservationIgnored private var anchorID: String?

    /// The bin currently being filled; it is written out once audio moves on to another bin.
    @ObservationIgnored private var openBin: (id: String, index: Int, peak: Float)?
    /// How much has been heard since listening started, to notice a silent (blocked) recording.
    @ObservationIgnored private var heardBins = 0
    @ObservationIgnored private var loudest: Float = 0

    private let playback = MusicPlayback.shared

    // MARK: Lifetime

    /// Starts listening while at least one view showing the waveform is open.
    func attach() {
        users += 1
        guard users == 1 else { return }
        clockTask = Task { [weak self] in
            while !Task.isCancelled {
                self?.tick()
                try? await Task.sleep(for: .milliseconds(30))
            }
        }
    }

    func detach() {
        users = max(0, users - 1)
        guard users == 0 else { return }
        clockTask?.cancel(); clockTask = nil
        stopCapture()
        save()
    }

    /// Clears the stored waveform of a song, e.g. if something else was playing while it was recorded.
    func clear(_ id: String) {
        peaks[id] = []
        dirtyIDs.insert(id)
        if openBin?.id == id { openBin = nil }
        save()
        revision += 1
    }

    // MARK: Reading

    /// Loudest heard peak per column for `count` columns spanning `range` (song seconds), or `nil` where unheard.
    func levels(_ id: String, range: ClosedRange<Double>, count: Int) -> [Float?] {
        guard count > 0 else { return [] }
        let bins = stored(id)
        guard !bins.isEmpty else { return Array(repeating: nil, count: count) }
        let span = (range.upperBound - range.lowerBound) / Double(count)
        return (0..<count).map { column in
            let from = Int(((range.lowerBound + Double(column) * span) * Self.binsPerSecond).rounded(.down))
            let to = max(from + 1, Int(((range.lowerBound + Double(column + 1) * span) * Self.binsPerSecond).rounded(.up)))
            let low = max(0, from), high = min(bins.count, to)
            guard low < high else { return nil }
            var best: Float = Self.unheard
            for index in low..<high where bins[index] > best { best = bins[index] }
            return best < 0 ? nil : best
        }
    }

    func hasWaveform(_ id: String) -> Bool { stored(id).contains { $0 >= 0 } }

    // MARK: Clock

    private func tick() {
        guard let id = playback.loadedID else { return }
        if id != anchorID {
            anchors = []
            anchorID = id
            openBin = nil
        }
        if playback.isPlaying {
            if capture == nil && problem == nil { startCapture() }
            anchors.append(Anchor(host: SystemAudioCapture.hostNow, song: playback.time, rate: Double(playback.rate)))
        } else if anchors.last?.song != nil {
            anchors.append(Anchor(host: SystemAudioCapture.hostNow, song: nil, rate: 0))
        }
        // Audio arrives a little after it plays; a couple of seconds of history is plenty.
        if anchors.count > 120 { anchors.removeFirst(anchors.count - 120) }
        if Date().timeIntervalSince(lastSave) > 10 { save() }
        if pendingPublish, Date().timeIntervalSince(lastPublish) > 0.15 { publish() }
    }

    /// Song time that was playing at capture-clock time `host`, or `nil` if the song wasn't playing then.
    private func songTime(at host: Double) -> Double? {
        guard let anchor = anchors.last(where: { $0.host <= host }), let song = anchor.song else { return nil }
        let elapsed = host - anchor.host
        // A gap this long means the clock stopped being sampled; don't guess.
        guard elapsed < 0.5 else { return nil }
        return song + elapsed * max(anchor.rate, 0.1)
    }

    // MARK: Capture

    private func startCapture() {
        let capture = SystemAudioCapture()
        self.capture = capture
        listening = true
        heardBins = 0
        loudest = 0
        captureTask = Task { [weak self] in
            do {
                try await capture.start()
            } catch {
                guard let self else { return }
                self.problem = error.localizedDescription
                self.stopCapture()
                return
            }
            // Measure loudness off the main actor in 5 ms slices, then place the slices on the timeline here.
            let slices = AsyncStream<[(host: Double, peak: Float)]> { continuation in
                let worker = Task.detached(priority: .utility) {
                    for await chunk in capture.audio { continuation.yield(Self.slices(of: chunk)) }
                    continuation.finish()
                }
                continuation.onTermination = { _ in worker.cancel() }
            }
            for await batch in slices {
                guard let self else { return }
                self.place(batch)
            }
        }
    }

    private func stopCapture() {
        captureTask?.cancel(); captureTask = nil
        if let capture { Task { await capture.stop() } }
        capture = nil
        listening = false
        flushOpenBin()
    }

    /// Lets the user try again after granting the recording permission.
    func retry() { problem = nil }

    nonisolated private static func slices(of chunk: CapturedAudio) -> [(host: Double, peak: Float)] {
        let buffer = chunk.buffer
        guard let channels = buffer.floatChannelData else { return [] }
        let frames = Int(buffer.frameLength)
        let rate = buffer.format.sampleRate
        let channelCount = Int(buffer.format.channelCount)
        let size = max(1, Int(rate * 0.005))
        var result: [(host: Double, peak: Float)] = []
        result.reserveCapacity(frames / size + 1)
        var start = 0
        while start < frames {
            let end = min(frames, start + size)
            var peak: Float = 0
            for channel in 0..<channelCount {
                let samples = channels[channel]
                for frame in start..<end { peak = max(peak, abs(samples[frame])) }
            }
            result.append((chunk.hostTime + Double(start) / rate, min(1, peak)))
            start = end
        }
        return result
    }

    private func place(_ batch: [(host: Double, peak: Float)]) {
        guard let id = anchorID, playback.loadedID == id else { return }
        for slice in batch {
            guard let time = songTime(at: slice.host), time >= 0 else { continue }
            let index = Int(time * Self.binsPerSecond)
            if let open = openBin, open.id == id, open.index == index {
                openBin?.peak = max(open.peak, slice.peak)
            } else {
                flushOpenBin()
                openBin = (id, index, slice.peak)
            }
        }
        pendingPublish = true
    }

    private func flushOpenBin() {
        guard let open = openBin else { return }
        openBin = nil
        var bins = stored(open.id)
        if bins.count <= open.index { bins.append(contentsOf: repeatElement(Self.unheard, count: open.index + 1 - bins.count)) }
        bins[open.index] = open.peak
        peaks[open.id] = bins
        dirtyIDs.insert(open.id)
        heardBins += 1
        loudest = max(loudest, open.peak)
        // Eight seconds of playing with nothing audible: macOS is likely blocking the protected stream.
        if heardBins > 800, loudest < 0.0005, problem == nil {
            problem = "Lyric Studio can’t hear the song, so it can’t draw the waveform. The volume may be muted, or macOS may be blocking recording of this Apple Music stream."
            stopCapture()
        }
    }

    private func publish() {
        pendingPublish = false
        lastPublish = Date()
        revision += 1
    }

    // MARK: Storage

    nonisolated private static var folder: URL {
        URL.applicationSupportDirectory.appending(path: "LyricStudio/Waveforms", directoryHint: .isDirectory)
    }

    nonisolated private static func file(_ id: String) -> URL {
        folder.appending(path: id.replacingOccurrences(of: "/", with: "_") + ".waveform")
    }

    private func stored(_ id: String) -> [Float] {
        if let bins = peaks[id] { return bins }
        var bins: [Float] = []
        if let data = try? Data(contentsOf: Self.file(id)) {
            // One byte per bin: 0 = unheard, 1…255 = level.
            bins = data.map { $0 == 0 ? Self.unheard : Float($0 - 1) / 254 }
        }
        peaks[id] = bins
        return bins
    }

    private func save() {
        lastSave = Date()
        guard !dirtyIDs.isEmpty else { return }
        let snapshot = dirtyIDs.compactMap { id in peaks[id].map { (id, $0) } }
        dirtyIDs = []
        Task.detached(priority: .utility) {
            try? FileManager.default.createDirectory(at: Self.folder, withIntermediateDirectories: true)
            for (id, bins) in snapshot {
                let data = Data(bins.map { $0 < 0 ? 0 : UInt8(1 + (min(1, $0) * 254).rounded()) })
                try? data.write(to: Self.file(id), options: .atomic)
            }
        }
    }
}
