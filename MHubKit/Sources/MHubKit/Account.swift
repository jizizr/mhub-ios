import Foundation

// Account and library sync. See docs/design.md「账号与歌单同步」and
// docs/api-contract.md「账号与同步」; cases in contract/library-ops-cases.json.

/// Where the session token lives (the keychain in the app).
public protocol SessionStore: AnyObject, Sendable {
    var token: String? { get set }
}

public struct AuthConfig: Decodable, Sendable, Equatable {
    public var enabled: Bool
    public var turnstileSiteKey: String

    public init(enabled: Bool = false, turnstileSiteKey: String = "") {
        self.enabled = enabled
        self.turnstileSiteKey = turnstileSiteKey
    }

    /// Registration needs a human check the app cannot show: send people to the web page.
    public var registersOnWeb: Bool { !turnstileSiteKey.isEmpty }

    enum CodingKeys: String, CodingKey {
        case enabled
        case turnstileSiteKey = "turnstile_site_key"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? false
        turnstileSiteKey = try c.decodeIfPresent(String.self, forKey: .turnstileSiteKey) ?? ""
    }
}

public struct AccountUser: Codable, Sendable, Equatable {
    public var id: Int64
    public var username: String

    public init(id: Int64, username: String) {
        self.id = id
        self.username = username
    }
}

struct MeResponse: Decodable { var user: AccountUser? }

public struct LoginResponse: Decodable, Sendable {
    public var user: AccountUser
    public var recoveryCodes: [String]

    enum CodingKeys: String, CodingKey {
        case user
        case recoveryCodes = "recovery_codes"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        user = try c.decode(AccountUser.self, forKey: .user)
        recoveryCodes = try c.decodeIfPresent([String].self, forKey: .recoveryCodes) ?? []
    }
}

/// A song as the account library stores it (no quality, no album).
public struct SyncTrack: Codable, Sendable, Equatable {
    public var platform: String
    public var sourceID: String
    public var title: String
    public var artist: String
    public var cover: String

    public init(_ track: Track) {
        platform = track.platform
        sourceID = track.sourceID
        title = track.title
        artist = track.artist
        cover = track.cover
    }

    public var track: Track { Track(platform: platform, sourceID: sourceID, title: title, artist: artist, cover: cover) }

    enum CodingKeys: String, CodingKey {
        case platform, title, artist, cover
        case sourceID = "source_id"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        platform = try c.decode(String.self, forKey: .platform)
        sourceID = try c.decode(String.self, forKey: .sourceID)
        title = try c.decodeIfPresent(String.self, forKey: .title) ?? ""
        artist = try c.decodeIfPresent(String.self, forKey: .artist) ?? ""
        cover = try c.decodeIfPresent(String.self, forKey: .cover) ?? ""
    }
}

public struct LibrarySnapshot: Decodable, Sendable {
    struct Entry: Decodable {
        var id: String
        var name: String
        var sourceURL: String?
        var sourcePlatform: String?
        var createdAt: Double?
        var updatedAt: Double?
        var tracks: [SyncTrack]?

        enum CodingKeys: String, CodingKey {
            case id, name, tracks
            case sourceURL = "source_url"
            case sourcePlatform = "source_platform"
            case createdAt = "created_at"
            case updatedAt = "updated_at"
        }
    }

    var playlists: [Entry]

    /// The account's playlists as local ones (newest first, as the server lists them).
    public var library: [Playlist] {
        playlists.map { entry in
            var playlist = Playlist(id: entry.id, name: entry.name, tracks: (entry.tracks ?? []).map(\.track),
                                    sourceURL: entry.sourceURL ?? "", sourcePlatform: entry.sourcePlatform ?? "")
            playlist.createdAt = Date(timeIntervalSince1970: (entry.createdAt ?? 0) / 1000)
            playlist.updatedAt = Date(timeIntervalSince1970: (entry.updatedAt ?? 0) / 1000)
            return playlist
        }
    }
}

/// One library edit, the same operations the server applies (`POST /api/v1/sync/library/json`).
public enum LibraryOp: Codable, Sendable, Equatable {
    case create(id: String, name: String, sourceURL: String, sourcePlatform: String, tracks: [SyncTrack])
    case append(id: String, tracks: [SyncTrack])
    case rename(id: String, name: String)
    case delete(id: String)
    case remove(id: String, key: String)
    case move(id: String, key: String, after: String?)

    public var playlistID: String {
        switch self {
        case let .create(id, _, _, _, _), let .append(id, _), let .rename(id, _), let .delete(id),
             let .remove(id, _), let .move(id, _, _): id
        }
    }

    enum CodingKeys: String, CodingKey {
        case op, id, name, tracks, key, after
        case sourceURL = "source_url"
        case sourcePlatform = "source_platform"
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(playlistID, forKey: .id)
        switch self {
        case let .create(_, name, sourceURL, sourcePlatform, tracks):
            try c.encode("create", forKey: .op)
            try c.encode(name, forKey: .name)
            try c.encode(sourceURL, forKey: .sourceURL)
            try c.encode(sourcePlatform, forKey: .sourcePlatform)
            try c.encode(tracks, forKey: .tracks)
        case let .append(_, tracks):
            try c.encode("append", forKey: .op)
            try c.encode(tracks, forKey: .tracks)
        case let .rename(_, name):
            try c.encode("rename", forKey: .op)
            try c.encode(name, forKey: .name)
        case .delete:
            try c.encode("delete", forKey: .op)
        case let .remove(_, key):
            try c.encode("remove", forKey: .op)
            try c.encode(key, forKey: .key)
        case let .move(_, key, after):
            try c.encode("move", forKey: .op)
            try c.encode(key, forKey: .key)
            try c.encode(after, forKey: .after) // null moves to the top
        }
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let id = try c.decode(String.self, forKey: .id)
        switch try c.decode(String.self, forKey: .op) {
        case "create":
            self = .create(id: id, name: try c.decode(String.self, forKey: .name),
                           sourceURL: try c.decodeIfPresent(String.self, forKey: .sourceURL) ?? "",
                           sourcePlatform: try c.decodeIfPresent(String.self, forKey: .sourcePlatform) ?? "",
                           tracks: try c.decodeIfPresent([SyncTrack].self, forKey: .tracks) ?? [])
        case "append": self = .append(id: id, tracks: try c.decode([SyncTrack].self, forKey: .tracks))
        case "rename": self = .rename(id: id, name: try c.decode(String.self, forKey: .name))
        case "delete": self = .delete(id: id)
        case "remove": self = .remove(id: id, key: try c.decode(String.self, forKey: .key))
        case "move": self = .move(id: id, key: try c.decode(String.self, forKey: .key),
                                  after: try c.decodeIfPresent(String.self, forKey: .after))
        case let other:
            throw DecodingError.dataCorruptedError(forKey: .op, in: c, debugDescription: "unknown op \(other)")
        }
    }
}

public enum LibrarySync {
    public static let untitled = "未命名歌单"
    /// Same playlist when names match and this share of local songs is already in the cloud.
    public static let mergeOverlap = 0.6

    public static func cleanName(_ name: String) -> String {
        let trimmed = String(name.trimmingCharacters(in: .whitespacesAndNewlines).prefix(200))
        return trimmed.isEmpty ? untitled : trimmed
    }

    /// Replays `ops` on a local library exactly as the server does (newest playlist first).
    public static func apply(_ library: [Playlist], _ ops: [LibraryOp], now: Date) -> [Playlist] {
        ops.reduce(library) { apply($0, $1, now: now) }
    }

    private static func apply(_ list: [Playlist], _ op: LibraryOp, now: Date) -> [Playlist] {
        func edit(_ change: (inout Playlist) -> Bool) -> [Playlist] {
            guard let index = list.firstIndex(where: { $0.id == op.playlistID }) else { return list }
            var result = list
            var playlist = result[index]
            guard change(&playlist) else { return list }
            playlist.updatedAt = now
            result[index] = playlist
            return result
        }
        switch op {
        case let .create(id, name, sourceURL, sourcePlatform, tracks):
            let playlist = Playlist(id: id, name: cleanName(name), tracks: tracks.map(\.track),
                                    sourceURL: sourceURL, sourcePlatform: sourcePlatform, now: now)
            return [playlist] + list.filter { $0.id != id }
        case let .append(_, tracks):
            return edit { playlist in
                var present = Set(playlist.tracks.map(\.id))
                let added = tracks.map(\.track).filter { present.insert($0.id).inserted }
                guard !added.isEmpty else { return false }
                playlist.tracks += added
                return true
            }
        case let .rename(_, name):
            return edit { $0.name = cleanName(name); return true }
        case .delete:
            return list.filter { $0.id != op.playlistID }
        case let .remove(_, key):
            return edit { $0.tracks.removeAll { $0.id == key }; return true }
        case let .move(_, key, after):
            return edit { playlist in
                guard let moving = playlist.tracks.first(where: { $0.id == key }), after != key else { return false }
                var rest = playlist.tracks.filter { $0.id != key }
                let position = after.map { after in rest.firstIndex { $0.id == after }.map { $0 + 1 } ?? rest.count } ?? 0
                rest.insert(moving, at: position)
                playlist.tracks = rest
                return true
            }
        }
    }

    /// The fewest moves that turn `from` into `to`: songs on a longest increasing
    /// run stay, every other song moves after its new neighbour, in the new order.
    public static func reorderMoves(from: [String], to: [String]) -> [(key: String, after: String?)] {
        var position: [String: Int] = [:]
        for (index, key) in from.enumerated() where position[key] == nil { position[key] = index }
        let keep = Set(longestIncreasing(to.map { position[$0] ?? -1 }).map { to[$0] })
        return to.enumerated().compactMap { index, key in
            keep.contains(key) ? nil : (key, index > 0 ? to[index - 1] : nil)
        }
    }

    /// Indices of one longest strictly increasing subsequence (patience sorting).
    private static func longestIncreasing(_ values: [Int]) -> [Int] {
        var tails: [Int] = []
        var previous = Array(repeating: -1, count: values.count)
        for index in values.indices where values[index] >= 0 {
            var low = 0, high = tails.count
            while low < high {
                let middle = (low + high) / 2
                if values[tails[middle]] < values[index] { low = middle + 1 } else { high = middle }
            }
            if low > 0 { previous[index] = tails[low - 1] }
            if low == tails.count { tails.append(index) } else { tails[low] = index }
        }
        var result: [Int] = []
        var index = tails.last ?? -1
        while index >= 0 {
            result.insert(index, at: 0)
            index = previous[index]
        }
        return result
    }

    /// The web client's `normalizeName`: NFKC, lower case, without spaces, punctuation or symbols.
    public static func normalizeName(_ name: String) -> String {
        let folded = name.precomposedStringWithCompatibilityMapping.lowercased()
        let dropped = CharacterSet.whitespacesAndNewlines.union(.punctuationCharacters).union(.symbols)
        return String(String.UnicodeScalarView(folded.unicodeScalars.filter { !dropped.contains($0) }))
    }

    public struct MergePlan: Sendable {
        public struct Merge: Sendable {
            public var local: Playlist
            public var cloudID: String
            public var tracks: [Track]
        }
        public var create: [Playlist]
        public var merge: [Merge]
    }

    /// How local playlists join the account library on first login (web `planGuestMerge`).
    public static func planMerge(local: [Playlist], cloud: [Playlist]) -> MergePlan {
        var plan = MergePlan(create: [], merge: [])
        let byName = Dictionary(grouping: cloud) { normalizeName($0.name) }
        for playlist in local {
            var seen = Set<String>()
            let keys = playlist.tracks.map(\.id).filter { seen.insert($0).inserted }
            func overlap(_ candidate: Playlist) -> Double {
                guard !keys.isEmpty else { return 1 }
                let cloudKeys = Set(candidate.tracks.map(\.id))
                return Double(keys.filter(cloudKeys.contains).count) / Double(keys.count)
            }
            let byOverlap = (byName[normalizeName(playlist.name)] ?? [])
                .map { ($0, overlap($0)) }
                .filter { $0.1 >= mergeOverlap }
                .max { $0.1 < $1.1 }?.0
            let match = byOverlap ?? (playlist.sourceURL.isEmpty ? nil : cloud.first { $0.sourceURL == playlist.sourceURL })
            guard let match else {
                plan.create.append(playlist)
                continue
            }
            var present = Set(match.tracks.map(\.id))
            let missing = playlist.tracks.filter { present.insert($0.id).inserted }
            if !missing.isEmpty { plan.merge.append(.init(local: playlist, cloudID: match.id, tracks: missing)) }
        }
        return plan
    }

    /// Operations that carry out a merge plan.
    public static func mergeOps(_ plan: MergePlan) -> [LibraryOp] {
        plan.create.reversed().map {
            .create(id: $0.id, name: $0.name, sourceURL: $0.sourceURL, sourcePlatform: $0.sourcePlatform,
                    tracks: $0.tracks.map(SyncTrack.init))
        } + plan.merge.map { .append(id: $0.cloudID, tracks: $0.tracks.map(SyncTrack.init)) }
    }
}
