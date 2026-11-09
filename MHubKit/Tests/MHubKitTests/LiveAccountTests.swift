import Foundation
import Testing
@testable import MHubKit

/// Against a disposable local server with accounts enabled:
/// `MHUB_TEST_SERVER=http://127.0.0.1:18080 MHUB_TEST_USER=… MHUB_TEST_PASSWORD=… swift test`.
@Suite(.enabled(if: ProcessInfo.processInfo.environment["MHUB_TEST_SERVER"] != nil))
struct LiveAccountTests {
    final class Store: SessionStore, @unchecked Sendable { var token: String? }

    @Test func signInEditAndSignOut() async throws {
        let env = ProcessInfo.processInfo.environment
        let server = try #require(URL(string: env["MHUB_TEST_SERVER"] ?? ""))
        let store = Store()
        let client = MHubClient(server: server, account: store)
        let device = MHubClient.Device(id: "swift-test", name: "swift test")
        _ = try await client.login(username: env["MHUB_TEST_USER"] ?? "", password: env["MHUB_TEST_PASSWORD"] ?? "", device: device)
        #expect(store.token?.isEmpty == false)
        #expect(try await client.me()?.username == env["MHUB_TEST_USER"])
        let id = "swift-" + UUID().uuidString
        let track = SyncTrack(Track(platform: "netease", sourceID: "1", title: "一", artist: "人"))
        var snapshot = try await client.libraryOps([.create(id: id, name: "Swift", sourceURL: "", sourcePlatform: "", tracks: [track])])
        #expect(snapshot.library.contains { $0.id == id && $0.tracks.map(\.id) == ["netease:1"] })
        snapshot = try await client.libraryOps([.delete(id: id)])
        #expect(!snapshot.library.contains { $0.id == id })
        try await client.logout()
        #expect(store.token == nil)
        #expect(try await client.me() == nil)
    }
}
