import Foundation

/// Listening tier. Raw values are the server's `quality` names.
public enum Quality: String, Codable, CaseIterable, Sendable, Identifiable {
    case standard, high, lossless, hires

    public var id: String { rawValue }

    public var label: String {
        switch self {
        case .standard: "标准"
        case .high: "高品质"
        case .lossless: "无损"
        case .hires: "Hi-Res"
        }
    }
}

/// A music platform as listed by `/api/v1/platforms`.
public struct PlatformInfo: Codable, Hashable, Sendable, Identifiable {
    public var id: String
    public var label: String

    public init(id: String, label: String) {
        self.id = id
        self.label = label
    }

    /// Used until the server answers, and when it cannot be reached.
    public static let fallback: [PlatformInfo] = [
        PlatformInfo(id: "applemusic", label: "Apple Music"),
        PlatformInfo(id: "netease", label: "网易云音乐"),
        PlatformInfo(id: "tencent", label: "QQ音乐"),
    ]

    public static func label(for id: String) -> String {
        fallback.first { $0.id == id }?.label ?? id
    }

    /// Playlist and album links can only be opened on these platforms.
    public static let collectionPlatforms: Set<String> = ["applemusic", "netease"]
    /// AutoPlay stations exist only for Apple Music.
    public static let autoplayPlatforms: Set<String> = ["applemusic"]
}

/// A song in a queue, playlist or list. Quality is not part of a track: it is
/// chosen when playback starts.
public struct Track: Codable, Hashable, Sendable, Identifiable {
    public var platform: String
    public var sourceID: String
    public var title: String
    public var artist: String
    public var album: String
    public var cover: String
    public var durationMs: Int?
    /// Added by AutoPlay rather than chosen by the user.
    public var isRecommendation: Bool

    /// `platform:source_id`, the same identity as the web `trackIdentity`.
    public var id: String { "\(platform):\(sourceID)" }

    public var coverURL: URL? { cover.isEmpty ? nil : URL(string: cover) }

    public init(platform: String, sourceID: String, title: String, artist: String,
                album: String = "", cover: String = "", durationMs: Int? = nil,
                isRecommendation: Bool = false) {
        self.platform = platform
        self.sourceID = sourceID
        self.title = title
        self.artist = artist
        self.album = album
        self.cover = cover
        self.durationMs = durationMs
        self.isRecommendation = isRecommendation
    }

    enum CodingKeys: String, CodingKey {
        case platform, title, artist, album, cover
        case sourceID = "source_id"
        case durationMs = "duration_ms"
        case isRecommendation = "autoplay"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        platform = try c.decode(String.self, forKey: .platform)
        sourceID = try c.decode(String.self, forKey: .sourceID)
        title = try c.decodeIfPresent(String.self, forKey: .title) ?? ""
        artist = try c.decodeIfPresent(String.self, forKey: .artist) ?? ""
        album = try c.decodeIfPresent(String.self, forKey: .album) ?? ""
        cover = try c.decodeIfPresent(String.self, forKey: .cover) ?? ""
        durationMs = try c.decodeIfPresent(Int.self, forKey: .durationMs)
        isRecommendation = try c.decodeIfPresent(Bool.self, forKey: .isRecommendation) ?? false
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(platform, forKey: .platform)
        try c.encode(sourceID, forKey: .sourceID)
        try c.encode(title, forKey: .title)
        try c.encode(artist, forKey: .artist)
        try c.encode(album, forKey: .album)
        try c.encode(cover, forKey: .cover)
        try c.encodeIfPresent(durationMs, forKey: .durationMs)
        if isRecommendation { try c.encode(true, forKey: .isRecommendation) }
    }

    /// The same song as a user choice (AutoPlay flag cleared).
    public var chosen: Track {
        var copy = self
        copy.isRecommendation = false
        return copy
    }
}

/// A search/recommendation/collection row as the API returns it.
public struct SearchItem: Codable, Hashable, Sendable {
    public var platform: String
    public var id: String
    public var song: String
    public var singer: String
    public var cover: String?

    public var track: Track {
        Track(platform: platform, sourceID: id, title: song, artist: singer, cover: cover ?? "")
    }
}

public struct RecommendationTag: Codable, Hashable, Sendable, Identifiable {
    public var id: String
    public var label: String
    public var subtitle: String
    public var playlistIDs: [String]

    enum CodingKeys: String, CodingKey {
        case id, label, subtitle
        case playlistIDs = "playlist_ids"
    }
}

public struct RecommendationPlaylist: Codable, Hashable, Sendable, Identifiable {
    public var id: String
    public var resourceType: String
    public var name: String
    public var curator: String
    public var description: String
    public var cover: String
    public var url: String

    enum CodingKeys: String, CodingKey {
        case id, name, curator, description, cover, url
        case resourceType = "resource_type"
    }
}

public struct RecommendationHome: Codable, Sendable {
    public var source: String
    public var tags: [RecommendationTag]
    public var playlists: [RecommendationPlaylist]
    public var tracks: [SearchItem]
}

public struct Continuation: Codable, Sendable {
    public var source: String
    public var tracks: [SearchItem]
    public var station: String?
}

public struct Collection: Codable, Sendable {
    public var platform: String
    public var id: String
    public var title: String
    public var sourceURL: String
    public var items: [SearchItem]

    enum CodingKeys: String, CodingKey {
        case platform, id, title, items
        case sourceURL = "source_url"
    }
}

/// `GET /api/v1/playbacks/:id`, and the `playback` member of the create response.
public struct PlaybackTask: Decodable, Sendable, Equatable {
    public enum Status: String, Decodable, Sendable {
        case queued, processing, streaming, completed, failed, unknown

        public init(from decoder: Decoder) throws {
            let raw = try decoder.singleValueContainer().decode(String.self)
            self = Status(rawValue: raw) ?? .unknown
        }
    }

    public var id: String
    public var status: Status
    public var mediaRevision: String?
    public var platform: String?
    public var quality: String?
    public var title: String?
    public var artist: String?
    public var album: String?
    /// Seconds.
    public var duration: Int?
    public var format: String?
    public var contentType: String?
    public var bitrate: Int?
    public var byteSize: Int?
    public var error: String?
    public var audioURL: String
    /// Present only while a progressive stream can serve Range requests.
    public var streamLength: Int?
    /// Server-side artwork, used when the list row had none.
    public var coverURL: String?

    enum CodingKeys: String, CodingKey {
        case id, status, platform, quality, title, artist, album, duration, format, bitrate, error
        case mediaRevision = "media_revision"
        case contentType = "content_type"
        case byteSize = "byte_size"
        case audioURL = "audio_url"
        case streamLength = "stream_length"
        case coverURL = "cover_url"
    }
}

struct CreatePlaybackResponse: Decodable {
    var playback: PlaybackTask
}

/// `GET /api/v1/lyrics`.
public struct LyricsPayload: Codable, Sendable {
    public struct WordLine: Codable, Sendable {
        public var start: Int
        public var end: Int
        public var bg: Bool?
        /// `[start, end, text]`.
        public var words: [WordTiming]
    }

    public struct WordTiming: Codable, Sendable {
        public var start: Int
        public var end: Int
        public var text: String

        public init(from decoder: Decoder) throws {
            var c = try decoder.unkeyedContainer()
            start = try c.decode(Int.self)
            end = try c.decode(Int.self)
            text = try c.decode(String.self)
        }

        public func encode(to encoder: Encoder) throws {
            var c = encoder.unkeyedContainer()
            try c.encode(start)
            try c.encode(end)
            try c.encode(text)
        }
    }

    public var available: Bool
    public var plain: String
    public var translation: String
    public var words: [WordLine]
    public var roman: String
    public var credits: [String]

    public static let empty = LyricsPayload(available: false, plain: "", translation: "", words: [], roman: "", credits: [])

    public init(available: Bool, plain: String, translation: String, words: [WordLine], roman: String, credits: [String]) {
        self.available = available
        self.plain = plain
        self.translation = translation
        self.words = words
        self.roman = roman
        self.credits = credits
    }

    enum CodingKeys: String, CodingKey { case available, plain, translation, words, roman, credits }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        available = try c.decode(Bool.self, forKey: .available)
        plain = try c.decodeIfPresent(String.self, forKey: .plain) ?? ""
        translation = try c.decodeIfPresent(String.self, forKey: .translation) ?? ""
        // An unexpected word shape drops word timing only, as on the web.
        words = (try? c.decodeIfPresent([WordLine].self, forKey: .words)) ?? []
        roman = try c.decodeIfPresent(String.self, forKey: .roman) ?? ""
        credits = (try? c.decodeIfPresent([String].self, forKey: .credits)) ?? []
    }
}

/// A local playlist. The JSON shape is shared with the Android app.
/// Where the queue came from, shown above it like the web `sourcePlaylist`:
/// `playlist` (local, `id`), `collection` (an album or platform playlist,
/// reopened from `platform` and `url`) or `recommendation`.
public struct QueueSource: Codable, Hashable, Sendable {
    public static let playlist = "playlist"
    public static let collection = "collection"
    public static let recommendation = "recommendation"

    public var type: String
    public var name: String
    public var id: String
    public var platform: String
    public var url: String
    public var cover: String

    public init(type: String, name: String, id: String = "", platform: String = "", url: String = "", cover: String = "") {
        self.type = type
        self.name = name
        self.id = id
        self.platform = platform
        self.url = url
        self.cover = cover
    }

    public var isRecommendation: Bool { type == Self.recommendation }
}

public struct Playlist: Codable, Hashable, Sendable, Identifiable {
    public var id: String
    public var name: String
    public var tracks: [Track]
    public var sourceURL: String
    public var sourcePlatform: String
    public var createdAt: Date
    public var updatedAt: Date

    public var cover: String { tracks.first { !$0.cover.isEmpty }?.cover ?? "" }

    public init(id: String = UUID().uuidString, name: String, tracks: [Track] = [],
                sourceURL: String = "", sourcePlatform: String = "", now: Date = .now) {
        self.id = id
        self.name = name
        self.tracks = tracks.uniqued()
        self.sourceURL = sourceURL
        self.sourcePlatform = sourcePlatform
        createdAt = now
        updatedAt = now
    }

    enum CodingKeys: String, CodingKey {
        case id, name, tracks
        case sourceURL = "source_url"
        case sourcePlatform = "source_platform"
        case createdAt = "created_at"
        case updatedAt = "updated_at"
    }
}

extension Array where Element == Track {
    /// Drops later duplicates of the same song.
    public func uniqued() -> [Track] {
        var seen = Set<String>()
        return filter { seen.insert($0.id).inserted }
    }
}
