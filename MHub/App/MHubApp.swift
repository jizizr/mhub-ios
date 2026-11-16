import MHubKit
import Perception
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
            WithPerceptionTracking {
                RootView()
                    .environment(app)
                    .environment(app.library)
                    .environment(player)
                    .preferredColorScheme(app.settings.appearance.colorScheme)
            }
        }
        // The「控制」menu on Mac; shortcuts with a hardware keyboard on iPad.
        .commands { PlaybackCommands(player: player) }
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
        WithPerceptionTracking {
            @Perception.Bindable var player = player
            @Perception.Bindable var app = app
            Group {
                if app.settings.serverURL == nil {
                    ServerSetupView()
                } else {
                    MainTabs(selection: $app.tab.tracked, playerTransition: playerTransition)
                    .fullScreenCover(isPresented: $player.showsFullPlayer.tracked) {
                        WithPerceptionTracking {
                            NowPlayingView()
                                .zoomTransition(sourceID: "player", in: playerTransition)
                                .appEnvironment(app, player)
                        }
                    }
                    .sheet(item: $app.pendingPlaylistTracks.tracked) { pending in
                        WithPerceptionTracking {
                            AddToPlaylistSheet(tracks: pending.tracks).appEnvironment(app, player)
                        }
                    }
                    .sheet(isPresented: $app.showsSettings.tracked) { SettingsView().appEnvironment(app, player) }
                    .modifier(UpdateAlert())
                }
            }
            .overlay(alignment: .top) { ToastView() }
            .task(id: app.settings.serverAddress) {
                await app.refreshPlatforms()
                await app.account.refresh()
            }
            .task { await app.updates.checkAutomatically() }
            .onValueChange(of: scenePhase) { phase in
                // Back in the foreground: upload queued library edits and take the account's library.
                if phase == .active { Task { await app.account.refresh() } }
            }
            .onValueChange(of: app.settings.cacheLimit) { limit in
                Task { await AudioCache.shared.setLimit(limit) }
            }
        }
    }
}

/// Home, library and search. iPhone: iOS 18+ uses `Tab` (the search role,
/// and on iOS 26 the tab bar accessory mini player); iOS 16–17 the older
/// `tabItem`. Mac and iPad at regular width: a sidebar and the floating
/// player bar, like Apple Music.
struct MainTabs: View {
    @Binding var selection: AppTab
    var playerTransition: Namespace.ID
    @Environment(\.horizontalSizeClass) private var sizeClass

    var body: some View {
        #if targetEnvironment(macCatalyst)
        if #available(macCatalyst 18.0, *) {
            sidebarTabs
        } else {
            legacy
        }
        #else
        if UIDevice.current.userInterfaceIdiom == .pad && sizeClass == .regular {
            if #available(iOS 18.0, *) {
                sidebarTabs
            } else {
                PadSidebar(selection: $selection)
            }
        } else if #available(iOS 26.0, macCatalyst 26.0, *) {
            modern
                .tabBarMinimizeBehavior(.onScrollDown)
                .tabViewBottomAccessory {
                    AccessoryMiniPlayer()
                        .matchedTransitionSource(id: "player", in: playerTransition)
                }
        } else if #available(iOS 18.0, macCatalyst 18.0, *) {
            modern
        } else {
            legacy
        }
        #endif
    }

    private var legacy: some View {
        TabView(selection: $selection) {
            HomeView().modifier(LegacyMiniPlayerInset())
                .tabItem { Label(Strings.home, systemImage: "house.fill") }.tag(AppTab.home)
            LibraryView().modifier(LegacyMiniPlayerInset())
                .tabItem { Label(Strings.library, systemImage: "square.stack.fill") }.tag(AppTab.library)
            SearchView().modifier(LegacyMiniPlayerInset())
                .tabItem { Label(Strings.search, systemImage: "magnifyingglass") }.tag(AppTab.search)
        }
    }

    /// Mac and iPad: the tabs as a sidebar (Apple Music's layout) and the
    /// floating player bar under every page instead of the tab bar accessory.
    @available(iOS 18.0, macCatalyst 18.0, *)
    private var sidebarTabs: some View {
        TabView(selection: $selection) {
            Tab(Strings.home, systemImage: "house", value: AppTab.home) { HomeView().modifier(WidePlayerBarInset()) }
            Tab(Strings.library, systemImage: "square.stack", value: AppTab.library) { LibraryView().modifier(WidePlayerBarInset()) }
            Tab(Strings.search, systemImage: "magnifyingglass", value: AppTab.search) { SearchView().modifier(WidePlayerBarInset()) }
        }
        .tabViewStyle(.sidebarAdaptable)
    }

    @available(iOS 18.0, macCatalyst 18.0, *)
    private var modern: some View {
        TabView(selection: $selection) {
            Tab(Strings.home, systemImage: "house.fill", value: AppTab.home) { HomeView().modifier(LegacyMiniPlayerInset()) }
            Tab(Strings.library, systemImage: "square.stack.fill", value: AppTab.library) { LibraryView().modifier(LegacyMiniPlayerInset()) }
            Tab(Strings.search, systemImage: "magnifyingglass", value: AppTab.search, role: .search) { SearchView().modifier(LegacyMiniPlayerInset()) }
        }
    }
}

/// iPadOS 16–17 (no adaptable `TabView`): the same sidebar drawn with a
/// split view. All three pages stay alive behind the visible one, so each
/// keeps its scroll position and navigation like a tab does.
struct PadSidebar: View {
    @Binding var selection: AppTab

    var body: some View {
        WithPerceptionTracking {
            NavigationSplitView {
                List(selection: Binding(get: { Optional(selection) }, set: { if let tab = $0 { selection = tab } })) {
                    Label(Strings.home, systemImage: "house").tag(AppTab.home)
                    Label(Strings.library, systemImage: "square.stack").tag(AppTab.library)
                    Label(Strings.search, systemImage: "magnifyingglass").tag(AppTab.search)
                }
                .navigationTitle(Strings.appName)
            } detail: {
                ZStack {
                    page(.home) { HomeView() }
                    page(.library) { LibraryView() }
                    page(.search) { SearchView() }
                }
                .modifier(WidePlayerBarInset())
            }
            .navigationSplitViewStyle(.balanced)
        }
    }

    private func page(_ tab: AppTab, @ViewBuilder content: () -> some View) -> some View {
        let shown = selection == tab
        return content()
            .opacity(shown ? 1 : 0)
            .allowsHitTesting(shown)
            .accessibilityHidden(!shown)
    }
}

extension View {
    /// The app's shared objects, passed to presented content explicitly: on
    /// Mac Catalyst a sheet or full-screen cover does not inherit them, and
    /// its first `@Environment` read crashes.
    func appEnvironment(_ app: AppModel, _ player: PlayerController) -> some View {
        environment(app).environment(app.library).environment(player)
    }
}

struct ToastView: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        WithPerceptionTracking {
            if let message = app.toast {
                Text(message)
                    .font(.subheadline.weight(.medium))
                    .padding(.horizontal, 18)
                    .padding(.vertical, 11)
                    .glass(.regular, in: .capsule)
                    .padding(.top, 8)
                    .padding(.horizontal, 24)
                    .transition(.move(edge: .top).combined(with: .opacity))
                    .onTapGesture { app.toast = nil }
                    .accessibilityAddTraits(.isStaticText)
            }
        }
    }
}
