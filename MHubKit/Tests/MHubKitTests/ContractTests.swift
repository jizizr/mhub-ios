import Foundation
import Testing
@testable import MHubKit

@Suite struct ContractTests {
    let server = URL(string: "https://mhub.example.test")!

    @Test func decodesSearchAsTracks() throws {
        let items = try Fixtures.decode([SearchItem].self, "search.json")
        #expect(items.count == 2)
        let track = items[0].track
        #expect(track.id == "applemusic:1440818839")
        #expect(track.title == "有没有" && track.artist == "陈奕迅")
        #expect(items[1].track.cover == "")
    }

    @Test func decodesHomeContinuationCollectionPlatforms() throws {
        let home = try Fixtures.decode(RecommendationHome.self, "recommendation-home.json")
        #expect(home.tags.first?.playlistIDs == ["pl.1"])
        #expect(home.playlists.first?.resourceType == "playlists")
        #expect(home.tracks.count == 1)
        let next = try Fixtures.decode(Continuation.self, "continuation.json")
        #expect(next.station == "ra.autoplay.abc" && next.tracks.count == 2)
        let collection = try Fixtures.decode(Collection.self, "collection.json")
        #expect(collection.title == "热歌榜" && collection.items.count == 2)
        let platforms = try Fixtures.decode([PlatformInfo].self, "platforms.json")
        #expect(platforms.map(\.id) == ["applemusic", "netease", "tencent"])
    }

    @Test func progressiveStreamingIsPlayable() throws {
        let response = try Fixtures.decode(CreatePlaybackResponse.self, "playback-streaming.json")
        #expect(response.playback.streamLength == 30_123_456)
        #expect(PlaybackReadiness.evaluate(response.playback, server: server)
            == .ready(URL(string: "https://mhub.example.test/api/v1/playbacks/netease--186016--lossless/audio?rev=native-v2")!))
    }

    @Test func remuxedStreamingWaits() throws {
        let task = try Fixtures.decode(PlaybackTask.self, "playback-remux-streaming.json")
        #expect(PlaybackReadiness.evaluate(task, server: server) == .wait(since: "streaming"))
    }

    @Test func processingWaitsAndKeepsMediaOrigin() throws {
        var task = try Fixtures.decode(PlaybackTask.self, "playback-processing.json")
        #expect(PlaybackReadiness.evaluate(task, server: server) == .wait(since: "processing"))
        task.status = .completed
        #expect(PlaybackReadiness.evaluate(task, server: server)
            == .ready(URL(string: "https://media.example.test/api/v1/playbacks/applemusic--1440818839--high/audio?rev=native-v3")!))
    }

    @Test func completedAndFailed() throws {
        let done = try Fixtures.decode(PlaybackTask.self, "playback-completed.json")
        #expect(done.duration == 246)
        guard case .ready = PlaybackReadiness.evaluate(done, server: server) else { Issue.record("not ready"); return }
        let failed = try Fixtures.decode(PlaybackTask.self, "playback-failed.json")
        #expect(PlaybackReadiness.evaluate(failed, server: server) == .failed("该歌曲需要付费"))
        // No source can ever play it: players skip it instead of retrying.
        let unplayable = try Fixtures.decode(PlaybackTask.self, "playback-unplayable.json")
        #expect(PlaybackReadiness.evaluate(unplayable, server: server) == .unplayable("Apple Music 暂无可用音源"))
    }

    @Test func serverAddressParsing() {
        #expect(MHubClient.serverURL(from: " music.example.test/ ")?.absoluteString == "https://music.example.test")
        #expect(MHubClient.serverURL(from: "http://127.0.0.1:8000")?.absoluteString == "http://127.0.0.1:8000")
        #expect(MHubClient.serverURL(from: "ftp://x.test") == nil)
        #expect(MHubClient.serverURL(from: "https://user:pw@x.test") == nil)
        #expect(MHubClient.serverURL(from: "") == nil)
        #expect(MHubClient.resolve("//evil.test/a", against: server) == nil)
        #expect(MHubClient.resolve("javascript:alert(1)", against: server) == nil)
    }

    @Test func trackJSONRoundTrips() throws {
        let track = Track(platform: "netease", sourceID: "1", title: "t", artist: "a", durationMs: 1000, isRecommendation: true)
        let decoded = try JSONDecoder().decode(Track.self, from: JSONEncoder().encode(track))
        #expect(decoded == track)
    }
}
