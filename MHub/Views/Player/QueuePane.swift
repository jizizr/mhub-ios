import MHubKit
import SwiftUI

/// "待播清单": shuffle / repeat / AutoPlay toggles and the upcoming songs.
struct QueuePane: View {
    @Environment(PlayerController.self) private var player

    var body: some View {
        let queue = player.queue
        VStack(spacing: 12) {
            HStack(spacing: 10) {
                toggle(Strings.shuffle, "shuffle", on: queue.shuffled) { player.toggleShuffle() }
                toggle(Strings.repeatMode, queue.repeatMode == .one ? "repeat.1" : "repeat", on: queue.repeatMode != .off) {
                    player.cycleRepeat()
                }
                toggle(Strings.autoplay, "infinity", on: queue.autoplay) { player.setAutoplay(!queue.autoplay) }
            }
            List {
                let upcoming = Array(queue.items.enumerated()).filter { $0.offset > queue.index }
                let chosen = upcoming.filter { !$0.element.isRecommendation }
                let recommended = upcoming.filter { $0.element.isRecommendation }
                Section {
                    ForEach(chosen, id: \.element.id) { row($0.offset, $0.element) }
                        .onMove { move($0, $1, in: chosen) }
                        .onDelete { remove($0, in: chosen) }
                } header: {
                    header(Strings.playingNext)
                }
                if !recommended.isEmpty || player.autoplayLoading {
                    Section {
                        ForEach(recommended, id: \.element.id) { row($0.offset, $0.element) }
                            .onDelete { remove($0, in: recommended) }
                        if player.autoplayLoading { ProgressView().frame(maxWidth: .infinity).listRowBackground(Color.clear) }
                    } header: {
                        header(Strings.fromAutoplay)
                    }
                }
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            .environment(\.editMode, .constant(.active))
        }
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

    private func header(_ title: String) -> some View {
        Text(title).font(.headline).foregroundStyle(.white).textCase(nil)
    }

    private func row(_ index: Int, _ track: Track) -> some View {
        Button {
            player.select(index)
        } label: {
            HStack(spacing: 12) {
                ArtworkView(url: track.coverURL, cornerRadius: 5).frame(width: 42, height: 42)
                VStack(alignment: .leading, spacing: 1) {
                    Text(track.title).lineLimit(1)
                    Text(track.artist).font(.subheadline).foregroundStyle(.white.opacity(0.55)).lineLimit(1)
                }
                Spacer(minLength: 0)
            }
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .listRowBackground(Color.clear)
        .listRowSeparatorTint(.white.opacity(0.12))
    }

    private func move(_ source: IndexSet, _ destination: Int, in rows: [(offset: Int, element: Track)]) {
        guard let from = source.first.map({ rows[$0].offset }) else { return }
        let to: Int
        if destination >= rows.count { to = rows.last.map(\.offset) ?? from }
        else {
            let target = rows[destination].offset
            to = from < target ? target - 1 : target
        }
        player.move(from: from, to: to)
    }

    private func remove(_ offsets: IndexSet, in rows: [(offset: Int, element: Track)]) {
        for index in offsets.map({ rows[$0].offset }).sorted(by: >) { player.remove(at: index) }
    }
}
