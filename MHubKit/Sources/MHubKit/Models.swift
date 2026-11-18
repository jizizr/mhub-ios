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
    /// Catalog search sections (`top`, `artists`, `albums`, `songs`,
    /// `playlists`); empty from servers that predate them.
    public var catalog: [String]

    public init(id: String, label: String, catalog: [String] = []) {
        self.id = id
        self.label = label
        self.catalog = catalog
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        label = try c.decodeIfPresent(String.self, forKey: .label) ?? id
        catalog = try c.decodeIfPresent([String].self, forKey: .catalog) ?? []
    }

    /// Album pages (and「前往专辑」) exist on this platform.
    public var hasAlbums: Bool { catalog.contains(CatalogSection.albums.rawValue) }
    /// Artist pages (and「前往艺人」) exist on this platform.
    public var hasArtists: Bool { catalog.contains(CatalogSection.artists.rawValue) }

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

/// Apple Music's search tabs, in its order.
public enum CatalogSection: String, CaseIterable, Sendable, Identifiable {
    case top, artists, albums, songs, playlists

    public var id: String { rawValue }

    public var label: String {
        switch self {
        case .top: "最佳结果"
        case .artists: "艺人"
        case .albums: "专辑"
        case .songs: "歌曲"
        case .playlists: "播放列表"
        }
    }
}

/// One catalog entry of any kind: a song, album, artist or playlist. Every
/// search section, album track list and artist shelf uses this shape.
public struct CatalogItem: Codable, Hashable, Sendable, Identifiable {
    public static let song = "song", album = "album", artist = "artist", playlist = "playlist"

    public var type: String
    public var platform: String
    public var itemID: String
    /// Song name, album title, artist name or playlist name.
    public var title: String
    /// Song: its artists. Album: its artist. Playlist: its curator.
    public var subtitle: String
    public var cover: String
    /// Songs: the album name.
    public var album: String
    /// Albums: `YYYY-MM-DD` or `YYYY`.
    public var releaseDate: String
    /// Albums and playlists: the link `collections/resolve` accepts.
    public var url: String
    public var trackNumber: Int?
    public var discNumber: Int?
    public var durationMs: Int?

    public var id: String { "\(type):\(platform):\(itemID)" }
    public var coverURL: URL? { cover.isEmpty ? nil : URL(string: cover) }
    public var year: String { String(releaseDate.prefix(4)) }

    public init(type: String, platform: String, itemID: String, title: String, subtitle: String = "", cover: String = "",
                album: String = "", releaseDate: String = "", url: String = "",
                trackNumber: Int? = nil, discNumber: Int? = nil, durationMs: Int? = nil) {
        self.type = type
        self.platform = platform
        self.itemID = itemID
        self.title = title
        self.subtitle = subtitle
        self.cover = cover
        self.album = album
        self.releaseDate = releaseDate
        self.url = url
        self.trackNumber = trackNumber
        self.discNumber = discNumber
        self.durationMs = durationMs
    }

    enum CodingKeys: String, CodingKey {
        case type, platform, title, subtitle, cover, album, url
        case itemID = "id"
        case releaseDate = "release_date"
        case trackNumber = "track_number"
        case discNumber = "disc_number"
        case durationMs = "duration_ms"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        type = try c.decode(String.self, forKey: .type)
        platform = try c.decode(String.self, forKey: .platform)
        itemID = try c.decode(String.self, forKey: .itemID)
        title = try c.decodeIfPresent(String.self, forKey: .title) ?? ""
        subtitle = try c.decodeIfPresent(String.self, forKey: .subtitle) ?? ""
        cover = try c.decodeIfPresent(String.self, forKey: .cover) ?? ""
        album = try c.decodeIfPresent(String.self, forKey: .album) ?? ""
        releaseDate = try c.decodeIfPresent(String.self, forKey: .releaseDate) ?? ""
        url = try c.decodeIfPresent(String.self, forKey: .url) ?? ""
        trackNumber = try c.decodeIfPresent(Int.self, forKey: .trackNumber)
        discNumber = try c.decodeIfPresent(Int.self, forKey: .discNumber)
        durationMs = try c.decodeIfPresent(Int.self, forKey: .durationMs)
    }

    /// A song as a playable track.
    public var track: Track {
        Track(platform: platform, sourceID: itemID, title: title, artist: subtitle, album: album, cover: cover, durationMs: durationMs)
    }

    /// The line under a card: its kind in best results, else the year of an
    /// album, then who made it.
    public func cardSubtitle(withKind: Bool) -> String {
        var parts: [String] = []
        if withKind {
            parts.append(Self.kindLabel(type))
        } else if type == Self.album, !year.isEmpty {
            parts.append(year)
        }
        if !subtitle.isEmpty { parts.append(subtitle) }
        return parts.joined(separator: " · ")
    }

    public static func kindLabel(_ type: String) -> String {
        switch type {
        case song: "歌曲"
        case album: "专辑"
        case artist: "艺人"
        case playlist: "播放列表"
        default: ""
        }
    }
}

/// `GET /api/v1/catalog/search`.
public struct CatalogSearch: Codable, Hashable, Sendable {
    public var platform: String
    public var sections: [String]
    public var top: [CatalogItem]
    public var artists: [CatalogItem]
    public var albums: [CatalogItem]
    public var songs: [CatalogItem]
    public var playlists: [CatalogItem]

    public init(platform: String, sections: [String] = ["songs"], top: [CatalogItem] = [], artists: [CatalogItem] = [],
                albums: [CatalogItem] = [], songs: [CatalogItem] = [], playlists: [CatalogItem] = []) {
        self.platform = platform
        self.sections = sections
        self.top = top
        self.artists = artists
        self.albums = albums
        self.songs = songs
        self.playlists = playlists
    }

    public func items(_ section: CatalogSection) -> [CatalogItem] {
        switch section {
        case .top: top
        case .artists: artists
        case .albums: albums
        case .songs: songs
        case .playlists: playlists
        }
    }

    /// Tabs to show: the platform's sections that found something. A
    /// songs-only platform gets none and keeps the plain song list.
    public var visibleSections: [CatalogSection] {
        guard sections.count > 1 else { return [] }
        return sections.compactMap(CatalogSection.init(rawValue:)).filter { !items($0).isEmpty }
    }
}

/// `GET /api/v1/albums/:platform/:id`.
public struct AlbumDetail: Codable, Hashable, Sendable {
    public var platform: String
    public var id: String
    public var title: String
    public var artist: String
    /// Empty when the platform has no artist page.
    public var artistID: String
    public var cover: String
    public var releaseDate: String
    public var genre: String
    public var copyright: String
    /// The link `collections/resolve` accepts; a saved playlist's source.
    public var url: String
    public var tracks: [CatalogItem]

    enum CodingKeys: String, CodingKey {
        case platform, id, title, artist, cover, genre, copyright, url, tracks
        case artistID = "artist_id"
        case releaseDate = "release_date"
    }

    public var coverURL: URL? { cover.isEmpty ? nil : URL(string: cover) }

    /// Discs in order; one unlabeled group (disc 0) for a single-disc album.
    /// `offset` is the album-wide index of the disc's first track.
    public var discs: [AlbumDisc] {
        var groups: [AlbumDisc] = []
        for (index, track) in tracks.enumerated() {
            let disc = track.discNumber ?? 1
            let entry = AlbumDisc.Entry(index: index, item: track)
            if let group = groups.firstIndex(where: { $0.disc == disc }) {
                groups[group].tracks.append(entry)
            } else {
                groups.append(AlbumDisc(disc: disc, tracks: [entry]))
            }
        }
        if groups.count == 1 { groups[0].disc = 0 }
        return groups
    }

    /// The footer: release date, length and copyright, as Apple Music shows them.
    public var footer: [String] {
        [Self.releaseText(releaseDate), Self.summary(tracks), copyright].filter { !$0.isEmpty }
    }

    /// "2001-09-14" → "2001年9月14日"; a bare year stays a year.
    public static func releaseText(_ value: String) -> String {
        let parts = value.prefix(10).split(separator: "-").compactMap { Int($0) }
        switch parts.count {
        case 3: return "\(parts[0])年\(parts[1])月\(parts[2])日"
        case 2: return "\(parts[0])年\(parts[1])月"
        case 1: return "\(parts[0])年"
        default: return ""
        }
    }

    /// "10 首歌曲，41 分钟".
    public static func summary(_ tracks: [CatalogItem]) -> String {
        guard !tracks.isEmpty else { return "" }
        let minutes = Int((Double(tracks.compactMap(\.durationMs).reduce(0, +)) / 60_000).rounded())
        if minutes == 0 { return "\(tracks.count) 首歌曲" }
        if minutes < 60 { return "\(tracks.count) 首歌曲，\(minutes) 分钟" }
        let rest = minutes % 60
        return "\(tracks.count) 首歌曲，\(minutes / 60) 小时" + (rest > 0 ? " \(rest) 分钟" : "")
    }
}

/// One disc of an album: its tracks with their album-wide positions.
public struct AlbumDisc: Identifiable, Hashable, Sendable {
    public struct Entry: Identifiable, Hashable, Sendable {
        /// Position in the whole album, where playback starts.
        public var index: Int
        public var item: CatalogItem
        public var id: String { item.id }
    }

    public var disc: Int
    public var tracks: [Entry]
    public var id: Int { disc }
}

/// `GET /api/v1/artists/:platform/:id`.
public struct ArtistDetail: Codable, Hashable, Sendable {
    public var platform: String
    public var id: String
    public var name: String
    public var cover: String
    public var topSongs: [CatalogItem]
    public var albums: [CatalogItem]
    public var singles: [CatalogItem]

    enum CodingKeys: String, CodingKey {
        case platform, id, name, cover, albums, singles
        case topSongs = "top_songs"
    }

    public var coverURL: URL? { cover.isEmpty ? nil : URL(string: cover) }
}

/// `GET /api/v1/tracks/:platform/:id`: a song's details and the album and
/// artist pages it links to (empty ids where the platform has none).
public struct TrackInfo: Codable, Hashable, Sendable {
    public var platform: String
    public var id: String
    public var song: String
    public var singer: String
    public var album: String
    public var cover: String
    public var albumID: String
    public var artistID: String

    enum CodingKeys: String, CodingKey {
        case platform, id, song, singer, album, cover
        case albumID = "album_id"
        case artistID = "artist_id"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        platform = try c.decode(String.self, forKey: .platform)
        id = try c.decode(String.self, forKey: .id)
        song = try c.decodeIfPresent(String.self, forKey: .song) ?? ""
        singer = try c.decodeIfPresent(String.self, forKey: .singer) ?? ""
        album = try c.decodeIfPresent(String.self, forKey: .album) ?? ""
        cover = try c.decodeIfPresent(String.self, forKey: .cover) ?? ""
        albumID = try c.decodeIfPresent(String.self, forKey: .albumID) ?? ""
        artistID = try c.decodeIfPresent(String.self, forKey: .artistID) ?? ""
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
    /// `unplayable`: no source can ever play this song; players skip it.
    public var errorCode: String?
    public var audioURL: String
    /// Present only while a progressive stream can serve Range requests.
    public var streamLength: Int?
    /// Server-side artwork, used when the list row had none.
    public var coverURL: String?

    enum CodingKeys: String, CodingKey {
        case id, status, platform, quality, title, artist, album, duration, format, bitrate, error
        case mediaRevision = "media_revision"
        case errorCode = "error_code"
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
    /// An album or artist page; `id` and `platform` reopen it.
    public static let album = "album"
    public static let artist = "artist"

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
