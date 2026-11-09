import Foundation
import Testing
@testable import MHubKit

/// Library sync, version order and account fixtures shared with Android
/// (`contract/library-ops-cases.json`, `contract/version-cases.json`).
@Suite struct AccountTests {
    struct ContractPlaylist: Decodable {
        var id: String
        var name: String
        var source_url: String?
        var tracks: [String]

        var playlist: Playlist {
            Playlist(id: id, name: name, tracks: tracks.map(AccountTests.track), sourceURL: source_url ?? "")
        }
    }

    struct Cases: Decodable {
        struct Apply: Decodable { var name: String; var before: [ContractPlaylist]; var ops: [LibraryOp]; var after: [ContractPlaylist] }
        struct Move: Decodable { var key: String; var after: String? }
        struct Reorder: Decodable { var name: String; var from: [String]; var to: [String]; var moves: [Move] }
        struct Merge: Decodable {
            struct Entry: Decodable { var local: String; var cloud: String; var keys: [String] }
            var name: String; var local: [ContractPlaylist]; var cloud: [ContractPlaylist]; var create: [String]; var merge: [Entry]
        }
        var apply: [Apply]
        var reorder: [Reorder]
        var merge: [Merge]
    }

    static func track(_ key: String) -> Track {
        let parts = key.split(separator: ":", maxSplits: 1).map(String.init)
        return Track(platform: parts[0], sourceID: parts.count > 1 ? parts[1] : "", title: key, artist: "")
    }

    static let cases: Cases = {
        let url = Fixtures.contract.appendingPathComponent("library-ops-cases.json")
        return try! JSONDecoder().decode(Cases.self, from: Data(contentsOf: url))
    }()

    static func summary(_ list: [Playlist]) -> [String] {
        list.map { "\($0.id)|\($0.name)|\($0.tracks.map(\.id).joined(separator: ","))" }
    }

    @Test func localReplayMatchesTheServerRules() {
        for item in Self.cases.apply {
            let result = LibrarySync.apply(item.before.map(\.playlist), item.ops, now: .now)
            #expect(Self.summary(result) == Self.summary(item.after.map(\.playlist)), "\(item.name)")
        }
    }

    @Test func dragReorderBecomesTheFewestMoves() {
        for item in Self.cases.reorder {
            let moves = LibrarySync.reorderMoves(from: item.from, to: item.to)
            #expect(moves.map(\.key) == item.moves.map(\.key), "\(item.name)")
            #expect(moves.map(\.after) == item.moves.map(\.after), "\(item.name)")
            let start = [Playlist(id: "p", name: "p", tracks: item.from.map(Self.track))]
            let replayed = LibrarySync.apply(start, moves.map { .move(id: "p", key: $0.key, after: $0.after) }, now: .now)
            #expect(replayed[0].tracks.map(\.id) == item.to, "\(item.name)")
        }
    }

    @Test func firstLoginMergeMatchesTheWebPlan() {
        for item in Self.cases.merge {
            let plan = LibrarySync.planMerge(local: item.local.map(\.playlist), cloud: item.cloud.map(\.playlist))
            #expect(plan.create.map(\.id) == item.create, "\(item.name)")
            #expect(plan.merge.map { "\($0.local.id)>\($0.cloudID):\($0.tracks.map(\.id).joined(separator: ","))" }
                == item.merge.map { "\($0.local)>\($0.cloud):\($0.keys.joined(separator: ","))" }, "\(item.name)")
        }
    }

    @Test func opsEncodeAsTheServerExpects() throws {
        let data = try JSONEncoder().encode([LibraryOp.move(id: "p", key: "netease:1", after: nil)])
        let object = try #require(try JSONSerialization.jsonObject(with: data) as? [[String: Any]])
        #expect(object[0]["op"] as? String == "move")
        #expect(object[0].keys.contains("after"))
        #expect(object[0]["after"] is NSNull)
    }

    @Test func accountFixturesDecode() throws {
        let me = try Fixtures.decode(MeResponse.self, "auth-me.json")
        #expect(me.user?.username == "alice")
        #expect(try Fixtures.decode(LoginResponse.self, "auth-register.json").recoveryCodes.count == 8)
        let library = try Fixtures.decode(LibrarySnapshot.self, "library-snapshot.json").library
        #expect(library[0].tracks.map(\.id) == ["netease:1", "applemusic:1440833098"])
        #expect(Int64(library[0].createdAt.timeIntervalSince1970 * 1000) == 1_762_000_000_123)
        #expect(library[1].sourceURL == "https://music.example/playlist?id=123")
    }

    @Test func sessionCookieIsReadFromSetCookie() {
        #expect(MHubClient.sessionToken(fromSetCookie: "mhub_session=abc; Path=/; HttpOnly; SameSite=Lax") == "abc")
        #expect(MHubClient.sessionToken(fromSetCookie: "other=1, mhub_session=xyz; Path=/") == "xyz")
        #expect(MHubClient.sessionToken(fromSetCookie: "mhub_session=; Path=/; Max-Age=0") == "")
        #expect(MHubClient.sessionToken(fromSetCookie: "other=1") == nil)
    }

    @Test func versionsCompareLikeTheContract() throws {
        struct File: Decodable { var cases: [[JSONValue]] }
        let url = Fixtures.contract.appendingPathComponent("version-cases.json")
        for item in try JSONDecoder().decode(File.self, from: Data(contentsOf: url)).cases {
            guard case let .string(a) = item[0], case let .string(b) = item[1], case let .number(sign) = item[2] else {
                Issue.record("bad case"); continue
            }
            let left = try #require(AppVersion(a)), right = try #require(AppVersion(b))
            #expect(AppVersion.compare(left, right) == Int(sign), "\(a) vs \(b)")
        }
    }

    @Test func releaseNotesBecomePlainText() {
        #expect(UpdateCheck.summary("## 变化\n\n- 歌单同步\n见 [MHub](https://x) 与 `/health`") == "变化\n• 歌单同步\n见 MHub 与 /health")
    }

    @Test func newestPublishedReleaseIsOffered() throws {
        let releases = try UpdateCheck.decode(Fixtures.data("github-releases.json"))
        let update = try #require(UpdateCheck.newer(releases, current: "0.1.0-beta.1", assetSuffix: ".apk"))
        #expect(update.version.description == "0.1.0-beta.2")
        #expect(update.download?.lastPathComponent == "MHub-0.1.0-beta.2.apk")
        #expect(UpdateCheck.newer(releases, current: "0.1.0-beta.2", assetSuffix: ".apk") == nil)
        #expect(UpdateCheck.newer(releases, current: "0.1.0", assetSuffix: ".apk") == nil)
        #expect(UpdateCheck.newer(releases, current: "0.1.0-beta.1", assetSuffix: ".ipa")?.download == nil)
    }
}
