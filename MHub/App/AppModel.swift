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

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        serverAddress = defaults.string(forKey: "server") ?? ""
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
    }

    var serverURL: URL? { MHubClient.serverURL(from: serverAddress) }
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
    private var toastID = 0

    var client: MHubClient? { settings.serverURL.map { MHubClient(server: $0) } }

    init() {
        recent = Self.loadRecent()
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

    @discardableResult
    func create(name: String, tracks: [Track] = [], sourceURL: String = "", sourcePlatform: String = "") -> Playlist {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let playlist = Playlist(name: trimmed.isEmpty ? Strings.untitledPlaylist : trimmed, tracks: tracks.map(\.chosen),
                                sourceURL: sourceURL, sourcePlatform: sourcePlatform)
        playlists.insert(playlist, at: 0)
        save()
        return playlist
    }

    func rename(_ id: String, to name: String) {
        update(id) { $0.name = name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? $0.name : name }
    }

    func delete(_ id: String) {
        playlists.removeAll { $0.id == id }
        save()
    }

    /// Returns how many songs were new to the playlist.
    @discardableResult
    func add(_ tracks: [Track], to id: String) -> Int {
        var added = 0
        update(id) { playlist in
            let known = Set(playlist.tracks.map(\.id))
            let new = tracks.map(\.chosen).uniqued().filter { !known.contains($0.id) }
            playlist.tracks.append(contentsOf: new)
            added = new.count
        }
        return added
    }

    func remove(trackIDs: Set<String>, from id: String) {
        update(id) { $0.tracks.removeAll { trackIDs.contains($0.id) } }
    }

    func move(in id: String, from source: IndexSet, to destination: Int) {
        update(id) { $0.tracks.move(fromOffsets: source, toOffset: destination) }
    }

    private func update(_ id: String, _ change: (inout Playlist) -> Void) {
        guard let at = playlists.firstIndex(where: { $0.id == id }) else { return }
        change(&playlists[at])
        playlists[at].updatedAt = .now
        save()
    }
}
