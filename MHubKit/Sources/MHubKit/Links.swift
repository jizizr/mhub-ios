import Foundation

/// Share links and import links, matching the web `utils/share.js`.
public enum Links {
    public static let shareablePlatforms: Set<String> = ["applemusic", "netease", "tencent", "soda"]

    public static func canShare(_ track: Track) -> Bool {
        shareablePlatforms.contains(track.platform)
            && track.sourceID.range(of: #"^[A-Za-z0-9._-]{1,64}$"#, options: .regularExpression) != nil
    }

    /// `<server>/?song=<platform>:<id>`; the web app opens it in its player.
    public static func shareURL(for track: Track, server: URL) -> URL? {
        guard canShare(track), var components = URLComponents(url: server, resolvingAgainstBaseURL: false) else { return nil }
        components.path = "/"
        components.queryItems = [URLQueryItem(name: "song", value: "\(track.platform):\(track.sourceID)")]
        return components.url
    }

    /// The platform a pasted playlist/album link belongs to.
    public static func collectionPlatform(for text: String) -> String? {
        guard let host = URL(string: text.trimmingCharacters(in: .whitespacesAndNewlines))?.host()?.lowercased() else { return nil }
        if host.hasSuffix("music.apple.com") { return "applemusic" }
        if host.hasSuffix("music.163.com") || host.hasSuffix("163cn.tv") { return "netease" }
        return nil
    }
}

extension Track {
    /// Fills metadata the playback task knows better (duration, album).
    public func enriched(by task: PlaybackTask, server: URL? = nil) -> Track {
        var copy = self
        if copy.cover.isEmpty, let server, let cover = task.coverURL,
           let url = MHubClient.resolve(cover, against: server) {
            copy.cover = url.absoluteString
        }
        if let duration = task.duration, duration > 0 { copy.durationMs = duration * 1000 }
        if copy.album.isEmpty, let album = task.album { copy.album = album }
        if copy.title.isEmpty, let title = task.title { copy.title = title }
        if copy.artist.isEmpty, let artist = task.artist { copy.artist = artist }
        return copy
    }

    /// Key of the fully cached audio file for this song at a quality.
    public func cacheKey(_ quality: Quality) -> String { "\(platform):\(sourceID):\(quality.rawValue)" }
}
