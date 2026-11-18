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
        #expect(platforms.map(\.id) == ["applemusic", "netease", "tencent", "bilibili"])
        #expect(platforms[0].hasAlbums && platforms[0].hasArtists)
        #expect(platforms[2].hasAlbums && !platforms[2].hasArtists)
        #expect(!platforms[3].hasAlbums)
        // Servers before catalog search list no sections.
        let old = try JSONDecoder().decode(PlatformInfo.self, from: Data(#"{"id":"netease","label":"网易云音乐"}"#.utf8))
        #expect(old.catalog.isEmpty && !old.hasAlbums)
    }

    @Test func decodesCatalogSearchSections() throws {
        let found = try Fixtures.decode(CatalogSearch.self, "catalog-search.json")
        #expect(found.visibleSections == [.top, .artists, .albums, .songs, .playlists])
        #expect(found.top.map(\.type) == [CatalogItem.artist, CatalogItem.song])
        let song = found.songs[0].track
        #expect(song.id == "applemusic:536115195" && song.album == "七里香" && song.durationMs == 297_200)
        #expect(found.albums[0].cardSubtitle(withKind: false) == "2001 · 周杰伦")
        #expect(found.albums[0].cardSubtitle(withKind: true) == "专辑 · 周杰伦")
        #expect(found.playlists[0].url.hasPrefix("https://music.apple.com/"))
        let songsOnly = try Fixtures.decode(CatalogSearch.self, "catalog-search-songs-only.json")
        #expect(songsOnly.visibleSections.isEmpty && songsOnly.songs.count == 1)
    }

    @Test func decodesAlbumArtistAndTrackInfo() throws {
        let album = try Fixtures.decode(AlbumDetail.self, "album.json")
        #expect(album.artistID == "300117743")
        #expect(album.discs.map(\.disc) == [1, 2])
        #expect(album.discs[0].tracks.map(\.item.trackNumber) == [1, 2])
        #expect(album.discs[1].tracks.map(\.index) == [2])
        #expect(album.footer == ["2001年9月14日", "3 首歌曲，12 分钟", "℗ 2001 JVR MUSIC INTERNATIONAL LTD."])
        let artist = try Fixtures.decode(ArtistDetail.self, "artist.json")
        #expect(artist.topSongs.first?.track.album == "七里香")
        #expect(artist.albums.count == 1 && artist.singles.count == 1)
        let info = try Fixtures.decode(TrackInfo.self, "track-info.json")
        #expect(info.albumID == "003DFRzD192KKD" && info.artistID.isEmpty)
        #expect(AlbumDetail.releaseText("2004") == "2004年")
        #expect(AlbumDetail.summary([]) == "")
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
