import MHubKit
import SwiftUI

/// The play queue, laid out like the web `QueuePanel` (docs/design.md「播放队列」):
/// mode toggles, count and source, the AutoPlay notice, then the whole queue
/// with the current song highlighted, drag handles and remove buttons.
struct QueuePane: View {
    @Environment(PlayerController.self) private var player
    @Environment(AppModel.self) private var app
    @Environment(LibraryStore.self) private var library
    @State private var confirmingClear = false

    var body: some View {
        let queue = player.queue
        VStack(spacing: 10) {
            HStack(spacing: 10) {
                toggle(Strings.shuffle, "shuffle", on: queue.shuffled) { player.toggleShuffle() }
                toggle(Strings.repeatMode, queue.repeatMode == .one ? "repeat.1" : "repeat", on: queue.repeatMode != .off) {
                    player.cycleRepeat()
                }
                toggle(Strings.autoplay, "infinity", on: queue.autoplay) { player.setAutoplay(!queue.autoplay) }
            }
            header(queue)
            if queue.autoplay { autoplayNotice }
            if queue.isEmpty {
                VStack(spacing: 6) {
                    Image(systemName: "music.note.list").font(.title).foregroundStyle(.white.opacity(0.5))
                    Text(Strings.queueEmpty).font(.headline)
                    Text(Strings.queueEmptyHint).font(.subheadline).foregroundStyle(.white.opacity(0.55)).multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                .padding(.top, 48)
            } else {
                list(queue)
            }
        }
        .alert(Strings.clearQueue, isPresented: $confirmingClear) {
            Button(Strings.cancel, role: .cancel) {}
            Button(Strings.clear, role: .destructive) { player.clearQueue() }
        } message: {
            Text(Strings.clearQueueConfirm)
        }
    }

    /// 「N 首音乐 · 来自歌单：X」 and clearing the queue.
    private func header(_ queue: PlayQueue) -> some View {
        HStack(spacing: 0) {
            Text(Strings.queueCount(queue.items.count)).foregroundStyle(.white.opacity(0.7))
            if let source = player.source {
                Text(" · ").foregroundStyle(.white.opacity(0.7))
                Button { open(source) } label: {
                    Text(source.isRecommendation ? Strings.sourceRecommendation(source.name) : Strings.sourcePlaylist(source.name))
                        .fontWeight(.semibold)
                        .lineLimit(1)
                }
                .buttonStyle(.plain)
            }
            Spacer(minLength: 8)
            Button(Strings.clearQueue, systemImage: "trash") { confirmingClear = true }
                .labelStyle(.iconOnly)
                .foregroundStyle(.white.opacity(queue.isEmpty ? 0.3 : 0.75))
                .disabled(queue.isEmpty)
        }
        .font(.subheadline)
    }

    /// Opens what the queue came from and closes the player, like the web source link.
    private func open(_ source: QueueSource) {
        switch source.type {
        case QueueSource.playlist:
            guard library.playlist(source.id) != nil else { return }
            app.libraryPath = NavigationPath([source.id])
            app.tab = .library
        case QueueSource.collection:
            app.homePath = NavigationPath([CollectionRoute(platform: source.platform, url: source.url, title: source.name, cover: source.cover)])
            app.tab = .home
        default:
            app.homePath = NavigationPath()
            app.tab = .home
        }
        player.showsFullPlayer = false
    }

    @ViewBuilder
    private var autoplayNotice: some View {
        let message: String? = switch player.autoplayStatus {
        case .loading: Strings.autoplayLoadingNotice
        case .empty: Strings.autoplayEmpty
        case .unsupported: Strings.autoplayUnsupported
        case .error: Strings.autoplayUnavailable
        case .idle, .ready: nil
        }
        if let message {
            HStack(spacing: 8) {
                if player.autoplayStatus == .loading { ProgressView().controlSize(.small) } else { Image(systemName: "infinity") }
                Text(message).lineLimit(2)
                Spacer(minLength: 4)
                if player.autoplayStatus != .loading {
                    Button(Strings.retry) { player.retryAutoplay() }.fontWeight(.semibold).buttonStyle(.plain)
                }
            }
            .font(.footnote)
            .foregroundStyle(.white.opacity(0.85))
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(.white.opacity(0.1), in: .rect(cornerRadius: 12))
        }
    }

    /// Every song in queue order; the drag handles reorder (web `moveInQueue`).
    private func list(_ queue: PlayQueue) -> some View {
        ScrollViewReader { proxy in
            List {
                ForEach(Array(queue.items.enumerated()), id: \.element.id) { index, track in
                    row(index, track, current: index == queue.index)
                }
                .onMove { source, destination in
                    guard let from = source.first else { return }
                    player.move(from: from, to: from < destination ? destination - 1 : destination)
                }
                .onDelete { offsets in
                    for index in offsets.sorted(by: >) { player.remove(at: index) }
                }
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            .environment(\.editMode, .constant(.active))
            // Open on the playing song, centred in the list.
            .onAppear { if let id = queue.current?.id { proxy.scrollTo(id, anchor: .center) } }
        }
    }

    private func row(_ index: Int, _ track: Track, current: Bool) -> some View {
        Button {
            player.select(index)
        } label: {
            HStack(spacing: 12) {
                ArtworkView(url: track.coverURL, cornerRadius: 5)
                    .frame(width: 42, height: 42)
                    .overlay {
                        if current {
                            RoundedRectangle(cornerRadius: 5).fill(.black.opacity(0.35))
                            Image(systemName: "waveform").font(.system(size: 15, weight: .bold))
                        }
                    }
                VStack(alignment: .leading, spacing: 1) {
                    Text(track.title)
                        .fontWeight(current ? .semibold : .regular)
                        .foregroundStyle(current ? Color.accentColor : .white)
                        .lineLimit(1)
                    Text((track.artist.isEmpty ? Strings.unknownArtist : track.artist) + (track.isRecommendation ? Strings.autoplayRecommended : ""))
                        .font(.subheadline).foregroundStyle(.white.opacity(0.55)).lineLimit(1)
                }
                Spacer(minLength: 0)
            }
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .listRowBackground(Color.clear)
        .listRowSeparatorTint(.white.opacity(0.12))
    }

    private func toggle(_ label: String, _ symbol: String, on: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.body.weight(.semibold))
                .frame(maxWidth: .infinity, minHeight: 36)
                .foregroundStyle(on ? Color.black : Color.white)
        }
        .buttonStyle(.plain)
        .glassEffect(on ? .regular.tint(.white).interactive() : .regular.interactive(), in: .capsule)
        .accessibilityLabel(label)
        .accessibilityAddTraits(on ? .isSelected : [])
    }
}
