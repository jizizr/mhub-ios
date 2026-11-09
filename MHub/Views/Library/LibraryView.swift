import MHubKit
import SwiftUI

struct LibraryView: View {
    @Environment(LibraryStore.self) private var library
    @Environment(AppModel.self) private var app
    @State private var creating = false
    @State private var importing = false
    @State private var name = ""

    var body: some View {
        NavigationStack(path: Bindable(app).libraryPath) {
            List {
                Section {
                    NavigationLink {
                        CacheView()
                    } label: {
                        Label(Strings.localCache, systemImage: "arrow.down.circle")
                    }
                }
                Section(Strings.playlists) {
                    if library.playlists.isEmpty {
                        ContentUnavailableView {
                            Label(Strings.emptyLibrary, systemImage: "music.note.list")
                        } description: {
                            Text(Strings.emptyLibraryHint)
                        } actions: {
                            Button(Strings.importPlaylist) { importing = true }.buttonStyle(.glass)
                        }
                    }
                    ForEach(library.playlists) { playlist in
                        NavigationLink(value: playlist.id) { PlaylistRow(playlist: playlist) }
                    }
                    .onDelete { offsets in
                        for offset in offsets { library.delete(library.playlists[offset].id) }
                    }
                }
            }
            .navigationTitle(Strings.library)
            .navigationDestination(for: String.self) { PlaylistDetailView(playlistID: $0) }
            .toolbar {
                Menu {
                    Button(Strings.newPlaylist, systemImage: "plus") {
                        name = ""
                        creating = true
                    }
                    Button(Strings.importPlaylist, systemImage: "link") { importing = true }
                } label: {
                    Label(Strings.newPlaylist, systemImage: "plus")
                }
                SettingsToolbarButton()
            }
            .alert(Strings.newPlaylist, isPresented: $creating) {
                TextField(Strings.playlistName, text: $name)
                Button(Strings.cancel, role: .cancel) {}
                Button(Strings.create) { library.create(name: name) }
            }
            .sheet(isPresented: $importing) { ImportPlaylistView() }
        }
    }
}

struct PlaylistDetailView: View {
    @Environment(LibraryStore.self) private var library
    @Environment(\.dismiss) private var dismiss
    var playlistID: String
    @State private var renaming = false
    @State private var deleting = false
    @State private var name = ""

    var body: some View {
        if let playlist = library.playlist(playlistID) {
            List {
                Section {
                    VStack(spacing: 14) {
                        ArtworkView(url: URL(string: playlist.cover), cornerRadius: 12)
                            .frame(width: 240, height: 240)
                            .shadow(color: .black.opacity(0.18), radius: 16, y: 8)
                        Text(playlist.name).font(.title2.bold()).multilineTextAlignment(.center)
                        Text(String(format: Strings.songsCount, playlist.tracks.count))
                            .font(.subheadline).foregroundStyle(.secondary)
                        PlayShuffleButtons(tracks: playlist.tracks,
                                           source: QueueSource(type: QueueSource.playlist, name: playlist.name, id: playlist.id))
                    }
                    .frame(maxWidth: .infinity)
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
                }
                if playlist.tracks.isEmpty {
                    ContentUnavailableView(Strings.emptyPlaylist, systemImage: "music.note")
                }
                ForEach(playlist.tracks) { TrackRow(track: $0, playlistID: playlist.id) }
                    .onDelete { offsets in
                        library.remove(trackIDs: Set(offsets.map { playlist.tracks[$0].id }), from: playlist.id)
                    }
                    .onMove { library.move(in: playlist.id, from: $0, to: $1) }
            }
            .listStyle(.plain)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItemGroup(placement: .topBarTrailing) {
                    EditButton()
                    Menu {
                        Button(Strings.rename, systemImage: "pencil") {
                            name = playlist.name
                            renaming = true
                        }
                        Button(Strings.deletePlaylist, systemImage: "trash", role: .destructive) { deleting = true }
                    } label: {
                        Label(Strings.settings, systemImage: "ellipsis")
                    }
                }
            }
            .alert(Strings.rename, isPresented: $renaming) {
                TextField(Strings.playlistName, text: $name)
                Button(Strings.cancel, role: .cancel) {}
                Button(Strings.done) { library.rename(playlist.id, to: name) }
            }
            .confirmationDialog(Strings.deletePlaylist, isPresented: $deleting, titleVisibility: .visible) {
                Button(Strings.delete, role: .destructive) {
                    library.delete(playlist.id)
                    dismiss()
                }
            } message: {
                Text(Strings.deletePlaylistConfirm)
            }
        } else {
            ContentUnavailableView(Strings.emptyLibrary, systemImage: "music.note.list")
        }
    }
}

struct ImportPlaylistView: View {
    @Environment(AppModel.self) private var app
    @Environment(LibraryStore.self) private var library
    @Environment(\.dismiss) private var dismiss
    @State private var link = ""
    @State private var working: Task<Void, Never>?
    @State private var error: String?
    /// While the server's quota is used up: when the import resumes.
    @State private var resumesAt: Date?

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField(Strings.importLinkPrompt, text: $link, axis: .vertical)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .keyboardType(.URL)
                } footer: {
                    if let resumesAt {
                        TimelineView(.periodic(from: .now, by: 1)) { context in
                            let ms = Int(resumesAt.timeIntervalSince(context.date) * 1000)
                            Text(Strings.importRateLimited(RateLimit.seconds(max(ms, 0))))
                                .foregroundStyle(.secondary)
                        }
                    } else {
                        Text(error ?? Strings.importUnsupported)
                            .foregroundStyle(error == nil ? Color.secondary : Color.red)
                    }
                }
            }
            .navigationTitle(Strings.importPlaylist)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(Strings.cancel, systemImage: "xmark") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    if working != nil {
                        ProgressView()
                    } else {
                        Button(Strings.importButton, systemImage: "checkmark") { working = Task { await importLink() } }
                            .disabled(Links.collectionPlatform(for: link) == nil)
                    }
                }
            }
            .onAppear {
                if let pasted = UIPasteboard.general.string, Links.collectionPlatform(for: pasted) != nil { link = pasted }
            }
            // Closing the sheet stops the import and any wait for the quota.
            .onDisappear { working?.cancel() }
        }
        .presentationDetents([.medium])
    }

    private func importLink() async {
        guard let platform = Links.collectionPlatform(for: link), let client = app.client else { return }
        error = nil
        defer { working = nil; resumesAt = nil }
        // An import is background work: it waits out the quota and shows the wait.
        let policy = RateLimitPolicy.importing { ms in
            Task { @MainActor in resumesAt = .now.addingTimeInterval(Double(ms) / 1000) }
        }
        do {
            let collection = try await client.collection(platform: platform, url: link.trimmingCharacters(in: .whitespacesAndNewlines),
                                                         rateLimit: policy)
            resumesAt = nil
            let playlist = library.create(name: collection.title, tracks: collection.items.map(\.track),
                                          sourceURL: collection.sourceURL, sourcePlatform: collection.platform)
            app.show(Strings.imported(playlist.name, playlist.tracks.count))
            dismiss()
        } catch is CancellationError {
        } catch {
            self.error = error.localizedDescription
        }
    }
}

struct CacheView: View {
    @Environment(PlayerController.self) private var player
    @State private var entries: [AudioCache.Entry] = []
    @State private var total: Int64 = 0
    @State private var confirming = false

    var body: some View {
        List {
            Section {
                LabeledContent(Strings.cacheUsage, value: total.byteText)
            }
            Section {
                if entries.isEmpty {
                    ContentUnavailableView(Strings.cacheEmpty, systemImage: "arrow.down.circle")
                }
                ForEach(Array(entries.enumerated()), id: \.element.id) { offset, entry in
                    Button {
                        player.play(entries.map(\.track), startAt: offset, shuffle: false)
                    } label: {
                        HStack(spacing: 12) {
                            ArtworkView(url: entry.track.coverURL, cornerRadius: 5).frame(width: 44, height: 44)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(entry.track.title).lineLimit(1)
                                Text("\(entry.track.artist) · \(entry.quality.label) · \(entry.size.byteText)")
                                    .font(.footnote).foregroundStyle(.secondary).lineLimit(1)
                            }
                        }
                    }
                    .buttonStyle(.plain)
                    .contextMenu { TrackMenuItems(tracks: [entry.track]) }
                }
                .onDelete { offsets in
                    let keys = offsets.map { entries[$0].key }
                    Task {
                        for key in keys { await AudioCache.shared.remove(key) }
                        await reload()
                    }
                }
            }
        }
        .navigationTitle(Strings.localCache)
        .toolbar {
            Button(Strings.clearCache, systemImage: "trash", role: .destructive) { confirming = true }
                .disabled(entries.isEmpty)
        }
        .confirmationDialog(Strings.clearCache, isPresented: $confirming, titleVisibility: .visible) {
            Button(Strings.clearCache, role: .destructive) {
                Task {
                    await AudioCache.shared.clear()
                    await reload()
                }
            }
        } message: {
            Text(Strings.clearCacheConfirm)
        }
        .task { await reload() }
    }

    private func reload() async {
        entries = await AudioCache.shared.entries()
        total = await AudioCache.shared.totalSize()
    }
}
