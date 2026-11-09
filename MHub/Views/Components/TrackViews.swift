import MHubKit
import SwiftUI

/// Cover art with a neutral placeholder. Requests share `URLCache.shared`.
struct ArtworkView: View {
    var url: URL?
    var cornerRadius: CGFloat = 6

    var body: some View {
        // The parent decides the size; the image only fills it.
        Rectangle()
            .fill(.quaternary)
            .overlay {
                AsyncImage(url: url, transaction: Transaction(animation: .easeOut(duration: 0.2))) { phase in
                    if let image = phase.image {
                        image.resizable().scaledToFill()
                    } else {
                        Image(systemName: "music.note").font(.title3).foregroundStyle(.secondary)
                    }
                }
            }
            .clipShape(.rect(cornerRadius: cornerRadius, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .strokeBorder(.primary.opacity(0.08), lineWidth: 0.5)
        }
    }
}

/// One song in a list. Tapping plays it now; the menu holds the other actions.
struct TrackRow: View {
    @Environment(PlayerController.self) private var player
    var track: Track
    var playlistID: String?
    var showsArtwork = true

    var body: some View {
        Button {
            player.playNow(track)
        } label: {
            HStack(spacing: 12) {
                if showsArtwork {
                    ArtworkView(url: track.coverURL, cornerRadius: 5)
                        .frame(width: 48, height: 48)
                        .overlay {
                            if player.current?.id == track.id {
                                NowPlayingIndicator(playing: player.isPlaying)
                            }
                        }
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text(track.title).font(.body).lineLimit(1)
                        .foregroundStyle(player.current?.id == track.id ? Color.accentColor : .primary)
                    Text(track.artist).font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer(minLength: 8)
                Menu {
                    TrackMenuItems(tracks: [track], playlistID: playlistID)
                } label: {
                    Image(systemName: "ellipsis")
                        .font(.body.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .frame(width: 32, height: 44)
                        .contentShape(.rect)
                }
                .accessibilityLabel(Strings.share)
            }
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .contextMenu {
            TrackMenuItems(tracks: [track], playlistID: playlistID)
        } preview: {
            TrackPreview(track: track)
        }
    }
}

private struct TrackPreview: View {
    var track: Track
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ArtworkView(url: track.coverURL, cornerRadius: 10).frame(width: 240, height: 240)
            Text(track.title).font(.headline).lineLimit(2)
            Text(track.artist).font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
        }
        .padding(16)
        .frame(width: 272)
    }
}

/// The song actions, in the order shared with Android and the web app.
struct TrackMenuItems: View {
    @Environment(AppModel.self) private var app
    @Environment(PlayerController.self) private var player
    @Environment(LibraryStore.self) private var library
    var tracks: [Track]
    var playlistID: String?
    /// The full player adds lyric sharing and the display settings.
    var inPlayer = false

    var body: some View {
        Button(Strings.playNext, systemImage: "text.line.first.and.arrowtriangle.forward") { player.playNext(tracks) }
        Button(Strings.addToQueue, systemImage: "text.line.last.and.arrowtriangle.forward") { player.append(tracks) }
        Button(Strings.addToPlaylist, systemImage: "text.badge.plus") {
            app.pendingPlaylistTracks = PendingTracks(tracks: tracks)
        }
        if tracks.count == 1, let track = tracks.first {
            Button(Strings.download, systemImage: "arrow.down.circle") { app.downloads.download(track) }
        }
        if tracks.count == 1, let track = tracks.first, let server = app.settings.serverURL,
           let url = Links.shareURL(for: track, server: server) {
            ShareLink(item: url, subject: Text(track.title), message: Text("\(track.title) - \(track.artist)")) {
                Label(Strings.share, systemImage: "square.and.arrow.up")
            }
        }
        if inPlayer, let track = tracks.first {
            if player.lyrics.isSynced {
                Button(Strings.shareLyricsMenu, systemImage: "quote.bubble") { app.lyricShare = LyricShareRequest(track: track) }
            }
            Button(Strings.displaySettingsMenu, systemImage: "textformat.size") { app.showsDisplaySettings = true }
        }
        if let playlistID {
            Divider()
            Button(Strings.removeFromPlaylist, systemImage: "trash", role: .destructive) {
                library.remove(trackIDs: Set(tracks.map(\.id)), from: playlistID)
            }
        }
    }
}

/// Animated bars over the artwork of the playing song.
struct NowPlayingIndicator: View {
    var playing: Bool

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 5, style: .continuous).fill(.black.opacity(0.35))
            Image(systemName: "waveform")
                .font(.body.weight(.bold))
                .foregroundStyle(.white)
                .symbolEffect(.variableColor.iterative, options: .repeating, isActive: playing)
        }
    }
}

struct AddToPlaylistSheet: View {
    @Environment(AppModel.self) private var app
    @Environment(LibraryStore.self) private var library
    @Environment(\.dismiss) private var dismiss
    var tracks: [Track]
    @State private var creating = false
    @State private var name = ""

    var body: some View {
        NavigationStack {
            List {
                Button {
                    creating = true
                } label: {
                    Label(Strings.newPlaylist, systemImage: "plus")
                }
                ForEach(library.playlists) { playlist in
                    Button {
                        let added = library.add(tracks, to: playlist.id)
                        app.show(Strings.addedToPlaylist(playlist.name, added))
                        dismiss()
                    } label: {
                        PlaylistRow(playlist: playlist)
                    }
                    .buttonStyle(.plain)
                }
            }
            .navigationTitle(Strings.addToPlaylist)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(Strings.cancel, systemImage: "xmark") { dismiss() }
                }
            }
            .alert(Strings.newPlaylist, isPresented: $creating) {
                TextField(Strings.playlistName, text: $name)
                Button(Strings.cancel, role: .cancel) {}
                Button(Strings.create) {
                    let playlist = library.create(name: name, tracks: tracks)
                    app.show(Strings.addedToPlaylist(playlist.name, tracks.count))
                    dismiss()
                }
            }
        }
        .presentationDetents([.medium, .large])
    }
}

struct PlaylistRow: View {
    var playlist: Playlist

    var body: some View {
        HStack(spacing: 12) {
            ArtworkView(url: URL(string: playlist.cover), cornerRadius: 6).frame(width: 56, height: 56)
            VStack(alignment: .leading, spacing: 2) {
                Text(playlist.name).lineLimit(1)
                Text(String(format: Strings.songsCount, playlist.tracks.count))
                    .font(.subheadline).foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
        .contentShape(.rect)
    }
}

/// "播放" and "随机播放" buttons under a list header, as in Apple Music.
struct PlayShuffleButtons: View {
    @Environment(PlayerController.self) private var player
    var tracks: [Track]
    /// Shown above the queue as「来自歌单」.
    var source: QueueSource?

    var body: some View {
        HStack(spacing: 14) {
            Button {
                player.play(tracks, shuffle: false, source: source)
            } label: {
                Label(Strings.play, systemImage: "play.fill").frame(maxWidth: .infinity)
            }
            Button {
                player.play(tracks, shuffle: true, source: source)
            } label: {
                Label(Strings.shuffle, systemImage: "shuffle").frame(maxWidth: .infinity)
            }
        }
        .buttonStyle(.glass)
        .controlSize(.large)
        .font(.headline)
        .disabled(tracks.isEmpty)
    }
}

extension Int64 {
    var byteText: String { ByteCountFormatter.string(fromByteCount: self, countStyle: .file) }
}
