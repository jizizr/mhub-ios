import MHubKit
import Perception
import SwiftUI

struct SearchView: View {
    @Environment(AppModel.self) private var app
    @State private var results: [Track] = []
    @State private var searching = false
    @State private var error: String?
    @State private var searched = ""

    var body: some View {
        WithPerceptionTracking {
            NavigationStack {
                List {
                    WithPerceptionTracking {
                        platformPicker
                            .listRowSeparator(.hidden)
                            .listRowInsets(EdgeInsets(top: 4, leading: 0, bottom: 8, trailing: 0))
                        if !results.isEmpty {
                            ForEach(results) { TrackRow(track: $0) }
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
                .toolbar { SettingsToolbarButton() }
                .searchable(text: Perception.Bindable(app).searchQuery.tracked, placement: .navigationBarDrawer(displayMode: .always),
                            prompt: Strings.searchPrompt)
                .task(id: "\(app.settings.searchPlatform)|\(app.searchQuery)") { await search() }
            }
        }
    }

    /// Typing searches after a short pause; a new keystroke cancels the old one.
    private func search() async {
        let text = app.searchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, let client = app.client else {
            results = []
            searched = ""
            error = nil
            return
        }
        try? await Task.sleep(for: .milliseconds(350))
        guard !Task.isCancelled else { return }
        searching = true
        defer { searching = false }
        do {
            let found = try await client.search(platform: app.settings.searchPlatform, query: text)
            guard !Task.isCancelled else { return }
            results = found
            searched = text
            error = nil
        } catch is CancellationError {
        } catch {
            if (error as? URLError)?.code == .cancelled { return }
            results = []
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
