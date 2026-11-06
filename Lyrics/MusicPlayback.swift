import Foundation
@preconcurrency import MusicKit

enum MusicPlaybackError: LocalizedError {
    case notAuthorized, noSubscription, unavailable

    var errorDescription: String? {
        switch self {
        case .notAuthorized: "Lyric Studio needs access to Apple Music. Allow it in System Settings › Privacy & Security › Media & Apple Music."
        case .noSubscription: "Playing full songs needs an active Apple Music subscription on this Mac."
        case .unavailable: "This song is no longer available in the Apple Music catalog. Choose another recording."
        }
    }
}

/// Plays Apple Music catalog songs inside the app with MusicKit's application player.
@MainActor @Observable final class MusicPlayback {
    static let shared = MusicPlayback()

    private(set) var loadedID: String?
    private(set) var loading = false
    /// Playback speed; slower speeds make word timing easier.
    var rate: Float = 1 { didSet { if isPlaying { player.state.playbackRate = rate } } }

    @ObservationIgnored private var lineTask: Task<Void, Never>?

    private var player: ApplicationMusicPlayer { ApplicationMusicPlayer.shared }

    /// Smoothed position and when it was taken, plus the last raw player reading, used to fill in
    /// between the player's coarse clock updates.
    @ObservationIgnored private var anchor: (position: Double, at: Date)?
    @ObservationIgnored private var lastRaw: Double?
    @ObservationIgnored private var lastReported: Double = 0

    /// Current position in seconds. Not observable; read it from a `TimelineView`.
    /// MusicKit's `playbackTime` only advances in steps, so between steps the position is extrapolated
    /// from the wall clock at the playback rate, which keeps word highlights and timed presses in sync.
    var time: Double {
        let raw = player.playbackTime
        guard isPlaying else { resetClock(raw); return raw }
        let now = Date()
        let speed = Double(player.state.playbackRate > 0 ? player.state.playbackRate : rate)
        var estimate = raw
        if let anchor, let lastRaw {
            let predicted = anchor.position + now.timeIntervalSince(anchor.at) * speed
            if raw == lastRaw {
                // No new reading yet: extrapolate, but never more than a second past the player.
                estimate = min(predicted, raw + 1)
            } else if abs(raw - predicted) < 0.3 {
                // A fresh reading that agrees: stay smooth and ease toward the player.
                estimate = predicted + (raw - predicted) * 0.2
                self.anchor = (estimate, now)
            } else {
                // Seek or large drift: jump to the player.
                self.anchor = (raw, now)
            }
        } else {
            anchor = (raw, now)
        }
        lastRaw = raw
        // Don't wobble backwards by a hair; real seeks reset the clock.
        if estimate < lastReported, lastReported - estimate < 0.3 { estimate = lastReported }
        lastReported = estimate
        return estimate
    }

    private func resetClock(_ position: Double) {
        anchor = nil
        lastRaw = nil
        lastReported = position
    }

    var isPlaying: Bool { player.state.playbackStatus == .playing }

    func authorize() async throws {
        var status = MusicAuthorization.currentStatus
        if status == .notDetermined { status = await MusicAuthorization.request() }
        guard status == .authorized else { throw MusicPlaybackError.notAuthorized }
    }

    func search(_ term: String) async throws -> [AppleMusicTrack] {
        try await authorize()
        var request = MusicCatalogSearchRequest(term: term, types: [MusicKit.Song.self])
        request.limit = 25
        return try await request.response().songs.map(AppleMusicTrack.init)
    }

    /// Queues the song so it is ready to play. Does nothing if it is already loaded.
    func load(_ track: AppleMusicTrack) async throws {
        guard loadedID != track.id, !loading else { return }
        loading = true
        defer { loading = false }
        try await authorize()
        guard try await MusicSubscription.current.canPlayCatalogContent else { throw MusicPlaybackError.noSubscription }
        let request = MusicCatalogResourceRequest<MusicKit.Song>(matching: \.id, equalTo: MusicItemID(track.id))
        guard let song = try await request.response().items.first else { throw MusicPlaybackError.unavailable }
        pause()
        resetClock(0)
        player.queue = [song]
        try await player.prepareToPlay()
        loadedID = track.id
    }

    func play() async throws {
        try await player.play()
        if rate != 1 { player.state.playbackRate = rate }
    }

    /// Audition the resolved word interval, independent of the presenting view.
    func playLine(_ words: [TimedWord]) async throws {
        let ranges = TimedWord.resolve(words).compactMap { $0 }
        guard let start = ranges.map(\.lowerBound).min(),
              let end = ranges.map(\.upperBound).max(), end > start else { return }
        pause()
        seek(to: start)
        try await play()
        lineTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                if self.time >= end { self.pause(); return }
                do { try await Task.sleep(for: .milliseconds(20)) } catch { return }
            }
        }
    }

    func pause() { lineTask?.cancel(); lineTask = nil; if isPlaying { player.pause() }; resetClock(player.playbackTime) }

    func toggle() async throws { if isPlaying { pause() } else { try await play() } }

    func seek(to seconds: Double) {
        lineTask?.cancel(); lineTask = nil
        player.playbackTime = max(0, seconds)
        resetClock(max(0, seconds))
    }
}

extension AppleMusicTrack {
    init(_ song: MusicKit.Song) {
        self.init(id: song.id.rawValue, title: song.title, artist: song.artistName, album: song.albumTitle,
                  artworkURL: song.artwork?.url(width: 400, height: 400), duration: song.duration, url: song.url)
    }
}
