import MHubKit
import Perception
import SwiftUI

/// A recommended playlist or album to open.
struct CollectionRoute: Hashable {
    var platform: String
    var url: String
    var title: String
    var cover: String
}

@MainActor @Perceptible
final class HomeModel {
    var home: RecommendationHome?
    var loading = false
    var error: String?
    var selectedTag: String?
    private var seen: [String] = []

    func load(client: MHubClient?, refresh: Bool = false) async {
        guard let client, !loading else { return }
        loading = true
        defer { loading = false }
        do {
            let result = try await client.home(refresh: refresh, exclude: refresh ? seen : [])
            seen = Array((seen + result.tracks.map(\.id)).suffix(300))
            withAnimation(.smooth) {
                home = result
                error = nil
                if let tag = selectedTag, !result.tags.contains(where: { $0.id == tag }) { selectedTag = nil }
            }
        } catch {
            self.error = error.localizedDescription
        }
    }

    var visiblePlaylists: [RecommendationPlaylist] {
        guard let home else { return [] }
        guard let tag = home.tags.first(where: { $0.id == selectedTag }) else { return home.playlists }
        let ids = Set(tag.playlistIDs)
        return home.playlists.filter { ids.contains($0.id) }
    }
}

struct HomeView: View {
    @Environment(AppModel.self) private var app
    @Environment(PlayerController.self) private var player
    @State private var model = HomeModel()

    var body: some View {
        WithPerceptionTracking {
            NavigationStack(path: Perception.Bindable(app).homePath.tracked) {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 30) {
                        WithPerceptionTracking {
                            if let home = model.home {
                                if !home.tags.isEmpty { tags(home.tags) }
                                if !model.visiblePlaylists.isEmpty { playlists }
                                if !home.tracks.isEmpty { songs(home.tracks.map(\.track)) }
                            } else if let error = model.error {
                                EmptyState {
                                    Label(Strings.homeLoadFailed, systemImage: "wifi.exclamationmark")
                                } description: {
                                    WithPerceptionTracking {
                                        Text(error)
                                    }
                                } actions: {
                                    WithPerceptionTracking {
                                        Button(Strings.retry) { Task { await model.load(client: app.client) } }
                                            .glassButton()
                                    }
                                }
                                .frame(maxWidth: .infinity)
                                .padding(.top, 60)
                            } else {
                                ProgressView().frame(maxWidth: .infinity).padding(.top, 80)
                            }
                            if !app.recent.isEmpty { recent }
                        }
                    }
                    .padding(.bottom, 24)
                }
                .navigationTitle(Strings.home)
                .toolbar {
                    WithPerceptionTracking {
                        ToolbarItemGroup(placement: .topBarTrailing) {
                            Button(Strings.refresh, systemImage: "arrow.clockwise") {
                                Task { await model.load(client: app.client, refresh: true) }
                            }
                            .disabled(model.loading)
                            SettingsToolbarButton()
                        }
                    }
                }
                .refreshable { await model.load(client: app.client, refresh: true) }
                .navigationDestination(for: CollectionRoute.self) { CollectionView(route: $0) }
            }
            .task(id: app.settings.serverAddress) {
                if model.home == nil { await model.load(client: app.client) }
            }
        }
    }

    private func tags(_ tags: [RecommendationTag]) -> some View {
        ScrollView(.horizontal) {
            HStack(spacing: 8) {
                ForEach(tags) { tag in
                    WithPerceptionTracking {
                        let selected = model.selectedTag == tag.id
                        let button = Button {
                            withAnimation(.snappy) { model.selectedTag = selected ? nil : tag.id }
                        } label: {
                            WithPerceptionTracking {
                                Text(tag.label).font(.subheadline.weight(.semibold))
                            }
                        }
                        button.glassButton(prominent: selected)
                    }
                }
            }
            .padding(.horizontal, 20)
        }
        .scrollIndicators(.hidden)
    }

    private var playlists: some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionHeader(title: Strings.recommendedPlaylists)
            ScrollView(.horizontal) {
                LazyHStack(alignment: .top, spacing: 14) {
                    WithPerceptionTracking {
                        ForEach(model.visiblePlaylists) { playlist in
                            WithPerceptionTracking {
                                NavigationLink(value: CollectionRoute(platform: "applemusic", url: playlist.url,
                                                                      title: playlist.name, cover: playlist.cover)) {
                                    VStack(alignment: .leading, spacing: 6) {
                                        ArtworkView(url: URL(string: playlist.cover), cornerRadius: 10)
                                            .frame(width: 170, height: 170)
                                        Text(playlist.name).font(.subheadline).lineLimit(2)
                                            .foregroundStyle(.primary)
                                        Text(playlist.curator).font(.footnote).foregroundStyle(.secondary).lineLimit(1)
                                    }
                                    .frame(width: 170, alignment: .leading)
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }
                }
                .shelfScrollTargets()
                .padding(.horizontal, 20)
            }
            .shelfScrollBehavior()
            .scrollIndicators(.hidden)
        }
    }

    private func songs(_ tracks: [Track]) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionHeader(title: Strings.recommendedSongs) {
                Button(Strings.play, systemImage: "play.fill") {
                    let tag = model.home?.tags.first { $0.id == model.selectedTag }
                    player.play(tracks, source: QueueSource(type: QueueSource.recommendation,
                                                            name: Strings.casualListening(tag?.label ?? Strings.madeForYou)))
                }
                    .labelStyle(.iconOnly)
                    .glassButton()
            }
            ScrollView(.horizontal) {
                LazyHGrid(rows: Array(repeating: GridItem(.fixed(56), spacing: 8), count: 4), spacing: 16) {
                    WithPerceptionTracking {
                        ForEach(tracks) { track in
                            WithPerceptionTracking {
                                TrackRow(track: track).frame(width: 300)
                            }
                        }
                    }
                }
                .shelfScrollTargets()
                .padding(.horizontal, 20)
            }
            .shelfScrollBehavior()
            .scrollIndicators(.hidden)
        }
    }

    private var recent: some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionHeader(title: Strings.recentlyPlayed)
            ScrollView(.horizontal) {
                LazyHStack(alignment: .top, spacing: 14) {
                    WithPerceptionTracking {
                        ForEach(app.recent) { track in
                            WithPerceptionTracking {
                                Button {
                                    player.playNow(track)
                                } label: {
                                    WithPerceptionTracking {
                                        VStack(alignment: .leading, spacing: 6) {
                                            ArtworkView(url: track.coverURL, cornerRadius: 10).frame(width: 130, height: 130)
                                            Text(track.title).font(.subheadline).lineLimit(1)
                                            Text(track.artist).font(.footnote).foregroundStyle(.secondary).lineLimit(1)
                                        }
                                        .frame(width: 130, alignment: .leading)
                                    }
                                }
                                .buttonStyle(.plain)
                                .contextMenu { TrackMenuItems(tracks: [track]) }
                            }
                        }
                    }
                }
                .padding(.horizontal, 20)
            }
            .scrollIndicators(.hidden)
        }
    }
}

struct SectionHeader<Trailing: View>: View {
    var title: String
    @ViewBuilder var trailing: Trailing

    var body: some View {
        WithPerceptionTracking {
            HStack {
                Text(title).font(.title2.bold())
                Spacer()
                trailing
            }
            .padding(.horizontal, 20)
        }
    }
}

extension SectionHeader where Trailing == EmptyView {
    init(title: String) {
        self.title = title
        trailing = EmptyView()
    }
}

/// A remote playlist or album: play it, or save it to the library.
struct CollectionView: View {
    @Environment(AppModel.self) private var app
    @Environment(LibraryStore.self) private var library
    var route: CollectionRoute
    @State private var collection: MHubKit.Collection?
    @State private var error: String?

    var body: some View {
        WithPerceptionTracking {
            List {
                WithPerceptionTracking {
                    Section {
                        VStack(spacing: 14) {
                            ArtworkView(url: URL(string: route.cover), cornerRadius: 12)
                                .frame(width: 240, height: 240)
                                .shadow(color: .black.opacity(0.18), radius: 16, y: 8)
                            Text(collection?.title ?? route.title).font(.title2.bold()).multilineTextAlignment(.center)
                            if let collection {
                                Text(String(format: Strings.songsCount, collection.items.count))
                                    .font(.subheadline).foregroundStyle(.secondary)
                                PlayShuffleButtons(tracks: collection.items.map(\.track),
                                                   source: QueueSource(type: QueueSource.collection, name: collection.title, id: route.url,
                                                                       platform: route.platform, url: route.url, cover: route.cover))
                            }
                        }
                        .frame(maxWidth: .infinity)
                        .listRowBackground(Color.clear)
                        .listRowSeparator(.hidden)
                    }
                    if let collection {
                        ForEach(collection.items.map(\.track)) { TrackRow(track: $0) }
                    } else if let error {
                        EmptyState(Strings.homeLoadFailed, systemImage: "exclamationmark.triangle", description: Text(error))
                    } else {
                        ProgressView().frame(maxWidth: .infinity)
                    }
                }
            }
            .listStyle(.plain)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                WithPerceptionTracking {
                    if let collection {
                        Button(Strings.addAllToPlaylist, systemImage: "plus") {
                            let playlist = library.create(name: collection.title, tracks: collection.items.map(\.track),
                                                          sourceURL: collection.sourceURL, sourcePlatform: collection.platform)
                            app.show(Strings.imported(playlist.name, playlist.tracks.count))
                        }
                    }
                }
            }
            .task {
                guard collection == nil, let client = app.client else { return }
                do { collection = try await client.collection(platform: route.platform, url: route.url) }
                catch { self.error = error.localizedDescription }
            }
        }
    }
}
