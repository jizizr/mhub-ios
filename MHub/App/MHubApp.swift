import MHubKit
import SwiftUI

@main
struct MHubApp: App {
    @State private var app: AppModel
    @State private var player: PlayerController

    init() {
        // AsyncImage and artwork requests go through the shared URLCache.
        URLCache.shared = URLCache(memoryCapacity: 48 << 20, diskCapacity: 300 << 20)
        let app = AppModel()
        _app = State(initialValue: app)
        _player = State(initialValue: PlayerController(app: app))
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(app)
                .environment(app.library)
                .environment(player)
                .preferredColorScheme(app.settings.appearance.colorScheme)
        }
    }
}

enum AppTab: Hashable { case home, library, search }

/// Songs waiting for the "添加到歌单" sheet.
struct PendingTracks: Identifiable {
    let id = UUID()
    var tracks: [Track]
}

struct RootView: View {
    @Environment(AppModel.self) private var app
    @Environment(PlayerController.self) private var player
    @Environment(\.scenePhase) private var scenePhase
    @Namespace private var playerTransition

    var body: some View {
        @Bindable var player = player
        @Bindable var app = app
        Group {
            if app.settings.serverURL == nil {
                ServerSetupView()
            } else {
                TabView(selection: $app.tab) {
                    Tab(Strings.home, systemImage: "house.fill", value: AppTab.home) { HomeView() }
                    Tab(Strings.library, systemImage: "square.stack.fill", value: AppTab.library) { LibraryView() }
                    Tab(Strings.search, systemImage: "magnifyingglass", value: AppTab.search, role: .search) { SearchView() }
                }
                .tabBarMinimizeBehavior(.onScrollDown)
                .tabViewBottomAccessory {
                    MiniPlayer()
                        .matchedTransitionSource(id: "player", in: playerTransition)
                }
                .fullScreenCover(isPresented: $player.showsFullPlayer) {
                    NowPlayingView()
                        .navigationTransition(.zoom(sourceID: "player", in: playerTransition))
                }
                .sheet(item: $app.pendingPlaylistTracks) { pending in
                    AddToPlaylistSheet(tracks: pending.tracks)
                }
                .sheet(isPresented: $app.showsSettings) { SettingsView() }
                .modifier(UpdateAlert())
            }
        }
        .overlay(alignment: .top) { ToastView() }
        .task(id: app.settings.serverAddress) {
            await app.refreshPlatforms()
            await app.account.refresh()
        }
        .task { await app.updates.checkAutomatically() }
        .onChange(of: scenePhase) { _, phase in
            // Back in the foreground: upload queued library edits and take the account's library.
            if phase == .active { Task { await app.account.refresh() } }
        }
        .onChange(of: app.settings.cacheLimit) { _, limit in
            Task { await AudioCache.shared.setLimit(limit) }
        }
    }
}

struct ToastView: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        if let message = app.toast {
            Text(message)
                .font(.subheadline.weight(.medium))
                .padding(.horizontal, 18)
                .padding(.vertical, 11)
                .glassEffect(.regular, in: .capsule)
                .padding(.top, 8)
                .padding(.horizontal, 24)
                .transition(.move(edge: .top).combined(with: .opacity))
                .onTapGesture { app.toast = nil }
                .accessibilityAddTraits(.isStaticText)
        }
    }
}
