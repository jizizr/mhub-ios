import AVFoundation
import MediaPlayer
import Network
import MHubKit
import Observation
import SwiftUI
import UIKit

/// Owns the play queue and the system player.
///
/// The queue logic lives in `PlayQueue` (shared behaviour with Android). This
/// class turns queue positions into `AVPlayerItem`s, keeps the next song
/// queued in `AVQueuePlayer` once the current one is fully cached (gapless and
/// lock-screen safe), and publishes Now Playing info and remote commands.
@MainActor @Observable
final class PlayerController {
    enum Phase: Equatable {
        case idle, loading, playing, paused
        case failed(String)
    }

    enum LyricsState: Equatable { case idle, loading, loaded, failed }

    private(set) var queue = PlayQueue()
    private(set) var phase: Phase = .idle
    private(set) var elapsed: Double = 0
    private(set) var duration: Double = 0
    private(set) var playingQuality: Quality?
    private(set) var lyrics: Lyrics = .empty
    private(set) var lyricsState: LyricsState = .idle
    private(set) var artwork: UIImage?
    private(set) var palette: [Color] = []
    /// The last AutoPlay request, for the queue's notice (web `autoplayState`).
    enum AutoplayStatus { case idle, loading, ready, empty, unsupported, error }
    private(set) var autoplayStatus: AutoplayStatus = .idle
    /// Where the queue came from (docs/design.md「播放队列」).
    private(set) var source: QueueSource?
    var showsFullPlayer = false

    var current: Track? { queue.current }
    /// What the play button shows: playing, or about to play.
    var isPlaying: Bool { phase == .playing || (phase == .loading && wantsPlay) }
    /// Exact player time, read every frame by the lyrics view.
    var currentTime: Double {
        let seconds = player.currentTime().seconds
        return seconds.isFinite ? seconds : elapsed
    }

    private let app: AppModel
    private let cache = AudioCache.shared
    private let player = AVQueuePlayer()
    private var generation = 0
    private var wantsPlay = false
    private var loadTask: Task<Void, Never>?
    private var prefetchTask: Task<Void, Never>?
    /// Identifies the running prefetch, so a cancelled one never clears its successor.
    private var prefetchSerial = 0
    private var lyricsTask: Task<Void, Never>?
    private var artworkTask: Task<Void, Never>?
    private var autoplayTask: Task<Int, Never>?
    private var autoplayStation: String?
    private var autoplayPlayed: [String] = []
    private var entries: [ObjectIdentifier: Entry] = [:]
    private var currentItem: AVPlayerItem?
    private var prefetched: (trackID: String, item: AVPlayerItem)?
    private var restorePosition: Double?
    private var lyricsMemory: [String: Lyrics] = [:]
    private var observers: [NSObjectProtocol] = []
    private var kvo: [NSKeyValueObservation] = []
    private var timeObserver: Any?
    private var persistTask: Task<Void, Never>?

    private struct Entry {
        var track: Track
        var quality: Quality
        var loader: CachingAssetLoader?
        var cached: Bool
    }

    /// Songs the server reported as unplayable, for this run (web `unplayableTracks`).
    @ObservationIgnored private var unplayable = Set<String>()
    @ObservationIgnored private var consecutiveFailures = 0
    private static let maxConsecutiveFailures = 5
    /// Low Data Mode: no next-song download (web: `saveData`).
    @ObservationIgnored private let pathMonitor = NWPathMonitor()
    @ObservationIgnored private var savingData = false

    init(app: AppModel) {
        self.app = app
        pathMonitor.pathUpdateHandler = { [weak self] path in
            let constrained = path.isConstrained
            Task { @MainActor in self?.savingData = constrained }
        }
        pathMonitor.start(queue: DispatchQueue(label: "mhub.path"))
        player.automaticallyWaitsToMinimizeStalling = true
        // Automated tests run silently (`MHUB_MUTE=1` in the launch environment).
        player.isMuted = ProcessInfo.processInfo.environment["MHUB_MUTE"] == "1"
        restore()
        configureSession()
        observePlayer()
        configureRemoteCommands()
        Task { await cache.setLimit(app.settings.cacheLimit) }
        if let track = current { loadSideContent(for: track) }
    }

    // MARK: Queue actions (same names and semantics as the web player)

    /// Tapping a song: it plays right after the current one.
    func playNow(_ track: Track) {
        if track.id == current?.id, currentItem != nil {
            if !isPlaying { play() }
            return
        }
        queue.playNow(track)
        resetAutoplayStation()
        load()
    }

    /// "播放" / "随机播放" on a list: replaces the queue.
    func play(_ tracks: [Track], startAt index: Int = 0, shuffle: Bool? = nil, source: QueueSource? = nil) {
        guard !tracks.isEmpty else { return }
        queue.replace(with: tracks, startAt: index, shuffle: shuffle)
        self.source = source
        resetAutoplayStation()
        load()
    }

    func playNext(_ tracks: [Track]) {
        let title = tracks.first?.title ?? ""
        let hadCurrent = current != nil
        let count = queue.playNext(tracks)
        queueChanged()
        if tracks.count == 1 {
            app.show(count == 0 ? Strings.nowPlayingAlready(title) : hadCurrent ? Strings.queuedNext(title) : Strings.queuedFirst(title))
        }
    }

    func append(_ tracks: [Track]) {
        let added = queue.append(tracks)
        queueChanged()
        if tracks.count == 1, let title = tracks.first?.title {
            app.show(added > 0 ? Strings.queuedAtEnd(title) : Strings.alreadyQueued(title))
        }
    }

    func select(_ index: Int) {
        queue.select(index)
        load()
    }

    func remove(at index: Int) {
        let wasCurrent = index == queue.index
        queue.remove(at: index)
        if wasCurrent { queue.isEmpty ? stop() : load() } else { queueChanged() }
    }

    func move(from: Int, to: Int) {
        queue.move(from: from, to: to)
        queueChanged()
    }

    func clearQueue() {
        queue.clear()
        source = nil
        autoplayStatus = .idle
        stop()
    }

    // MARK: Transport

    func togglePlay() { isPlaying ? pause() : play() }

    func play() {
        wantsPlay = true
        guard current != nil else { return }
        if currentItem == nil {
            load(seek: restorePosition)
            return
        }
        activateSession()
        player.play()
    }

    func pause() {
        wantsPlay = false
        player.pause()
        if phase == .loading { phase = .paused }
        persistSoon()
    }

    func next() {
        advance(manual: true)
    }

    /// Restarts the song after three seconds, otherwise goes back one.
    func previous() {
        if elapsed > 3 {
            seek(to: 0)
            return
        }
        guard queue.previous() != nil else { return }
        load()
    }

    /// The player's own volume; used only where system volume is unavailable.
    func setAppVolume(_ volume: Float) {
        player.volume = volume
    }

    func seek(to seconds: Double) {
        elapsed = seconds
        if currentItem == nil {
            restorePosition = seconds
            return
        }
        player.seek(to: CMTime(seconds: seconds, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero) { @Sendable [weak self] _ in
            Task { @MainActor in self?.updateNowPlaying() }
        }
    }

    /// Replays the current song in another quality, keeping the position.
    func reload(in quality: Quality) {
        app.settings.quality = quality
        load(seek: elapsed)
    }

    // MARK: Modes

    func cycleRepeat() {
        queue.cycleRepeat()
        queueChanged()
    }

    func toggleShuffle() {
        queue.toggleShuffle()
        queueChanged()
    }

    func setAutoplay(_ enabled: Bool) {
        queue.setAutoplay(enabled)
        resetAutoplayStation()
        queueChanged()
        if enabled { Task { _ = await fetchRecommendations(force: false) } } else { autoplayStatus = .idle }
    }

    /// The queue notice's「重试」.
    func retryAutoplay() { Task { _ = await fetchRecommendations(force: true) } }

    // MARK: Loading

    private func load(seek: Double? = nil) {
        generation += 1
        let generation = generation
        loadTask?.cancel()
        dropPrefetched()
        for entry in entries.values { entry.loader?.cancel() }
        entries.removeAll()
        player.removeAllItems()
        currentItem = nil
        restorePosition = nil
        wantsPlay = true
        guard let track = current else {
            phase = .idle
            return
        }
        let quality = app.settings.quality
        phase = .loading
        elapsed = seek ?? 0
        duration = Double(track.durationMs ?? 0) / 1000
        playingQuality = quality
        loadSideContent(for: track)
        updateNowPlaying()
        persistSoon()
        loadTask = Task {
            do {
                // A song the listener asked for waits out the server's quota and
                // plays when allowed; it never fails over to the next song.
                let policy = RateLimitPolicy.playback { ms in
                    Task { @MainActor [weak self] in
                        guard let self, generation == self.generation else { return }
                        app.show(Strings.playbackRateLimited(RateLimit.seconds(ms)))
                    }
                }
                let (item, entry) = try await makeItem(for: track, quality: quality, rateLimit: policy)
                guard generation == self.generation else { entry.loader?.cancel(); return }
                entries[ObjectIdentifier(item)] = entry
                currentItem = item
                player.insert(item, after: nil)
                if let seek, seek > 0 {
                    await player.seek(to: CMTime(seconds: seek, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
                }
                if wantsPlay {
                    activateSession()
                    player.play()
                } else {
                    phase = .paused
                }
                trackBecameCurrent(entry)
            } catch is CancellationError {
            } catch APIError.unplayable {
                guard generation == self.generation else { return }
                // Nothing can play this song: move on as if it were not queued.
                unplayable.insert(track.id)
                app.show(Strings.unplayableSkipped(track.title))
                skipOnFailure()
            } catch {
                guard generation == self.generation else { return }
                let message = error.localizedDescription
                phase = .failed(message)
                app.show(message)
            }
        }
    }

    /// Steps past a song that cannot play; after five in a row (or the whole queue) it stops.
    private func skipOnFailure() {
        consecutiveFailures += 1
        if consecutiveFailures >= Self.maxConsecutiveFailures || consecutiveFailures >= queue.items.count {
            consecutiveFailures = 0
            wantsPlay = false
            phase = .paused
            updateNowPlaying()
            return
        }
        advance(manual: true)
    }

    /// The song a natural end leads to, stepping over songs known to be unplayable.
    private func playableNextIndex() -> Int? {
        guard queue.repeatMode != .one else { return nil }
        var probe = queue
        for _ in queue.items.indices {
            guard let next = probe.naturalNextIndex, next != queue.index else { return nil }
            if !unplayable.contains(queue.items[next].id) { return next }
            probe.select(next)
        }
        return nil
    }

    /// A cached file plays directly; otherwise the server prepares the song
    /// and `CachingAssetLoader` streams and caches it in one pass.
    private func makeItem(for track: Track, quality: Quality, rateLimit: RateLimitPolicy) async throws -> (AVPlayerItem, Entry) {
        let key = track.cacheKey(quality)
        if let file = await cache.file(for: key) {
            return (AVPlayerItem(url: file), Entry(track: track, quality: quality, loader: nil, cached: true))
        }
        guard let client = app.client else { throw APIError.invalidServer }
        let (task, url) = try await client.preparePlayback(track, quality: quality, rateLimit: rateLimit)
        try Task.checkCancellation()
        let enriched = track.enriched(by: task, server: client.server)
        if enriched != track {
            queue.update(enriched)
            if enriched.cover != track.cover, current?.id == track.id { loadArtwork(for: enriched) }
        }
        let loader = CachingAssetLoader(remote: url, key: key, track: enriched, quality: quality, cache: cache) { [weak self] in
            Task { @MainActor in self?.didCache(key) }
        }
        let item = AVPlayerItem(asset: loader.asset)
        item.preferredForwardBufferDuration = 0
        return (item, Entry(track: enriched, quality: quality, loader: loader, cached: false))
    }

    private func trackBecameCurrent(_ entry: Entry) {
        consecutiveFailures = 0
        app.recordRecent(entry.track)
        if entry.track.isRecommendation { autoplayPlayed.append(entry.track.sourceID) }
        updateNowPlaying()
        persistSoon()
        Task { _ = await fetchRecommendations(force: false) }
        if entry.cached { schedulePrefetch() }
    }

    /// The prefetched song usually finishes caching while it is still queued:
    /// remember that, so once it plays the song after it is prefetched in turn
    /// (otherwise the next hand-off falls back to a cold load and a silent gap).
    private func didCache(_ key: String) {
        for (id, entry) in entries where entry.track.cacheKey(entry.quality) == key {
            entries[id]?.cached = true
        }
        if let item = currentItem, entries[ObjectIdentifier(item)]?.cached == true { schedulePrefetch() }
    }

    // MARK: Next song

    /// The next song is resolved only after the current one is fully cached,
    /// then queued in AVQueuePlayer so the system plays it without a gap.
    private func schedulePrefetch() {
        guard prefetched == nil, prefetchTask == nil, !savingData,
              let nextIndex = playableNextIndex(), let item = currentItem else { return }
        let track = queue.items[nextIndex]
        let quality = app.settings.quality
        let generation = generation
        prefetchSerial += 1
        let serial = prefetchSerial
        prefetchTask = Task {
            defer { if serial == prefetchSerial { prefetchTask = nil } }
            let stillNext = { [unowned self] in
                generation == self.generation && currentItem === item
                    && playableNextIndex().map({ queue.items[$0].id }) == track.id
            }
            var attempt = 0
            while !Task.isCancelled {
                do {
                    // Over quota a prefetch gives up at once, silently.
                    let (next, entry) = try await makeItem(for: track, quality: quality, rateLimit: .prefetch)
                    guard stillNext() else {
                        entry.loader?.cancel()
                        return
                    }
                    entries[ObjectIdentifier(next)] = entry
                    prefetched = (track.id, next)
                    if player.canInsert(next, after: item) { player.insert(next, after: item) }
                    return
                } catch is CancellationError {
                    return
                } catch APIError.unplayable {
                    // The queue now steps over it; warm the song after it instead.
                    unplayable.insert(track.id)
                    guard generation == self.generation, currentItem === item else { return }
                    prefetchSerial += 1
                    prefetchTask = nil
                    schedulePrefetch()
                    return
                } catch {
                    // Retry with backoff, never sooner than the server's Retry-After.
                    var retryAfter = 0
                    if case let APIError.rateLimited(ms, _) = error { retryAfter = ms }
                    let delay = RateLimit.prefetchDelayMs(attempt: attempt, retryAfterMs: retryAfter)
                    attempt += 1
                    try? await Task.sleep(for: .milliseconds(delay))
                    guard stillNext() else { return }
                }
            }
        }
    }

    private func dropPrefetched() {
        prefetchTask?.cancel()
        prefetchTask = nil
        guard let prefetched else { return }
        player.remove(prefetched.item)
        entries.removeValue(forKey: ObjectIdentifier(prefetched.item))?.loader?.cancel()
        self.prefetched = nil
    }

    /// After a queue edit the prefetched song may no longer be next.
    private func queueChanged() {
        persistSoon()
        let nextID = playableNextIndex().map { queue.items[$0].id }
        if let prefetched, prefetched.trackID != nextID { dropPrefetched() }
        if let item = currentItem, entries[ObjectIdentifier(item)]?.cached == true { schedulePrefetch() }
        Task { _ = await fetchRecommendations(force: false) }
    }

    /// AVQueuePlayer moved on to the prefetched item by itself.
    private func playerAdvanced(to item: AVPlayerItem?) {
        guard let item, item !== currentItem, let prefetched, prefetched.item === item,
              let position = queue.items.firstIndex(where: { $0.id == prefetched.trackID }) else { return }
        if let old = currentItem { entries.removeValue(forKey: ObjectIdentifier(old))?.loader?.cancel() }
        self.prefetched = nil
        queue.select(position)
        currentItem = item
        guard let entry = entries[ObjectIdentifier(item)] else { return }
        elapsed = 0
        duration = Double(entry.track.durationMs ?? 0) / 1000
        playingQuality = entry.quality
        loadSideContent(for: entry.track)
        trackBecameCurrent(entry)
    }

    private func itemEnded(_ item: AVPlayerItem) {
        guard item === currentItem, prefetched == nil else { return }
        advance(manual: false)
    }

    private func advance(manual: Bool) {
        var step = queue.next(manual: manual)
        // Songs already known to be unplayable are stepped over like absent ones.
        for _ in queue.items.indices {
            guard case .index = step, let current = queue.current, unplayable.contains(current.id) else { break }
            step = queue.next(manual: true)
        }
        switch step {
        case .index:
            load()
        case .ended:
            wantsPlay = false
            phase = .paused
            player.pause()
            updateNowPlaying()
        case .needsRecommendations:
            phase = .loading
            Task {
                let added = await fetchRecommendations(force: true)
                if added > 0, case .index = queue.next(manual: manual) {
                    load()
                } else {
                    phase = .paused
                    wantsPlay = false
                    app.show(Strings.noMoreRecommendations)
                }
            }
        }
    }

    private func stop() {
        generation += 1
        loadTask?.cancel()
        dropPrefetched()
        for entry in entries.values { entry.loader?.cancel() }
        entries.removeAll()
        player.removeAllItems()
        currentItem = nil
        wantsPlay = false
        phase = .idle
        elapsed = 0
        duration = 0
        lyrics = .empty
        artwork = nil
        palette = []
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
        persistSoon()
    }

    // MARK: AutoPlay

    private func resetAutoplayStation() {
        autoplayStation = nil
        autoplayTask = nil
    }

    /// Requests an Apple Music AutoPlay batch when two or fewer songs remain.
    private func fetchRecommendations(force: Bool) async -> Int {
        guard queue.autoplay, let seed = current, let client = app.client else { return 0 }
        guard PlatformInfo.autoplayPlatforms.contains(seed.platform) else {
            autoplayStatus = .unsupported
            return 0
        }
        guard force || queue.upcoming.count <= 2 else { return 0 }
        if let autoplayTask { return await autoplayTask.value }
        let exclude = queue.items.filter { $0.platform == seed.platform }.map(\.sourceID) + autoplayPlayed.suffix(200)
        let seeds = queue.autoplaySeeds()
        let station = autoplayStation
        autoplayStatus = .loading
        let task = Task<Int, Never> { [weak self] in
            guard let result = try? await client.continuation(platform: seed.platform, seedID: seed.sourceID, seedIDs: seeds,
                                                              station: station, exclude: exclude) else { return -1 }
            guard let self, self.queue.autoplay, self.current?.id == seed.id else { return 0 }
            if let next = result.station { self.autoplayStation = next }
            let added = self.queue.appendRecommendations(result.tracks.filter { $0.platform == seed.platform }.map(\.track))
            if added > 0 { self.queueChanged() }
            return added
        }
        autoplayTask = task
        let added = await task.value
        autoplayTask = nil
        autoplayStatus = added < 0 ? .error : added > 0 ? .ready : queue.autoplay ? .empty : .idle
        return max(added, 0)
    }

    // MARK: Lyrics and artwork

    private func loadSideContent(for track: Track) {
        loadLyrics(for: track)
        loadArtwork(for: track)
    }

    private func loadLyrics(for track: Track) {
        lyricsTask?.cancel()
        if let cached = lyricsMemory[track.id] {
            lyrics = cached
            lyricsState = .loaded
            return
        }
        lyrics = .empty
        lyricsState = .loading
        guard let client = app.client else { lyricsState = .failed; return }
        lyricsTask = Task {
            do {
                let built = Lyrics.build(from: try await client.lyrics(for: track))
                guard current?.id == track.id else { return }
                if lyricsMemory.count > 60 { lyricsMemory.removeAll() }
                lyricsMemory[track.id] = built
                lyrics = built
                lyricsState = .loaded
            } catch is CancellationError {
            } catch {
                if current?.id == track.id { lyricsState = .failed }
            }
        }
    }

    private func loadArtwork(for track: Track) {
        artworkTask?.cancel()
        guard let url = track.coverURL else {
            artwork = nil
            palette = []
            return
        }
        artworkTask = Task {
            guard let (data, _) = try? await URLSession.shared.data(from: url), let image = UIImage(data: data) else { return }
            let colors = await Task.detached(priority: .utility) { ArtworkPalette.colors(of: image) }.value
            guard current?.id == track.id else { return }
            withAnimation(.smooth(duration: 0.8)) {
                artwork = image
                palette = colors
            }
            updateNowPlaying()
        }
    }

    // MARK: System integration

    private func configureSession() {
        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .default, policy: .longFormAudio)
        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: AVAudioSession.interruptionNotification, object: nil, queue: .main) { [weak self] note in
            let raw = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt
            let options = note.userInfo?[AVAudioSessionInterruptionOptionKey] as? UInt ?? 0
            MainActor.assumeIsolated {
                guard let self, let raw, let type = AVAudioSession.InterruptionType(rawValue: raw) else { return }
                if type == .ended, AVAudioSession.InterruptionOptions(rawValue: options).contains(.shouldResume), self.wantsPlay {
                    self.player.play()
                }
            }
        })
        observers.append(center.addObserver(forName: AVPlayerItem.didPlayToEndTimeNotification, object: nil, queue: .main) { [weak self] note in
            guard let item = note.object as? AVPlayerItem else { return }
            MainActor.assumeIsolated { self?.itemEnded(item) }
        })
        observers.append(center.addObserver(forName: AVPlayerItem.failedToPlayToEndTimeNotification, object: nil, queue: .main) { [weak self] note in
            guard let item = note.object as? AVPlayerItem else { return }
            MainActor.assumeIsolated {
                guard let self, item === self.currentItem else { return }
                self.phase = .failed(item.error?.localizedDescription ?? Strings.preparing)
            }
        })
        observers.append(center.addObserver(forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.persistNow() }
        })
    }

    private func activateSession() {
        try? AVAudioSession.sharedInstance().setActive(true)
    }

    private func observePlayer() {
        kvo.append(player.observe(\.timeControlStatus, options: [.new]) { @Sendable [weak self] player, _ in
            let status = player.timeControlStatus
            Task { @MainActor in self?.timeControlChanged(status) }
        })
        kvo.append(player.observe(\.currentItem, options: [.new]) { @Sendable [weak self] player, _ in
            let item = player.currentItem
            Task { @MainActor in self?.playerAdvanced(to: item) }
        })
        timeObserver = player.addPeriodicTimeObserver(forInterval: CMTime(value: 1, timescale: 4), queue: .main) { [weak self] time in
            MainActor.assumeIsolated { self?.tick(time) }
        }
    }

    private func timeControlChanged(_ status: AVPlayer.TimeControlStatus) {
        guard currentItem != nil else { return }
        switch status {
        case .playing: phase = .playing
        case .waitingToPlayAtSpecifiedRate: if wantsPlay { phase = .loading }
        case .paused: if case .failed = phase {} else { phase = .paused }
        @unknown default: break
        }
        updateNowPlaying()
    }

    private func tick(_ time: CMTime) {
        guard currentItem != nil else { return }
        if time.seconds.isFinite { elapsed = time.seconds }
        if let item = currentItem, item.duration.seconds.isFinite, item.duration.seconds > 0 {
            duration = item.duration.seconds
        }
    }

    private func configureRemoteCommands() {
        let center = MPRemoteCommandCenter.shared()
        center.playCommand.addTarget { [weak self] _ in MainActor.assumeIsolated { self?.play() }; return .success }
        center.pauseCommand.addTarget { [weak self] _ in MainActor.assumeIsolated { self?.pause() }; return .success }
        center.togglePlayPauseCommand.addTarget { [weak self] _ in MainActor.assumeIsolated { self?.togglePlay() }; return .success }
        center.nextTrackCommand.addTarget { [weak self] _ in MainActor.assumeIsolated { self?.next() }; return .success }
        center.previousTrackCommand.addTarget { [weak self] _ in MainActor.assumeIsolated { self?.previous() }; return .success }
        center.changePlaybackPositionCommand.addTarget { [weak self] event in
            guard let event = event as? MPChangePlaybackPositionCommandEvent else { return .commandFailed }
            MainActor.assumeIsolated { self?.seek(to: event.positionTime) }
            return .success
        }
    }

    private func updateNowPlaying() {
        guard let track = current else {
            MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
            return
        }
        var info: [String: Any] = [
            MPMediaItemPropertyTitle: track.title,
            MPMediaItemPropertyArtist: track.artist,
            MPMediaItemPropertyAlbumTitle: track.album,
            MPMediaItemPropertyPlaybackDuration: duration,
            MPNowPlayingInfoPropertyElapsedPlaybackTime: currentTime,
            MPNowPlayingInfoPropertyPlaybackRate: phase == .playing ? 1.0 : 0.0,
            MPNowPlayingInfoPropertyMediaType: MPNowPlayingInfoMediaType.audio.rawValue,
        ]
        if let artwork { info[MPMediaItemPropertyArtwork] = Self.nowPlayingArtwork(artwork) }
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
    }

    /// MediaPlayer asks for the image on its own queue, so the handler must
    /// not inherit main-actor isolation.
    nonisolated private static func nowPlayingArtwork(_ image: UIImage) -> MPMediaItemArtwork {
        MPMediaItemArtwork(boundsSize: image.size) { @Sendable _ in image }
    }

    // MARK: Persistence

    private struct Saved: Codable {
        var queue: PlayQueue
        var position: Double
        var source: QueueSource?
    }

    private static var stateFile: URL { URL.applicationSupportDirectory.appendingPathComponent("playback.json") }

    private func restore() {
        guard let data = try? Data(contentsOf: Self.stateFile),
              let saved = try? JSONDecoder().decode(Saved.self, from: data) else { return }
        queue = saved.queue
        source = saved.source
        restorePosition = saved.position
        elapsed = saved.position
        duration = Double(queue.current?.durationMs ?? 0) / 1000
        phase = queue.current == nil ? .idle : .paused
        // The quality the restored song will load in.
        if queue.current != nil { playingQuality = app.settings.quality }
    }

    private func persistSoon() {
        persistTask?.cancel()
        persistTask = Task {
            try? await Task.sleep(for: .milliseconds(400))
            guard !Task.isCancelled else { return }
            persistNow()
        }
    }

    private func persistNow() {
        let saved = Saved(queue: queue, position: elapsed, source: source)
        guard let data = try? JSONEncoder().encode(saved) else { return }
        try? FileManager.default.createDirectory(at: URL.applicationSupportDirectory, withIntermediateDirectories: true)
        try? data.write(to: Self.stateFile, options: .atomic)
    }
}
