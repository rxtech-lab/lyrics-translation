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

    /// Smoothed position and when it was taken, the last raw player reading, and how far the smoothed
    /// clock still has to catch up to (or fall back toward) the player.
    @ObservationIgnored private var anchor: (position: Double, at: Date)?
    @ObservationIgnored private var lastRaw: Double?
    @ObservationIgnored private var pendingError: Double = 0

    /// Current position in seconds. Not observable; read it from a `TimelineView`.
    /// MusicKit's `playbackTime` only advances in steps, so between steps the position is extrapolated
    /// from the wall clock at the playback rate. Disagreements with the player are absorbed by briefly
    /// running a little faster or slower (never backwards or frozen), so the playhead moves smoothly.
    var time: Double {
        let raw = player.playbackTime
        guard isPlaying else { resetClock(raw); return raw }
        let now = Date()
        let speed = Double(player.state.playbackRate > 0 ? player.state.playbackRate : rate)
        guard let anchor else {
            self.anchor = (raw, now)
            lastRaw = raw
            pendingError = 0
            return raw
        }
        let elapsed = max(0, now.timeIntervalSince(anchor.at))
        let predicted = anchor.position + elapsed * speed
        if raw != lastRaw {
            lastRaw = raw
            let error = raw - predicted
            if abs(error) > 0.5 {
                // Seek or large drift: jump to the player.
                self.anchor = (raw, now)
                pendingError = 0
                return raw
            }
            pendingError = error
        }
        // Slew toward the player at up to ±40% of the playback speed so the clock stays continuous.
        let limit = elapsed * speed * 0.4
        let step = min(max(pendingError, -limit), limit)
        pendingError -= step
        // If the player hasn't reported progress (e.g. still buffering), don't run far ahead of it.
        let position = min(predicted + step, raw + 1)
        self.anchor = (max(position, anchor.position), now)
        return self.anchor!.position
    }

    private func resetClock(_ position: Double) {
        anchor = nil
        lastRaw = nil
        pendingError = 0
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
