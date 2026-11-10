import MHubKit
import Perception
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

    /// Landscape iPad and a widened Mac window: controls on the left, lyrics
    /// or the queue beside them instead of in their place.
    @State private var wide = false

    var body: some View {
        WithPerceptionTracking {
            Group {
                if wide { wideLayout } else { narrowLayout }
            }
            .padding(.horizontal, 28)
            .foregroundStyle(.white)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .onGeometryChange(for: Bool.self) { proxy in
                proxy.size.width >= Self.wideWidth && proxy.size.width > proxy.size.height
            } action: { isWide in
                // Entering the wide layout (opening the player, or widening the
                // window) with only the artwork showing: fill the right column with
                // lyrics when the song has (or is loading) them, else the queue.
                if isWide, !wide, pane == .artwork {
                    pane = !player.lyrics.isEmpty || player.lyricsState == .loading ? .lyrics : .queue
                }
                wide = isWide
            }
            // A visible way out: a swipe down is not obvious on iPad and does not exist on Mac.
            .overlay(alignment: .topLeading) {
                if wide || Self.isMac {
                    // A plain button: the Mac style would draw its own bezel inside the glass circle.
                    Button { dismiss() } label: {
                        WithPerceptionTracking {
                            Image(systemName: "chevron.down")
                                .font(.body.weight(.semibold))
                                .frame(width: 36, height: 36)
                                .contentShape(.circle)
                        }
                    }
                    .buttonStyle(.plain)
                    .glass(.interactive, in: .circle)
                    .accessibilityLabel(Strings.done)
                    .padding(.top, 8)
                        .padding(.leading, 20)
                        .foregroundStyle(.white)
                }
            }
            // A background never changes the layout size, however large the image.
            .background { PlayerBackground(artwork: player.artwork, palette: player.palette) }
            // Sheets opened from the player's「…」menu and from a long-pressed lyric line.
            .sheet(item: Perception.Bindable(app).lyricShare.tracked) { LyricsShareView(request: $0).appEnvironment(app, player) }
            .sheet(isPresented: Perception.Bindable(app).showsDisplaySettings.tracked) { DisplaySettingsView().appEnvironment(app, player) }
            .environment(\.colorScheme, .dark)
            .statusBarHidden(false)
        }
    }

    /// iPhone and narrow windows: lyrics or the queue replace the artwork.
    private var narrowLayout: some View {
        VStack(spacing: 0) {
            grabber
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
    }

    static let wideWidth: CGFloat = 820

    #if targetEnvironment(macCatalyst)
    static let isMac = true
    #else
    static let isMac = false
    #endif

    /// Laid out like Apple Music on Mac and iPad: the window splits in two
    /// halves, a compact column of artwork, title, progress and transport
    /// centred in the left one and lyrics or the queue filling the right one.
    /// Volume sits top right; AirPlay, lyrics and queue bottom right. With
    /// neither panel open the column is centred in the whole window.
    private var wideLayout: some View {
        HStack(spacing: 0) {
            VStack(spacing: 0) {
                Spacer(minLength: 56)
                largeArtwork.frame(maxWidth: 320)
                Spacer().frame(height: 44)
                titleRow.padding(.bottom, 14)
                PlayerProgress().padding(.bottom, 6)
                TransportControls(showsModes: true)
                Spacer(minLength: 56)
            }
            .frame(maxWidth: 400)
            .frame(maxWidth: .infinity)
            if pane != .artwork {
                Group {
                    if pane == .lyrics {
                        LyricsPane(anchorFraction: 0.3)
                            .environment(\.lyricScale, 1.3)
                            .padding(.trailing, 40)
                    } else {
                        QueuePane().padding(.top, 64).padding(.trailing, 12)
                    }
                }
                .padding(.bottom, 64)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .transition(.move(edge: .trailing).combined(with: .opacity))
            }
        }
        .overlay(alignment: .topTrailing) {
            VolumeControl()
                .frame(width: 180)
                .padding(.horizontal, 16)
                .frame(height: 36)
                .glass(.regular, in: .capsule)
                .padding(.top, 8)
        }
        .overlay(alignment: .bottomTrailing) {
            HStack(spacing: 2) {
                RoutePickerButton().frame(width: 40, height: 40)
                paneButton(.lyrics, symbol: "quote.bubble", label: Strings.lyrics)
                paneButton(.queue, symbol: "list.bullet", label: Strings.queue)
            }
            .padding(4)
            .glass(.regular, in: .capsule)
            .padding(.bottom, 12)
        }
    }

    private var grabber: some View {
        Capsule().fill(.white.opacity(0.4)).frame(width: 38, height: 5).padding(.top, 10)
            .accessibilityLabel(Strings.done)
            .onTapGesture { dismiss() }
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
                    WithPerceptionTracking {
                        TrackMenuItems(tracks: [track], inPlayer: true)
                    }
                } label: {
                    WithPerceptionTracking {
                        Image(systemName: "ellipsis")
                            .font(.body.weight(.bold))
                            .frame(width: 32, height: 32)
                            .glass(.interactive, in: .circle)
                    }
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
                    WithPerceptionTracking {
                        TrackMenuItems(tracks: [track], inPlayer: true)
                    }
                } label: {
                    WithPerceptionTracking {
                        Image(systemName: "ellipsis")
                            .font(.body.weight(.bold))
                            .frame(width: 32, height: 32)
                            .glass(.interactive, in: .circle)
                    }
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
            WithPerceptionTracking {
                // Only symbols that have a filled variant switch to it (list.bullet has none).
                Image(systemName: active && UIImage(systemName: symbol + ".fill") != nil ? symbol + ".fill" : symbol)
                    .font(.title3)
                    .frame(width: 44, height: 44)
            }
        }
        .buttonStyle(.plain)
        .glass(active ? .interactive : .none, in: .circle)
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
        WithPerceptionTracking {
            let duration = max(player.duration, 0)
            let value = dragValue ?? min(player.elapsed, duration)
            VStack(spacing: 6) {
                GeometryReader { geometry in
                    WithPerceptionTracking {
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
    }

    @ViewBuilder
    private var qualityBadge: some View {
        if let quality = player.playingQuality {
            Menu {
                WithPerceptionTracking {
                    ForEach(Quality.allCases) { option in
                        WithPerceptionTracking {
                            // The current quality is ticked, as in system menus.
                            Button {
                                if option != quality { player.reload(in: option) }
                            } label: {
                                WithPerceptionTracking {
                                    if option == quality {
                                        Label(Strings.replayIn(option.label), systemImage: "checkmark")
                                    } else {
                                        Text(Strings.replayIn(option.label))
                                    }
                                }
                            }
                        }
                    }
                }
            } label: {
                WithPerceptionTracking {
                    HStack(spacing: 4) {
                        if quality == .lossless || quality == .hires { Image(systemName: "waveform").font(.system(size: 9, weight: .bold)) }
                        Text(quality.label).font(.system(size: 11, weight: .semibold))
                    }
                    .padding(.horizontal, 9)
                    .frame(height: 22)
                    .glass(.interactive, in: .capsule)
                }
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
    /// Shuffle and repeat at the ends of the row (wide player, as on Mac).
    var showsModes = false

    var body: some View {
        WithPerceptionTracking {
            HStack {
                if showsModes {
                    modeButton("随机播放", "shuffle", on: player.queue.shuffled) { player.toggleShuffle() }
                }
                Spacer()
                control("上一首", "backward.fill", size: 30) { player.previous() }
                Spacer()
                Button {
                    player.togglePlay()
                } label: {
                    WithPerceptionTracking {
                        Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
                            .font(.system(size: 46))
                            .symbolReplaceTransition()
                            .frame(width: 80, height: 80)
                    }
                }
                .buttonStyle(PressScaleStyle())
                .accessibilityLabel(player.isPlaying ? "暂停" : Strings.play)
                Spacer()
                control("下一首", "forward.fill", size: 30) { player.next() }
                Spacer()
                if showsModes {
                    let mode = player.queue.repeatMode
                    modeButton("重复", mode == .one ? "repeat.1" : "repeat", on: mode != .off) { player.cycleRepeat() }
                }
            }
            .disabled(player.current == nil)
        }
    }

    private func modeButton(_ label: String, _ symbol: String, on: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(on ? Color.accentColor : .white.opacity(0.75))
                .frame(width: 36, height: 36)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
        .accessibilityAddTraits(on ? .isSelected : [])
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
