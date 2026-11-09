import MHubKit
import SwiftUI

/// The full player, laid out like Apple Music: artwork (or lyrics, or the
/// queue), title, progress, transport, volume and the bottom button row.
struct NowPlayingView: View {
    enum Pane { case artwork, lyrics, queue }

    @Environment(PlayerController.self) private var player
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss
    @State private var pane: Pane = .artwork
    @Namespace private var artworkSpace

    var body: some View {
        VStack(spacing: 0) {
                Capsule().fill(.white.opacity(0.4)).frame(width: 38, height: 5).padding(.top, 10)
                    .accessibilityLabel(Strings.done)
                    .onTapGesture { dismiss() }
                switch pane {
                case .artwork:
                    Spacer(minLength: 16)
                    largeArtwork
                    Spacer(minLength: 16)
                    titleRow.padding(.bottom, 18)
                case .lyrics:
                    compactHeader
                    LyricsPane().frame(maxHeight: .infinity)
                case .queue:
                    compactHeader
                    QueuePane().frame(maxHeight: .infinity)
                }
                PlayerProgress().padding(.bottom, 8)
                TransportControls().padding(.vertical, 14)
                VolumeControl().padding(.bottom, 10)
                bottomBar.padding(.bottom, 6)
        }
        .padding(.horizontal, 28)
        .foregroundStyle(.white)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        // A background never changes the layout size, however large the image.
        .background { PlayerBackground(artwork: player.artwork, palette: player.palette) }
        // Sheets opened from the player's「…」menu and from a long-pressed lyric line.
        .sheet(item: Bindable(app).lyricShare) { LyricsShareView(request: $0) }
        .sheet(isPresented: Bindable(app).showsDisplaySettings) { DisplaySettingsView() }
        .environment(\.colorScheme, .dark)
        .statusBarHidden(false)
    }

    private var largeArtwork: some View {
        ArtworkView(url: player.current?.coverURL, cornerRadius: 12)
            .aspectRatio(1, contentMode: .fit)
            .matchedGeometryEffect(id: "artwork", in: artworkSpace)
            .shadow(color: .black.opacity(player.isPlaying ? 0.4 : 0.2), radius: player.isPlaying ? 30 : 14, y: 14)
            .scaleEffect(player.isPlaying ? 1 : 0.82)
            .animation(.spring(response: 0.5, dampingFraction: 0.68), value: player.isPlaying)
            .frame(maxWidth: .infinity)
    }

    private var titleRow: some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(player.current?.title ?? Strings.notPlaying).font(.title3.weight(.semibold)).lineLimit(1)
                Text(player.current?.artist ?? "").font(.title3).foregroundStyle(.white.opacity(0.6)).lineLimit(1)
            }
            Spacer()
            if let track = player.current {
                Menu {
                    TrackMenuItems(tracks: [track], inPlayer: true)
                } label: {
                    Image(systemName: "ellipsis")
                        .font(.body.weight(.bold))
                        .frame(width: 32, height: 32)
                        .glassEffect(.regular.interactive(), in: .circle)
                }
            }
        }
    }

    private var compactHeader: some View {
        HStack(spacing: 12) {
            ArtworkView(url: player.current?.coverURL, cornerRadius: 6)
                .matchedGeometryEffect(id: "artwork", in: artworkSpace)
                .frame(width: 60, height: 60)
                .shadow(color: .black.opacity(0.25), radius: 8, y: 4)
            VStack(alignment: .leading, spacing: 2) {
                Text(player.current?.title ?? "").font(.headline).lineLimit(1)
                Text(player.current?.artist ?? "").font(.subheadline).foregroundStyle(.white.opacity(0.6)).lineLimit(1)
            }
            Spacer()
            if let track = player.current {
                Menu {
                    TrackMenuItems(tracks: [track], inPlayer: true)
                } label: {
                    Image(systemName: "ellipsis")
                        .font(.body.weight(.bold))
                        .frame(width: 32, height: 32)
                        .glassEffect(.regular.interactive(), in: .circle)
                }
            }
        }
        .padding(.vertical, 18)
        .onTapGesture { withAnimation(.spring(response: 0.45, dampingFraction: 0.85)) { pane = .artwork } }
    }

    private var bottomBar: some View {
        HStack {
            paneButton(.lyrics, symbol: "quote.bubble", label: Strings.lyrics)
            Spacer()
            RoutePickerButton().frame(width: 44, height: 44)
            Spacer()
            paneButton(.queue, symbol: "list.bullet", label: Strings.queue)
        }
        .padding(.horizontal, 26)
    }

    @ViewBuilder
    private func paneButton(_ target: Pane, symbol: String, label: String) -> some View {
        let active = pane == target
        Button {
            withAnimation(.spring(response: 0.45, dampingFraction: 0.85)) { pane = active ? .artwork : target }
        } label: {
            Image(systemName: active ? symbol + ".fill" : symbol)
                .font(.title3)
                .frame(width: 44, height: 44)
        }
        .buttonStyle(.plain)
        .glassEffect(active ? .regular.interactive() : .identity, in: .circle)
        .accessibilityLabel(label)
        .accessibilityAddTraits(active ? .isSelected : [])
    }
}

/// Seek bar with elapsed/remaining time and the quality badge.
struct PlayerProgress: View {
    @Environment(PlayerController.self) private var player
    @Environment(AppModel.self) private var app
    @State private var dragValue: Double?

    var body: some View {
        let duration = max(player.duration, 0)
        let value = dragValue ?? min(player.elapsed, duration)
        VStack(spacing: 6) {
            GeometryReader { geometry in
                let fraction = duration > 0 ? value / duration : 0
                ZStack(alignment: .leading) {
                    Capsule().fill(.white.opacity(0.2))
                    Capsule().fill(.white.opacity(dragValue == nil ? 0.75 : 1))
                        .frame(width: max(0, geometry.size.width * fraction))
                }
                .frame(height: dragValue == nil ? 7 : 12)
                .frame(maxHeight: .infinity)
                .contentShape(.rect)
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { gesture in
                            guard duration > 0 else { return }
                            let x = min(max(0, gesture.location.x / geometry.size.width), 1)
                            withAnimation(.snappy(duration: 0.15)) { dragValue = x * duration }
                        }
                        .onEnded { _ in
                            if let target = dragValue { player.seek(to: target) }
                            withAnimation(.snappy) { dragValue = nil }
                        }
                )
            }
            .frame(height: 20)
            .accessibilityElement()
            .accessibilityLabel("进度")
            .accessibilityValue(Self.format(value))
            .accessibilityAdjustableAction { direction in
                player.seek(to: max(0, min(duration, value + (direction == .increment ? 10 : -10))))
            }
            HStack {
                Text(Self.format(value)).frame(width: 60, alignment: .leading)
                Spacer()
                qualityBadge
                Spacer()
                Text("-" + Self.format(max(0, duration - value))).frame(width: 60, alignment: .trailing)
            }
            .font(.caption.monospacedDigit().weight(.medium))
            .foregroundStyle(.white.opacity(0.55))
        }
    }

    @ViewBuilder
    private var qualityBadge: some View {
        if let quality = player.playingQuality {
            Menu {
                ForEach(Quality.allCases) { option in
                    // The current quality is ticked, as in system menus.
                    Button {
                        if option != quality { player.reload(in: option) }
                    } label: {
                        if option == quality {
                            Label(Strings.replayIn(option.label), systemImage: "checkmark")
                        } else {
                            Text(Strings.replayIn(option.label))
                        }
                    }
                }
            } label: {
                HStack(spacing: 4) {
                    if quality == .lossless || quality == .hires { Image(systemName: "waveform").font(.system(size: 9, weight: .bold)) }
                    Text(quality.label).font(.system(size: 11, weight: .semibold))
                }
                .padding(.horizontal, 9)
                .frame(height: 22)
                .glassEffect(.regular.interactive(), in: .capsule)
            }
            .accessibilityLabel(Strings.quality)
        }
    }

    static func format(_ seconds: Double) -> String {
        guard seconds.isFinite else { return "0:00" }
        let total = Int(seconds.rounded(.down))
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}

struct TransportControls: View {
    @Environment(PlayerController.self) private var player

    var body: some View {
        HStack {
            Spacer()
            control("上一首", "backward.fill", size: 30) { player.previous() }
            Spacer()
            Button {
                player.togglePlay()
            } label: {
                Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
                    .font(.system(size: 46))
                    .contentTransition(.symbolEffect(.replace))
                    .frame(width: 80, height: 80)
            }
            .buttonStyle(PressScaleStyle())
            .accessibilityLabel(player.isPlaying ? "暂停" : Strings.play)
            Spacer()
            control("下一首", "forward.fill", size: 30) { player.next() }
            Spacer()
        }
        .disabled(player.current == nil)
    }

    private func control(_ label: String, _ symbol: String, size: CGFloat, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: size)).frame(width: 64, height: 64)
        }
        .buttonStyle(PressScaleStyle())
        .accessibilityLabel(label)
    }
}

/// Apple Music's transport buttons shrink and show a soft circle while pressed.
struct PressScaleStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(Circle().fill(.white.opacity(configuration.isPressed ? 0.14 : 0)))
            .scaleEffect(configuration.isPressed ? 0.86 : 1)
            .animation(.spring(response: 0.3, dampingFraction: 0.6), value: configuration.isPressed)
    }
}
