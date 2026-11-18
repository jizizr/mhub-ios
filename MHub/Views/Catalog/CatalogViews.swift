import MHubKit
import Perception
import SwiftUI

/// An album or artist page, pushed on the current tab's navigation stack.
/// A page opened from a song has no id yet: it looks it up through the
/// song's track info (docs/api-contract.md「分类搜索、专辑与艺人」).
struct CatalogRoute: Hashable {
    enum Kind: Hashable { case album, artist }

    var kind: Kind
    var platform: String
    var id: String
    var trackID = ""
    var title = ""
    var cover = ""

    static func album(of track: Track) -> CatalogRoute {
        CatalogRoute(kind: .album, platform: track.platform, id: "", trackID: track.sourceID, title: track.album, cover: track.cover)
    }

    static func artist(of track: Track) -> CatalogRoute {
        CatalogRoute(kind: .artist, platform: track.platform, id: "", trackID: track.sourceID, title: track.artist)
    }

    /// Where a catalog card leads: album and artist pages, or the playlist page.
    static func destination(of item: CatalogItem) -> AnyHashable? {
        switch item.type {
        case CatalogItem.album:
            CatalogRoute(kind: .album, platform: item.platform, id: item.itemID, title: item.title, cover: item.cover)
        case CatalogItem.artist:
            CatalogRoute(kind: .artist, platform: item.platform, id: item.itemID, title: item.title, cover: item.cover)
        case CatalogItem.playlist:
            CollectionRoute(platform: item.platform, url: item.url.isEmpty ? item.itemID : item.url, title: item.title, cover: item.cover)
        default:
            nil
        }
    }
}

extension View {
    /// Album, artist and playlist pages, registered once on every tab's stack.
    func catalogDestinations() -> some View {
        navigationDestination(for: CatalogRoute.self) { route in
            switch route.kind {
            case .album: AlbumView(route: route)
            case .artist: ArtistView(route: route)
            }
        }
        .navigationDestination(for: CollectionRoute.self) { CollectionView(route: $0) }
    }
}

// MARK: Cards

/// An Apple Music lockup: square artwork (round for artists) over one or two lines.
struct CatalogCard: View {
    var item: CatalogItem
    var withKind = false
    var width: CGFloat = 150

    private var isArtist: Bool { item.type == CatalogItem.artist }

    var body: some View {
        WithPerceptionTracking {
            VStack(alignment: isArtist ? .center : .leading, spacing: 5) {
                ArtworkView(url: item.coverURL, cornerRadius: isArtist ? width / 2 : 10)
                    .frame(width: width, height: width)
                Text(item.title).font(.subheadline).lineLimit(1).foregroundStyle(.primary)
                let subtitle = item.cardSubtitle(withKind: withKind)
                Text(subtitle.isEmpty && isArtist ? CatalogItem.kindLabel(CatalogItem.artist) : subtitle)
                    .font(.footnote).foregroundStyle(.secondary).lineLimit(1)
            }
            .frame(width: width, alignment: isArtist ? .center : .leading)
            .contentShape(.rect)
        }
    }
}

/// A card that opens its page, or plays a song in place.
struct CatalogLink: View {
    @Environment(PlayerController.self) private var player
    var item: CatalogItem
    var withKind = false
    var width: CGFloat = 150

    var body: some View {
        WithPerceptionTracking {
            if let destination = CatalogRoute.destination(of: item) {
                NavigationLink(value: destination) {
                    CatalogCard(item: item, withKind: withKind, width: width)
                }
                .buttonStyle(.plain)
            } else {
                Button {
                    player.playNow(item.track)
                } label: {
                    CatalogCard(item: item, withKind: withKind, width: width)
                }
                .buttonStyle(.plain)
                .contextMenu {
                    WithPerceptionTracking {
                        TrackMenuItems(tracks: [item.track])
                    }
                }
            }
        }
    }
}

/// A titled horizontal shelf of cards.
struct CatalogShelf: View {
    var title: String
    var items: [CatalogItem]
    var withKind = false
    /// The title opens the full section (search tabs).
    var onMore: (() -> Void)?

    var body: some View {
        WithPerceptionTracking {
            VStack(alignment: .leading, spacing: 10) {
                if !title.isEmpty {
                    if let onMore {
                        Button(action: onMore) {
                            HStack(spacing: 2) {
                                Text(title).font(.title3.bold())
                                Image(systemName: "chevron.right").font(.subheadline.bold()).foregroundStyle(.secondary)
                            }
                            .foregroundStyle(.primary)
                        }
                        .buttonStyle(.plain)
                        .padding(.horizontal, 20)
                    } else {
                        Text(title).font(.title3.bold()).padding(.horizontal, 20)
                    }
                }
                ScrollView(.horizontal) {
                    LazyHStack(alignment: .top, spacing: 14) {
                        WithPerceptionTracking {
                            ForEach(items) { item in
                                WithPerceptionTracking {
                                    CatalogLink(item: item, withKind: withKind)
                                }
                            }
                        }
                    }
                    .shelfScrollTargets()
                    .padding(.horizontal, 20)
                }
                .shelfScrollBehavior()
                .scrollIndicators(.hidden)
                .shelfPager(ids: items.map(\.id), perPage: 4, artworkHeight: 150)
            }
        }
    }
}

/// A whole section as a grid of cards (search tabs other than songs).
struct CatalogGrid: View {
    var items: [CatalogItem]

    var body: some View {
        WithPerceptionTracking {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 150, maximum: 220), spacing: 14, alignment: .top)], spacing: 18) {
                WithPerceptionTracking {
                    ForEach(items) { item in
                        WithPerceptionTracking {
                            CatalogLink(item: item)
                        }
                    }
                }
            }
            .padding(.horizontal, 20)
        }
    }
}

// MARK: Album

struct AlbumView: View {
    @Environment(AppModel.self) private var app
    @Environment(PlayerController.self) private var player
    @Environment(LibraryStore.self) private var library
    var route: CatalogRoute
    @State private var album: AlbumDetail?
    @State private var error: String?

    var body: some View {
        WithPerceptionTracking {
            List {
                WithPerceptionTracking {
                    Section { header }
                        .listRowBackground(Color.clear)
                        .listRowSeparator(.hidden)
                    if let album {
                        ForEach(album.discs) { disc in
                            WithPerceptionTracking {
                                Section {
                                    ForEach(disc.tracks) { entry in
                                        WithPerceptionTracking {
                                            TrackRow(track: entry.item.track, number: entry.item.trackNumber ?? entry.index + 1,
                                                     showsArtist: entry.item.subtitle != album.artist) {
                                                play(album, from: entry.index)
                                            }
                                        }
                                    }
                                } header: {
                                    if disc.disc > 0 { Text(Strings.disc(disc.disc)) }
                                }
                            }
                        }
                        Section {
                            VStack(alignment: .leading, spacing: 2) {
                                ForEach(album.footer, id: \.self) { Text($0) }
                            }
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .listRowSeparator(.hidden)
                        }
                    } else if let error {
                        CatalogLoadError(message: error) { Task { await load() } }
                    } else {
                        ProgressView().frame(maxWidth: .infinity).listRowSeparator(.hidden)
                    }
                }
            }
            .listStyle(.plain)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                WithPerceptionTracking {
                    if let album, !album.tracks.isEmpty {
                        Button(Strings.addToLibrary, systemImage: "plus") {
                            let playlist = library.create(name: album.artist.isEmpty ? album.title : "\(album.title) - \(album.artist)",
                                                          tracks: album.tracks.map(\.track),
                                                          sourceURL: album.url, sourcePlatform: album.platform)
                            app.show(Strings.savedToLibrary(playlist.name, playlist.tracks.count))
                        }
                    }
                }
            }
            .task { if album == nil { await load() } }
        }
    }

    private var header: some View {
        VStack(spacing: 8) {
            ArtworkView(url: album?.coverURL ?? URL(string: route.cover), cornerRadius: 12)
                .frame(width: 240, height: 240)
                .shadow(color: .black.opacity(0.18), radius: 16, y: 8)
                .padding(.bottom, 6)
            Text(album?.title ?? route.title).font(.title2.bold()).multilineTextAlignment(.center)
            if let album {
                if !album.artistID.isEmpty, app.hasArtists(album.platform) {
                    NavigationLink(value: CatalogRoute(kind: .artist, platform: album.platform, id: album.artistID, title: album.artist)) {
                        Text(album.artist).font(.title3).foregroundStyle(Color.accentColor)
                    }
                    .buttonStyle(.plain)
                } else {
                    Text(album.artist).font(.title3).foregroundStyle(Color.accentColor)
                }
                let meta = [album.genre, String(album.releaseDate.prefix(4))].filter { !$0.isEmpty }.joined(separator: " · ")
                if !meta.isEmpty { Text(meta).font(.caption.weight(.semibold)).foregroundStyle(.secondary) }
                PlayShuffleButtons(tracks: album.tracks.map(\.track), source: source(album)).padding(.top, 8)
            }
        }
        .frame(maxWidth: .infinity)
    }

    private func source(_ album: AlbumDetail) -> QueueSource {
        QueueSource(type: QueueSource.album, name: album.title, id: album.id, platform: album.platform, url: album.url, cover: album.cover)
    }

    /// A tapped song plays the album from there; shuffle keeps it first.
    private func play(_ album: AlbumDetail, from index: Int) {
        player.play(album.tracks.map(\.track), startAt: index, keepStart: true, source: source(album))
    }

    private func load() async {
        guard let client = app.client else { return }
        error = nil
        do {
            var id = route.id
            if id.isEmpty {
                id = try await client.trackInfo(platform: route.platform, id: route.trackID).albumID
                if id.isEmpty { throw CatalogPageError(message: Strings.noAlbumFound) }
            }
            album = try await client.album(platform: route.platform, id: id)
        } catch is CancellationError {
        } catch {
            if (error as? URLError)?.code == .cancelled { return }
            self.error = error.localizedDescription
        }
    }
}

// MARK: Artist

struct ArtistView: View {
    @Environment(AppModel.self) private var app
    @Environment(PlayerController.self) private var player
    var route: CatalogRoute
    @State private var artist: ArtistDetail?
    @State private var error: String?

    var body: some View {
        WithPerceptionTracking {
            List {
                WithPerceptionTracking {
                    Section { header }
                        .listRowBackground(Color.clear)
                        .listRowSeparator(.hidden)
                    if let artist {
                        if !artist.topSongs.isEmpty {
                            Section {
                                ForEach(artist.topSongs.prefix(10)) { item in
                                    WithPerceptionTracking {
                                        TrackRow(track: item.track) {
                                            play(artist, from: artist.topSongs.firstIndex(of: item) ?? 0)
                                        }
                                    }
                                }
                            } header: {
                                Text(Strings.topSongs).font(.title3.bold()).foregroundStyle(.primary).textCase(nil)
                            }
                        }
                        if !artist.albums.isEmpty { shelf(Strings.albums, artist.albums) }
                        if !artist.singles.isEmpty { shelf(Strings.singlesAndEPs, artist.singles) }
                    } else if let error {
                        CatalogLoadError(message: error) { Task { await load() } }
                    } else {
                        ProgressView().frame(maxWidth: .infinity).listRowSeparator(.hidden)
                    }
                }
            }
            .listStyle(.plain)
            .navigationBarTitleDisplayMode(.inline)
            .task { if artist == nil { await load() } }
        }
    }

    private func shelf(_ title: String, _ items: [CatalogItem]) -> some View {
        CatalogShelf(title: title, items: items)
            .listRowInsets(EdgeInsets(top: 16, leading: 0, bottom: 8, trailing: 0))
            .listRowSeparator(.hidden)
    }

    private var header: some View {
        VStack(spacing: 12) {
            ArtworkView(url: artist?.coverURL ?? URL(string: route.cover), cornerRadius: 100)
                .frame(width: 200, height: 200)
                .shadow(color: .black.opacity(0.18), radius: 16, y: 8)
            Text(artist?.name ?? route.title).font(.largeTitle.bold()).multilineTextAlignment(.center)
            if let artist, !artist.topSongs.isEmpty {
                PlayShuffleButtons(tracks: artist.topSongs.map(\.track), source: source(artist)).padding(.top, 4)
            }
        }
        .frame(maxWidth: .infinity)
    }

    private func source(_ artist: ArtistDetail) -> QueueSource {
        QueueSource(type: QueueSource.artist, name: artist.name, id: artist.id, platform: artist.platform, cover: artist.cover)
    }

    private func play(_ artist: ArtistDetail, from index: Int) {
        player.play(artist.topSongs.map(\.track), startAt: index, keepStart: true, source: source(artist))
    }

    private func load() async {
        guard let client = app.client else { return }
        error = nil
        do {
            var id = route.id
            if id.isEmpty {
                id = try await client.trackInfo(platform: route.platform, id: route.trackID).artistID
                if id.isEmpty { throw CatalogPageError(message: Strings.noArtistFound) }
            }
            artist = try await client.artist(platform: route.platform, id: id)
        } catch is CancellationError {
        } catch {
            if (error as? URLError)?.code == .cancelled { return }
            self.error = error.localizedDescription
        }
    }
}

struct CatalogPageError: LocalizedError {
    var message: String
    var errorDescription: String? { message }
}

private struct CatalogLoadError: View {
    var message: String
    var retry: () -> Void

    var body: some View {
        WithPerceptionTracking {
            EmptyState {
                Label(Strings.pageLoadFailed, systemImage: "exclamationmark.triangle")
            } description: {
                Text(message)
            } actions: {
                Button(Strings.retry, action: retry).glassButton()
            }
            .frame(maxWidth: .infinity)
            .listRowSeparator(.hidden)
        }
    }
}
