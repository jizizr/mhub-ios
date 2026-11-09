import Foundation

/// Semantic version order (`contract/version-cases.json`); a leading `v` and build metadata are ignored.
public struct AppVersion: Comparable, Sendable, CustomStringConvertible {
    public var core: [Int]
    public var prerelease: [String]

    public init?(_ text: String) {
        var value = text.trimmingCharacters(in: .whitespaces)
        if value.hasPrefix("v") { value.removeFirst() }
        if let plus = value.firstIndex(of: "+") { value = String(value[..<plus]) }
        let parts = value.split(separator: "-", maxSplits: 1, omittingEmptySubsequences: false)
        let numbers = parts[0].split(separator: ".", omittingEmptySubsequences: false).map { Int($0) }
        guard !numbers.isEmpty, numbers.allSatisfy({ $0 != nil }) else { return nil }
        core = numbers.compactMap { $0 }
        prerelease = parts.count > 1 ? parts[1].split(separator: ".").map(String.init) : []
    }

    public var description: String {
        core.map(String.init).joined(separator: ".") + (prerelease.isEmpty ? "" : "-" + prerelease.joined(separator: "."))
    }

    public static func compare(_ a: AppVersion, _ b: AppVersion) -> Int {
        for index in 0..<max(a.core.count, b.core.count) {
            let left = index < a.core.count ? a.core[index] : 0
            let right = index < b.core.count ? b.core[index] : 0
            if left != right { return left < right ? -1 : 1 }
        }
        // A release is newer than any of its pre-releases.
        if a.prerelease.isEmpty || b.prerelease.isEmpty {
            return min(b.prerelease.count, 1) - min(a.prerelease.count, 1)
        }
        for (left, right) in zip(a.prerelease, b.prerelease) {
            let difference: Int
            switch (Int(left), Int(right)) {
            case let (l?, r?): difference = l == r ? 0 : (l < r ? -1 : 1)
            case (_?, nil): difference = -1
            case (nil, _?): difference = 1
            default: difference = left == right ? 0 : (left < right ? -1 : 1)
            }
            if difference != 0 { return difference }
        }
        return a.prerelease.count == b.prerelease.count ? 0 : (a.prerelease.count < b.prerelease.count ? -1 : 1)
    }

    public static func < (a: AppVersion, b: AppVersion) -> Bool { compare(a, b) < 0 }
    public static func == (a: AppVersion, b: AppVersion) -> Bool { compare(a, b) == 0 }
}

public struct GitHubRelease: Decodable, Sendable {
    public struct Asset: Decodable, Sendable {
        public var name: String
        public var url: String
        enum CodingKeys: String, CodingKey {
            case name
            case url = "browser_download_url"
        }
    }

    public var tag: String
    public var body: String?
    public var page: String
    public var draft: Bool
    public var assets: [Asset]

    enum CodingKeys: String, CodingKey {
        case body, draft, assets
        case tag = "tag_name"
        case page = "html_url"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        tag = try c.decode(String.self, forKey: .tag)
        body = try c.decodeIfPresent(String.self, forKey: .body)
        page = try c.decode(String.self, forKey: .page)
        draft = try c.decodeIfPresent(Bool.self, forKey: .draft) ?? false
        assets = try c.decodeIfPresent([Asset].self, forKey: .assets) ?? []
    }
}

/// A release newer than the running app.
public struct AvailableUpdate: Sendable, Identifiable {
    public var version: AppVersion
    public var notes: String
    public var page: URL
    public var download: URL?
    public var id: String { version.description }
}

public enum UpdateCheck {
    /// The newest published release (pre-releases included) if it is newer than `current`.
    public static func newer(_ releases: [GitHubRelease], current: String, assetSuffix: String) -> AvailableUpdate? {
        guard let running = AppVersion(current) else { return nil }
        let candidates = releases.filter { !$0.draft }.compactMap { release in AppVersion(release.tag).map { ($0, release) } }
        guard let latest = candidates.max(by: { $0.0 < $1.0 }), latest.0 > running,
              let page = URL(string: latest.1.page) else { return nil }
        return AvailableUpdate(
            version: latest.0,
            notes: (latest.1.body ?? "").trimmingCharacters(in: .whitespacesAndNewlines),
            page: page,
            download: latest.1.assets.first { $0.name.hasSuffix(assetSuffix) }.flatMap { URL(string: $0.url) })
    }

    /// The first `lines` lines of release notes as plain text (Markdown links, marks and headings removed).
    public static func summary(_ notes: String, lines: Int = 6) -> String {
        notes.components(separatedBy: .newlines)
            .map { line in
                line.replacingOccurrences(of: #"\[([^\]]+)\]\([^)]*\)"#, with: "$1", options: .regularExpression)
                    .replacingOccurrences(of: "[`*_]", with: "", options: .regularExpression)
                    .replacingOccurrences(of: #"^\s*#+\s*"#, with: "", options: .regularExpression)
                    .replacingOccurrences(of: #"^\s*[-+]\s+"#, with: "• ", options: .regularExpression)
                    .trimmingCharacters(in: .whitespaces)
            }
            .filter { !$0.isEmpty }
            .prefix(lines)
            .joined(separator: "\n")
    }

    public static func decode(_ data: Data) throws -> [GitHubRelease] {
        try JSONDecoder().decode([GitHubRelease].self, from: data)
    }

    /// Asks GitHub for the repository's recent releases.
    public static func fetch(repository: String, session: URLSession = .shared) async throws -> [GitHubRelease] {
        guard let url = URL(string: "https://api.github.com/repos/\(repository)/releases?per_page=10") else { throw APIError.invalidServer }
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 15)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("MHub-App", forHTTPHeaderField: "User-Agent")
        let (data, response) = try await session.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else { throw APIError.http(status: status, detail: "") }
        return try decode(data)
    }
}
