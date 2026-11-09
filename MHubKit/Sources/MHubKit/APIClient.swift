import Foundation

public enum APIError: LocalizedError, Equatable {
    case invalidServer
    case http(status: Int, detail: String)
    case playbackFailed(String)
    case timedOut

    public var errorDescription: String? {
        switch self {
        case .invalidServer: "服务器地址无效"
        case let .http(status, detail): detail.isEmpty ? "HTTP \(status)" : detail
        case let .playbackFailed(message): message.isEmpty ? "播放准备失败" : message
        case .timedOut: "等待音频超时，请重试"
        }
    }
}

/// When a playback task can be handed to the system player. The rule is shared
/// with Android; see `docs/api-contract.md`.
public enum PlaybackReadiness: Equatable, Sendable {
    case ready(URL)
    case wait(since: String)
    case failed(String)

    public static func evaluate(_ task: PlaybackTask, server: URL) -> PlaybackReadiness {
        switch task.status {
        case .failed:
            return .failed(task.error ?? "")
        case .completed:
            guard let url = MHubClient.resolve(task.audioURL, against: server) else { return .failed("音频地址无效") }
            return .ready(url)
        case .streaming where task.streamLength != nil:
            guard let url = MHubClient.resolve(task.audioURL, against: server) else { return .failed("音频地址无效") }
            return .ready(url)
        case .streaming, .queued, .processing, .unknown:
            return .wait(since: task.status.rawValue)
        }
    }
}

/// HTTP client for one MHub server. Value type; safe to share across tasks.
public struct MHubClient: Sendable {
    public let server: URL
    let session: URLSession

    public init(server: URL, session: URLSession = .shared) {
        self.server = server
        self.session = session
    }

    /// Parses a user-entered address; a missing scheme defaults to https.
    public static func serverURL(from text: String) -> URL? {
        var value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return nil }
        if !value.contains("://") { value = "https://" + value }
        while value.hasSuffix("/") { value.removeLast() }
        guard let url = URL(string: value), let scheme = url.scheme?.lowercased(),
              ["http", "https"].contains(scheme), url.host() != nil,
              url.user() == nil, url.password() == nil else { return nil }
        return url
    }

    /// Resolves server-relative paths; absolute media-origin URLs stay as is.
    public static func resolve(_ value: String, against server: URL) -> URL? {
        guard !value.isEmpty else { return nil }
        if let absolute = URL(string: value), let scheme = absolute.scheme?.lowercased() {
            return ["http", "https"].contains(scheme) ? absolute : nil
        }
        guard value.hasPrefix("/"), !value.hasPrefix("//") else { return nil }
        return URL(string: server.absoluteString + value)
    }

    // MARK: Endpoints

    public func health() async throws {
        _ = try await data(path: "/health", timeout: 8)
    }

    public func platforms() async throws -> [PlatformInfo] {
        try await get("/api/v1/platforms")
    }

    public func search(platform: String, query: String, limit: Int = 20) async throws -> [Track] {
        let items: [SearchItem] = try await get("/api/v1/search", [
            "platform": platform, "q": query, "limit": String(limit),
        ])
        return items.map(\.track)
    }

    public func home(platform: String = "applemusic", limit: Int = 40, refresh: Bool = false,
                     exclude: [String] = []) async throws -> RecommendationHome {
        var query = ["platform": platform, "limit": String(limit)]
        if refresh { query["refresh"] = "true" }
        let numeric = exclude.filter { !$0.isEmpty && $0.allSatisfy(\.isNumber) }.suffix(300)
        if !numeric.isEmpty { query["exclude"] = numeric.joined(separator: ",") }
        return try await get("/api/v1/recommendations/home", query)
    }

    public func continuation(platform: String, seedID: String, seedIDs: [String], station: String?,
                             exclude: [String], limit: Int = 10) async throws -> Continuation {
        var body: [String: Any] = [
            "platform": platform, "seed_id": seedID, "seed_ids": seedIDs,
            "exclude": Array(Set(exclude)), "limit": limit,
        ]
        if let station, !station.isEmpty { body["station"] = station }
        return try await post("/api/v1/recommendations/continue", body: body)
    }

    public func collection(platform: String, url: String) async throws -> Collection {
        try await get("/api/v1/collections/resolve", ["platform": platform, "url": url], timeout: 60)
    }

    public func lyrics(for track: Track) async throws -> LyricsPayload {
        var query = ["platform": track.platform, "track_id": track.sourceID]
        if !track.title.isEmpty { query["title"] = track.title }
        if !track.artist.isEmpty { query["artist"] = track.artist }
        if !track.album.isEmpty { query["album"] = track.album }
        if let duration = track.durationMs, duration > 0 { query["duration"] = String(duration / 1000) }
        return try await get("/api/v1/lyrics", query)
    }

    public func createPlayback(_ track: Track, quality: Quality) async throws -> PlaybackTask {
        let response: CreatePlaybackResponse = try await post("/api/v1/playbacks", body: [
            "platform": track.platform, "query": track.title, "selected_id": track.sourceID,
            "quality": quality.rawValue, "include_cover": false,
        ])
        return response.playback
    }

    /// Long-poll: returns as soon as the task leaves `since` (at most ~15 s).
    public func playback(id: String, since: String? = nil, waitMs: Int = 15_000) async throws -> PlaybackTask {
        var query: [String: String] = [:]
        if let since { query = ["since": since, "wait_ms": String(waitMs)] }
        let path = "/api/v1/playbacks/" + (id.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? id)
        return try await get(path, query, timeout: Double(waitMs) / 1000 + 10)
    }

    /// Creates the task and long-polls until the system player can open it.
    public func preparePlayback(_ track: Track, quality: Quality, deadline: Duration = .seconds(180)) async throws
        -> (task: PlaybackTask, url: URL) {
        let clock = ContinuousClock()
        let end = clock.now.advanced(by: deadline)
        var task = try await createPlayback(track, quality: quality)
        while true {
            try Task.checkCancellation()
            switch PlaybackReadiness.evaluate(task, server: server) {
            case let .ready(url): return (task, url)
            case let .failed(message): throw APIError.playbackFailed(message)
            case let .wait(since):
                guard clock.now < end else { throw APIError.timedOut }
                task = try await playback(id: task.id, since: since)
            }
        }
    }

    // MARK: Transport

    private func get<T: Decodable>(_ path: String, _ query: [String: String] = [:], timeout: Double = 20) async throws -> T {
        try await JSONDecoder().decode(T.self, from: data(path: path, query: query, timeout: timeout))
    }

    private func post<T: Decodable>(_ path: String, body: [String: Any]) async throws -> T {
        let payload = try JSONSerialization.data(withJSONObject: body)
        return try await JSONDecoder().decode(T.self, from: data(path: path, method: "POST", body: payload, timeout: 30))
    }

    private func data(path: String, query: [String: String] = [:], method: String = "GET",
                      body: Data? = nil, timeout: Double) async throws -> Data {
        guard var components = URLComponents(string: server.absoluteString + path) else { throw APIError.invalidServer }
        if !query.isEmpty {
            components.queryItems = query.sorted { $0.key < $1.key }.map { URLQueryItem(name: $0.key, value: $0.value) }
        }
        guard let url = components.url else { throw APIError.invalidServer }
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: timeout)
        request.httpMethod = method
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let body {
            request.httpBody = body
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        let (data, response) = try await session.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else {
            let detail = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["detail"] as? String
            throw APIError.http(status: status, detail: detail ?? "")
        }
        return data
    }
}
