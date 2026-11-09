import Foundation

public enum APIError: LocalizedError, Equatable {
    case invalidServer
    case http(status: Int, detail: String)
    case playbackFailed(String)
    /// No source can ever play the song (server code `unplayable`): skip it, never retry.
    case unplayable(String)
    case timedOut
    /// HTTP 429 that outlasted the caller's wait limit.
    case rateLimited(retryAfterMs: Int, detail: String)

    public var errorDescription: String? {
        switch self {
        case .invalidServer: "服务器地址无效"
        case let .http(status, detail): detail.isEmpty ? "HTTP \(status)" : detail
        case let .playbackFailed(message): message.isEmpty ? "播放准备失败" : message
        case let .unplayable(message): message.isEmpty ? "暂时无法播放" : message
        case .timedOut: "等待音频超时，请重试"
        case let .rateLimited(retryAfterMs, detail):
            "\(detail.isEmpty ? "请求过于频繁" : detail)（约 \(RateLimit.seconds(retryAfterMs)) 秒后可重试）"
        }
    }
}

/// When a playback task can be handed to the system player. The rule is shared
/// with Android; see `docs/api-contract.md`.
public enum PlaybackReadiness: Equatable, Sendable {
    case ready(URL)
    case wait(since: String)
    case failed(String)
    /// No source can ever play it (`error_code: unplayable`).
    case unplayable(String)

    public static let unplayableCode = "unplayable"

    public static func evaluate(_ task: PlaybackTask, server: URL) -> PlaybackReadiness {
        switch task.status {
        case .failed:
            return task.errorCode == unplayableCode ? .unplayable(task.error ?? "") : .failed(task.error ?? "")
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
    /// Waits out a 429; tests replace it to record waits instead of sleeping.
    let sleep: @Sendable (Int) async throws -> Void
    /// The signed-in account's session; nil for guests.
    public let account: SessionStore?

    public init(server: URL, session: URLSession = .shared, account: SessionStore? = nil) {
        self.init(server: server, session: session, account: account) { try await Task.sleep(for: .milliseconds($0)) }
    }

    init(server: URL, session: URLSession, account: SessionStore? = nil, sleep: @escaping @Sendable (Int) async throws -> Void) {
        self.server = server
        self.session = session
        self.account = account
        self.sleep = sleep
    }

    public static let sessionCookie = "mhub_session"

    /// The session token a `Set-Cookie` header carries: a value, "" when cleared, nil when absent.
    public static func sessionToken(fromSetCookie header: String?) -> String? {
        guard let header else { return nil }
        // Several cookies may be folded into one header with commas; expiry dates contain commas too.
        for part in header.components(separatedBy: "\(sessionCookie)=").dropFirst() {
            let value = String(part.prefix { $0 != ";" && $0 != "," })
            let attributes = part.lowercased()
            if attributes.contains("max-age=0") { return "" }
            return value
        }
        return nil
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

    public func collection(platform: String, url: String, rateLimit: RateLimitPolicy = .standard) async throws -> Collection {
        try await get("/api/v1/collections/resolve", ["platform": platform, "url": url], timeout: 60, rateLimit: rateLimit)
    }

    public func lyrics(for track: Track) async throws -> LyricsPayload {
        var query = ["platform": track.platform, "track_id": track.sourceID]
        if !track.title.isEmpty { query["title"] = track.title }
        if !track.artist.isEmpty { query["artist"] = track.artist }
        if !track.album.isEmpty { query["album"] = track.album }
        if let duration = track.durationMs, duration > 0 { query["duration"] = String(duration / 1000) }
        return try await get("/api/v1/lyrics", query)
    }

    public func createPlayback(_ track: Track, quality: Quality, rateLimit: RateLimitPolicy = .standard) async throws -> PlaybackTask {
        let response: CreatePlaybackResponse = try await post("/api/v1/playbacks", body: [
            "platform": track.platform, "query": track.title, "selected_id": track.sourceID,
            "quality": quality.rawValue, "include_cover": false,
        ], rateLimit: rateLimit)
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
    /// `rateLimit` covers creating the task; the deadline starts once it exists.
    public func preparePlayback(_ track: Track, quality: Quality, rateLimit: RateLimitPolicy = .standard,
                                deadline: Duration = .seconds(180)) async throws -> (task: PlaybackTask, url: URL) {
        var task = try await createPlayback(track, quality: quality, rateLimit: rateLimit)
        let clock = ContinuousClock()
        let end = clock.now.advanced(by: deadline)
        while true {
            try Task.checkCancellation()
            switch PlaybackReadiness.evaluate(task, server: server) {
            case let .ready(url): return (task, url)
            case let .failed(message): throw APIError.playbackFailed(message)
            case let .unplayable(message): throw APIError.unplayable(message)
            case let .wait(since):
                guard clock.now < end else { throw APIError.timedOut }
                task = try await playback(id: task.id, since: since)
            }
        }
    }

    // MARK: Account and library sync (docs/api-contract.md「账号与同步」)

    /// This install as the server names it in the session list.
    public struct Device: Sendable {
        public var id: String
        public var name: String
        public init(id: String, name: String) {
            self.id = id
            self.name = name
        }
        func body(_ fields: [String: Any]) -> [String: Any] {
            fields.merging(["device_id": id, "device_name": name]) { left, _ in left }
        }
    }

    public func authConfig() async throws -> AuthConfig { try await get("/api/v1/auth/config") }

    public func me() async throws -> AccountUser? {
        let response: MeResponse = try await get("/api/v1/auth/me")
        return response.user
    }

    public func login(username: String, password: String, device: Device) async throws -> LoginResponse {
        try await post("/api/v1/auth/password/login", body: device.body(["username": username, "password": password]))
    }

    public func recoveryLogin(username: String, code: String, device: Device) async throws -> LoginResponse {
        try await post("/api/v1/auth/recovery/login", body: device.body(["username": username, "code": code]))
    }

    public func register(username: String, password: String, device: Device) async throws -> LoginResponse {
        try await post("/api/v1/auth/register", body: device.body(["username": username, "password": password]))
    }

    public func logout() async throws {
        _ = try await data(path: "/api/v1/auth/logout", method: "POST", body: Data("{}".utf8), timeout: 15)
        account?.token = nil
    }

    public func librarySnapshot() async throws -> LibrarySnapshot { try await get("/api/v1/sync/library/json") }

    public func libraryOps(_ ops: [LibraryOp]) async throws -> LibrarySnapshot {
        struct Body: Encodable { var ops: [LibraryOp] }
        let payload = try JSONEncoder().encode(Body(ops: ops))
        let response = try await data(path: "/api/v1/sync/library/json", method: "POST", body: payload, timeout: 30)
        return try JSONDecoder().decode(LibrarySnapshot.self, from: response)
    }

    // MARK: Download

    /// Creates the task at `quality` and waits until the whole file is ready (not just streamable).
    public func completedPlayback(_ track: Track, quality: Quality, rateLimit: RateLimitPolicy,
                                  deadline: Duration = .seconds(600)) async throws -> PlaybackTask {
        var task = try await createPlayback(track, quality: quality, rateLimit: rateLimit)
        let clock = ContinuousClock()
        let end = clock.now.advanced(by: deadline)
        while task.status != .completed {
            try Task.checkCancellation()
            if task.status == .failed {
                throw task.errorCode == PlaybackReadiness.unplayableCode ? APIError.unplayable(task.error ?? "") : APIError.playbackFailed(task.error ?? "")
            }
            guard clock.now < end else { throw APIError.timedOut }
            task = try await playback(id: task.id, since: task.status.rawValue)
        }
        return task
    }

    /// The whole file of a completed task, with the account session.
    public func audioRequest(for task: PlaybackTask) -> URLRequest? {
        let path = "/api/v1/playbacks/" + (task.id.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? task.id) + "/audio"
        guard let url = Self.resolve(path, against: server) else { return nil }
        var request = URLRequest(url: url, timeoutInterval: 120)
        authorize(&request)
        return request
    }

    /// Account requests carry the session cookie; writes also need the client header.
    private func authorize(_ request: inout URLRequest) {
        request.httpShouldHandleCookies = false
        request.setValue("1", forHTTPHeaderField: "x-mhub-client")
        if let token = account?.token, !token.isEmpty {
            request.setValue("\(Self.sessionCookie)=\(token)", forHTTPHeaderField: "Cookie")
        }
    }

    // MARK: Transport

    private func get<T: Decodable>(_ path: String, _ query: [String: String] = [:], timeout: Double = 20,
                                   rateLimit: RateLimitPolicy = .standard) async throws -> T {
        try await JSONDecoder().decode(T.self, from: data(path: path, query: query, timeout: timeout, rateLimit: rateLimit))
    }

    private func post<T: Decodable>(_ path: String, body: [String: Any], rateLimit: RateLimitPolicy = .standard) async throws -> T {
        let payload = try JSONSerialization.data(withJSONObject: body)
        return try await JSONDecoder().decode(T.self, from: data(path: path, method: "POST", body: payload, timeout: 30,
                                                                  rateLimit: rateLimit))
    }

    /// One request; HTTP 429 is waited out and resent within `rateLimit`.
    private func data(path: String, query: [String: String] = [:], method: String = "GET",
                      body: Data? = nil, timeout: Double, rateLimit: RateLimitPolicy = .standard) async throws -> Data {
        guard var components = URLComponents(string: server.absoluteString + path) else { throw APIError.invalidServer }
        if !query.isEmpty {
            components.queryItems = query.sorted { $0.key < $1.key }.map { URLQueryItem(name: $0.key, value: $0.value) }
        }
        guard let url = components.url else { throw APIError.invalidServer }
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: timeout)
        request.httpMethod = method
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        authorize(&request)
        if let body {
            request.httpBody = body
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        let session = session
        return try await RateLimit.run(rateLimit, sleep: sleep) {
            let (data, response) = try await session.data(for: request)
            let http = response as? HTTPURLResponse
            // The server slides the session forward or clears it on logout.
            if let token = Self.sessionToken(fromSetCookie: http?.value(forHTTPHeaderField: "Set-Cookie")) {
                account?.token = token.isEmpty ? nil : token
            }
            let status = http?.statusCode ?? 0
            guard (200..<300).contains(status) else {
                let payload = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
                let detail = payload?["detail"] as? String ?? ""
                if payload?["code"] as? String == PlaybackReadiness.unplayableCode { throw APIError.unplayable(detail) }
                if status == 429 {
                    throw APIError.rateLimited(retryAfterMs: RateLimit.retryAfterMs(http?.value(forHTTPHeaderField: "Retry-After")),
                                               detail: detail)
                }
                throw APIError.http(status: status, detail: detail)
            }
            return data
        }
    }
}
