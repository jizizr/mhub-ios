import MHubKit
import Perception
import SwiftUI

/// Search: platform chips, then the results in Apple Music's tabs (最佳结果 ·
/// 艺人 · 专辑 · 歌曲 · 播放列表). A platform with songs only keeps a plain list.
struct SearchView: View {
    @Environment(AppModel.self) private var app
    @State private var found: CatalogSearch?
    @State private var section: CatalogSection = .top
    @State private var searching = false
    @State private var error: String?
    @State private var searched = ""

    var body: some View {
        WithPerceptionTracking {
            NavigationStack(path: Perception.Bindable(app).searchPath.tracked) {
                List {
                    WithPerceptionTracking {
                        platformPicker
                            .listRowSeparator(.hidden)
                            .listRowInsets(EdgeInsets(top: 4, leading: 0, bottom: 8, trailing: 0))
                        if let found, !found.songs.isEmpty || !found.visibleSections.isEmpty {
                            results(found)
                        } else if searching {
                            ProgressView().frame(maxWidth: .infinity).listRowSeparator(.hidden)
                        } else if let error {
                            EmptyState(Strings.homeLoadFailed, systemImage: "exclamationmark.triangle", description: Text(error))
                                .listRowSeparator(.hidden)
                        } else if !searched.isEmpty {
                            EmptyState.search(text: searched).listRowSeparator(.hidden)
                        } else {
                            EmptyState(Strings.searchHint, systemImage: "magnifyingglass")
                                .listRowSeparator(.hidden)
                        }
                    }
                }
                .listStyle(.plain)
                .navigationTitle(Strings.search)
                .padTabBar()
                .toolbar { SettingsToolbarButton() }
                .searchable(text: Perception.Bindable(app).searchQuery.tracked, placement: .navigationBarDrawer(displayMode: .always),
                            prompt: Strings.searchPrompt)
                .task(id: "\(app.settings.searchPlatform)|\(app.searchQuery)") { await search() }
                .catalogDestinations()
            }
        }
    }

    @ViewBuilder
    private func results(_ found: CatalogSearch) -> some View {
        let tabs = found.visibleSections
        let active = tabs.contains(section) ? section : (tabs.first ?? .songs)
        if !tabs.isEmpty {
            sectionPicker(tabs, active: active)
                .listRowSeparator(.hidden)
                .listRowInsets(EdgeInsets(top: 0, leading: 0, bottom: 8, trailing: 0))
        }
        switch active {
        case .top where !tabs.isEmpty:
            CatalogShelf(title: "", items: found.top, withKind: true)
                .listRowInsets(EdgeInsets(top: 4, leading: 0, bottom: 12, trailing: 0))
                .listRowSeparator(.hidden)
            if !found.songs.isEmpty {
                moreHeader(.songs)
                ForEach(found.songs.prefix(6)) { TrackRow(track: $0.track) }
            }
            ForEach([CatalogSection.albums, .artists, .playlists].filter { !found.items($0).isEmpty }) { shelf in
                WithPerceptionTracking {
                    CatalogShelf(title: shelf.label, items: Array(found.items(shelf).prefix(12))) {
                        withAnimation(.snappy) { section = shelf }
                    }
                    .listRowInsets(EdgeInsets(top: 18, leading: 0, bottom: 8, trailing: 0))
                    .listRowSeparator(.hidden)
                }
            }
        case .songs, .top:
            ForEach(found.songs) { TrackRow(track: $0.track) }
        default:
            CatalogGrid(items: found.items(active))
                .listRowInsets(EdgeInsets(top: 4, leading: 0, bottom: 12, trailing: 0))
                .listRowSeparator(.hidden)
        }
    }

    private func moreHeader(_ target: CatalogSection) -> some View {
        Button {
            withAnimation(.snappy) { section = target }
        } label: {
            HStack(spacing: 2) {
                Text(target.label).font(.title3.bold())
                Image(systemName: "chevron.right").font(.subheadline.bold()).foregroundStyle(.secondary)
            }
            .foregroundStyle(.primary)
        }
        .buttonStyle(.plain)
        .listRowSeparator(.hidden)
        .listRowInsets(EdgeInsets(top: 18, leading: 20, bottom: 4, trailing: 20))
    }

    /// Typing searches after a short pause; a new keystroke cancels the old one.
    private func search() async {
        let text = app.searchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, let client = app.client else {
            found = nil
            searched = ""
            error = nil
            return
        }
        try? await Task.sleep(for: .milliseconds(350))
        guard !Task.isCancelled else { return }
        let platform = app.settings.searchPlatform
        searching = true
        defer { searching = false }
        do {
            let result: CatalogSearch
            do {
                result = try await client.catalogSearch(platform: platform, query: text)
            } catch let APIError.http(status, _) where status == 404 {
                // A server from before catalog search: songs only.
                let songs = try await client.search(platform: platform, query: text)
                result = CatalogSearch(platform: platform, songs: songs.map {
                    CatalogItem(type: CatalogItem.song, platform: $0.platform, itemID: $0.sourceID, title: $0.title,
                                subtitle: $0.artist, cover: $0.cover)
                })
            }
            guard !Task.isCancelled else { return }
            found = result
            section = .top
            searched = text
            error = nil
        } catch is CancellationError {
        } catch {
            if (error as? URLError)?.code == .cancelled { return }
            found = nil
            self.error = error.localizedDescription
        }
    }

    /// Platform chips, the same control as the Android search page.
    private var platformPicker: some View {
        ScrollView(.horizontal) {
            HStack(spacing: 8) {
                ForEach(app.platforms) { platform in
                    WithPerceptionTracking {
                        let selected = app.settings.searchPlatform == platform.id
                        let button = Button(shortLabel(platform)) {
                            withAnimation(.snappy) { app.settings.searchPlatform = platform.id }
                        }
                        .font(.subheadline.weight(.semibold))
                        button.glassButton(prominent: selected)
                    }
                }
            }
            .padding(.horizontal, 20)
        }
        .scrollIndicators(.hidden)
    }

    /// The result tabs: plain text that turns into a filled pill when chosen.
    private func sectionPicker(_ tabs: [CatalogSection], active: CatalogSection) -> some View {
        ScrollView(.horizontal) {
            HStack(spacing: 4) {
                ForEach(tabs) { tab in
                    WithPerceptionTracking {
                        Button {
                            withAnimation(.snappy) { section = tab }
                        } label: {
                            Text(tab.label)
                                .font(.subheadline.weight(.semibold))
                                .foregroundStyle(tab == active ? Color.white : Color.primary)
                                .padding(.horizontal, 14)
                                .padding(.vertical, 6)
                                .background(tab == active ? Color.accentColor : Color.clear, in: .capsule)
                                .contentShape(.capsule)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .padding(.horizontal, 16)
        }
        .scrollIndicators(.hidden)
    }

    private func shortLabel(_ platform: PlatformInfo) -> String {
        switch platform.id {
        case "applemusic": "Apple"
        case "netease": "网易云"
        case "tencent": "QQ"
        case "bilibili": "B站"
        case "youtubemusic": "YouTube"
        default: platform.label
        }
    }
}
