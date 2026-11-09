import Foundation
import MHubKit
import Observation
import SwiftUI

enum Appearance: String, CaseIterable, Identifiable {
    case system, light, dark
    var id: String { rawValue }
    var label: String {
        switch self {
        case .system: Strings.appearanceSystem
        case .light: Strings.appearanceLight
        case .dark: Strings.appearanceDark
        }
    }
    var colorScheme: ColorScheme? {
        switch self {
        case .system: nil
        case .light: .light
        case .dark: .dark
        }
    }
}

/// User preferences, stored in UserDefaults. Names match the Android
/// `Settings` keys so both apps describe the same options.
@MainActor @Observable
final class Settings {
    private let defaults: UserDefaults

    var serverAddress: String { didSet { defaults.set(serverAddress, forKey: "server") } }
    var quality: Quality { didSet { defaults.set(quality.rawValue, forKey: "quality") } }
    var searchPlatform: String { didSet { defaults.set(searchPlatform, forKey: "search_platform") } }
    var lyricScript: LyricScript { didSet { defaults.set(lyricScript.rawValue, forKey: "lyric_script") } }
    var lyricWordMode: LyricWordMode { didSet { defaults.set(lyricWordMode.rawValue, forKey: "lyric_word_mode") } }
    var showTranslation: Bool { didSet { defaults.set(showTranslation, forKey: "lyric_translation") } }
    var showRoman: Bool { didSet { defaults.set(showRoman, forKey: "lyric_roman") } }
    var appearance: Appearance { didSet { defaults.set(appearance.rawValue, forKey: "appearance") } }
    /// Audio cache limit in bytes.
    var cacheLimit: Int64 { didSet { defaults.set(cacheLimit, forKey: "cache_limit") } }
    /// Check GitHub for a newer release at launch (at most daily).
    var autoUpdate: Bool { didSet { defaults.set(autoUpdate, forKey: "auto_update") } }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        // The public server unless the user set their own (docs/design.md「设置项」).
        serverAddress = defaults.string(forKey: "server") ?? Self.defaultServer
        quality = Quality(rawValue: defaults.string(forKey: "quality") ?? "") ?? .high
        searchPlatform = defaults.string(forKey: "search_platform") ?? "applemusic"
        lyricScript = LyricScript(rawValue: defaults.string(forKey: "lyric_script") ?? "") ?? .original
        // The apps default to estimated word timing so every synced song sweeps
        // word by word; the web player keeps "native" as its default.
        lyricWordMode = LyricWordMode(rawValue: defaults.string(forKey: "lyric_word_mode") ?? "") ?? .estimate
        showTranslation = defaults.object(forKey: "lyric_translation") as? Bool ?? true
        showRoman = defaults.bool(forKey: "lyric_roman")
        appearance = Appearance(rawValue: defaults.string(forKey: "appearance") ?? "") ?? .system
        let limit = defaults.object(forKey: "cache_limit") as? Int64 ?? 0
        cacheLimit = limit > 0 ? limit : 2 << 30
        autoUpdate = defaults.object(forKey: "auto_update") as? Bool ?? true
    }

    var serverURL: URL? { MHubClient.serverURL(from: serverAddress) }

    static let defaultServer = "https://music.op.wiki"
}

/// App-wide state shared by every screen: server client, settings, the local
/// library and transient feedback.
@MainActor @Observable
final class AppModel {
    let settings = Settings()
    let library = LibraryStore()
    var platforms: [PlatformInfo] = PlatformInfo.fallback
    var recent: [Track] = []
    var toast: String?
    /// Songs for which the "添加到歌单" sheet is open.
    var pendingPlaylistTracks: PendingTracks?
    /// The search field lives in the tab bar, so its text is app state.
    var searchQuery = ""
    /// Settings, opened from the account button of every root page.
    var showsSettings = false
    /// The selected tab and the home and library stacks, so the queue's source
    /// link can open a playlist from the player.
    var tab: AppTab = .home
    var homePath = NavigationPath()
    var libraryPath = NavigationPath()
    /// The player's「歌词与外观」sheet.
    var showsDisplaySettings = false
    /// The player's lyric sharing sheet, with a long-pressed line preselected.
    var lyricShare: LyricShareRequest?
    private var toastID = 0

    @ObservationIgnored private(set) var account: AccountManager!
    @ObservationIgnored private(set) var updates: UpdateManager!
    @ObservationIgnored private(set) var downloads: SongDownloads!

    var client: MHubClient? { settings.serverURL.map { MHubClient(server: $0, account: account?.session) } }

    init() {
        recent = Self.loadRecent()
        account = AccountManager(library: library) { [weak self] in self?.client }
        updates = UpdateManager(settings: settings)
        downloads = SongDownloads(app: self)
    }

    func show(_ message: String) {
        toastID += 1
        let id = toastID
        withAnimation(.snappy) { toast = message }
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(2.6))
            if toastID == id { withAnimation(.snappy) { toast = nil } }
        }
    }

    func refreshPlatforms() async {
        guard let client else { return }
        if let list = try? await client.platforms(), !list.isEmpty { platforms = list }
    }

    func label(for platform: String) -> String {
        platforms.first { $0.id == platform }?.label ?? PlatformInfo.label(for: platform)
    }

    // MARK: Recently played

    func recordRecent(_ track: Track) {
        recent.removeAll { $0.id == track.id }
        recent.insert(track.chosen, at: 0)
        if recent.count > 30 { recent.removeLast(recent.count - 30) }
        if let data = try? JSONEncoder().encode(recent) { UserDefaults.standard.set(data, forKey: "recent_tracks") }
    }

    private static func loadRecent() -> [Track] {
        guard let data = UserDefaults.standard.data(forKey: "recent_tracks") else { return [] }
        return (try? JSONDecoder().decode([Track].self, from: data)) ?? []
    }
}

/// Local playlists, persisted as `library.json` (same schema as Android).
@MainActor @Observable
final class LibraryStore {
    private(set) var playlists: [Playlist] = []
    private let file: URL
    /// While an account is linked, every edit is also handed over as library
    /// operations for upload (docs/design.md「账号与歌单同步」).
    @ObservationIgnored var recorder: (([LibraryOp]) -> Void)?

    init() {
        let folder = URL.applicationSupportDirectory
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        file = folder.appendingPathComponent("library.json")
        load()
    }

    private struct Document: Codable {
        var version = 1
        var playlists: [Playlist]
    }

    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .millisecondsSince1970
        return encoder
    }()

    private static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .millisecondsSince1970
        return decoder
    }()

    private func load() {
        guard let data = try? Data(contentsOf: file),
              let document = try? Self.decoder.decode(Document.self, from: data) else { return }
        playlists = document.playlists
    }

    private func save() {
        guard let data = try? Self.encoder.encode(Document(playlists: playlists)) else { return }
        try? data.write(to: file, options: .atomic)
    }

    func playlist(_ id: String) -> Playlist? { playlists.first { $0.id == id } }

    /// Replace everything, e.g. with the account's library.
    func replaceAll(_ list: [Playlist]) {
        guard list != playlists else { return }
        playlists = list
        save()
    }

    private func record(_ ops: [LibraryOp]) {
        if !ops.isEmpty { recorder?(ops) }
    }

    @discardableResult
    func create(name: String, tracks: [Track] = [], sourceURL: String = "", sourcePlatform: String = "") -> Playlist {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let playlist = Playlist(name: trimmed.isEmpty ? Strings.untitledPlaylist : trimmed, tracks: tracks.map(\.chosen),
                                sourceURL: sourceURL, sourcePlatform: sourcePlatform)
        playlists.insert(playlist, at: 0)
        save()
        record([.create(id: playlist.id, name: playlist.name, sourceURL: sourceURL, sourcePlatform: sourcePlatform,
                        tracks: playlist.tracks.map(SyncTrack.init))])
        return playlist
    }

    func rename(_ id: String, to name: String) {
        guard !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        update(id) { $0.name = LibrarySync.cleanName(name) }
        record([.rename(id: id, name: name)])
    }

    func delete(_ id: String) {
        playlists.removeAll { $0.id == id }
        save()
        record([.delete(id: id)])
    }

    /// Returns how many songs were new to the playlist.
    @discardableResult
    func add(_ tracks: [Track], to id: String) -> Int {
        var new: [Track] = []
        update(id) { playlist in
            let known = Set(playlist.tracks.map(\.id))
            new = tracks.map(\.chosen).uniqued().filter { !known.contains($0.id) }
            playlist.tracks.append(contentsOf: new)
        }
        if !new.isEmpty { record([.append(id: id, tracks: new.map(SyncTrack.init))]) }
        return new.count
    }

    func remove(trackIDs: Set<String>, from id: String) {
        update(id) { $0.tracks.removeAll { trackIDs.contains($0.id) } }
        record(trackIDs.sorted().map { .remove(id: id, key: $0) })
    }

    func move(in id: String, from source: IndexSet, to destination: Int) {
        guard let before = playlist(id)?.tracks.map(\.id) else { return }
        update(id) { $0.tracks.move(fromOffsets: source, toOffset: destination) }
        let after = playlist(id)?.tracks.map(\.id) ?? before
        record(LibrarySync.reorderMoves(from: before, to: after).map { .move(id: id, key: $0.key, after: $0.after) })
    }

    private func update(_ id: String, _ change: (inout Playlist) -> Void) {
        guard let at = playlists.firstIndex(where: { $0.id == id }) else { return }
        change(&playlists[at])
        playlists[at].updatedAt = .now
        save()
    }
}

/// Open lyric sharing for a song, optionally with one line chosen.
struct LyricShareRequest: Identifiable {
    let id = UUID()
    var track: Track
    var line: Int?
}
