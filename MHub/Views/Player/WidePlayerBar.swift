import MHubKit
import Perception
import SwiftUI

/// The player bar of the Mac window and of iPad at regular width, floating
/// over the bottom of the page like Apple Music's on macOS 26: a Liquid Glass capsule at most 600 points wide,
/// centred, with transport on the left, the song (and a hairline seek bar
/// along its bottom edge) in the middle, and the menu, lyrics, queue and
/// volume on the right. Clicking the song opens the full player; the lyrics
/// and queue buttons open it on that panel.
struct WidePlayerBar: View {
    @Environment(PlayerController.self) private var player
    @Environment(AppModel.self) private var app
    @State private var showsVolume = false

    static let maxWidth: CGFloat = 600

    var body: some View {
        WithPerceptionTracking {
            HStack(spacing: 4) {
                transport
                nowPlaying
                trailing
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 10)
            .frame(height: 48)
            .glass(.regular, in: .capsule)
            .shadow(color: .black.opacity(0.12), radius: 14, y: 6)
            .frame(maxWidth: Self.maxWidth)
            .padding(.horizontal, 16)
            .padding(.bottom, 12)
            .frame(maxWidth: .infinity)
        }
    }

    private var transport: some View {
        HStack(spacing: 2) {
            let mode = player.queue.repeatMode
            modeButton(Strings.shuffle, "shuffle", on: player.queue.shuffled) { player.toggleShuffle() }
            iconButton("上一首", "backward.fill", size: 15) { player.previous() }
            Group {
                if player.phase == .loading && player.isPlaying {
                    ProgressView().controlSize(.small).frame(width: 32, height: 32)
                } else {
                    iconButton(player.isPlaying ? "暂停" : Strings.play, player.isPlaying ? "pause.fill" : "play.fill", size: 19) {
                        player.togglePlay()
                    }
                    .symbolReplaceTransition()
                }
            }
            iconButton("下一首", "forward.fill", size: 15) { player.next() }
            modeButton("重复", mode == .one ? "repeat.1" : "repeat", on: mode != .off) { player.cycleRepeat() }
        }
        .disabled(player.current == nil)
    }

    /// Artwork, title and「artist — album」, with the seek bar along the bottom.
    private var nowPlaying: some View {
        HStack(spacing: 8) {
            ArtworkView(url: player.current?.coverURL, cornerRadius: 5)
                .frame(width: 32, height: 32)
            VStack(alignment: .leading, spacing: 0) {
                Text(player.current?.title ?? Strings.notPlaying)
                    .font(.system(size: 13, weight: .semibold))
                    .lineLimit(1)
                if let track = player.current {
                    Text(track.album.isEmpty ? track.artist : "\(track.artist) — \(track.album)")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 6)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .contentShape(.rect)
        .onTapGesture { open(nil) }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
        .help("打开播放器")
        .overlay(alignment: .bottom) { MacSeekBar().padding(.horizontal, 4) }
    }

    private var trailing: some View {
        HStack(spacing: 0) {
            if let track = player.current {
                Menu {
                    WithPerceptionTracking { TrackMenuItems(tracks: [track], inPlayer: true) }
                } label: {
                    Image(systemName: "ellipsis")
                        .font(.system(size: 14, weight: .semibold))
                        .frame(width: 30, height: 32)
                        .contentShape(.rect)
                }
                .menuIndicator(.hidden)
                .fixedSize()
                .help("更多")
            }
            iconButton(Strings.lyrics, "quote.bubble", size: 14) { open(.lyrics) }
            iconButton(Strings.queue, "list.bullet", size: 14) { open(.queue) }
            iconButton("音量", "speaker.wave.2.fill", size: 14) { showsVolume.toggle() }
                .popover(isPresented: $showsVolume, arrowEdge: .top) {
                    MacVolumeSlider()
                        .frame(width: 180)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 10)
                        .appEnvironment(app, player)
                }
        }
    }

    private func open(_ pane: NowPlayingView.Pane?) {
        guard player.current != nil || pane == .queue else { return }
        app.playerPane = pane
        player.showsFullPlayer = true
    }

    private func iconButton(_ label: String, _ symbol: String, size: CGFloat, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: size, weight: .semibold))
                .frame(width: 32, height: 32)
                .contentShape(.rect)
        }
        .accessibilityLabel(label)
        .help(label)
    }

    private func modeButton(_ label: String, _ symbol: String, on: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(on ? Color.accentColor : .secondary)
                .frame(width: 26, height: 32)
                .contentShape(.rect)
        }
        .accessibilityLabel(label)
        .accessibilityAddTraits(on ? .isSelected : [])
        .help(label)
    }
}

/// The hairline seek bar along the bottom of the song: 2 points at rest,
/// 5 under the pointer or while dragged, with the elapsed and remaining time
/// shown above its ends meanwhile.
private struct MacSeekBar: View {
    @Environment(PlayerController.self) private var player
    @State private var dragValue: Double?
    @State private var hovering = false

    var body: some View {
        WithPerceptionTracking {
            let duration = max(player.duration, 0)
            let value = dragValue ?? min(player.elapsed, duration)
            let active = hovering || dragValue != nil
            GeometryReader { geometry in
                WithPerceptionTracking {
                    let fraction = duration > 0 ? value / duration : 0
                    ZStack(alignment: .leading) {
                        Capsule().fill(.primary.opacity(0.12))
                        Capsule().fill(.primary.opacity(active ? 0.8 : 0.45))
                            .frame(width: max(0, geometry.size.width * fraction))
                    }
                    .frame(height: active ? 5 : 2)
                    .frame(maxHeight: .infinity, alignment: .bottom)
                    .padding(.bottom, 3)
                    .contentShape(.rect)
                    .onHover { inside in withAnimation(.snappy(duration: 0.15)) { hovering = inside } }
                    .gesture(
                        DragGesture(minimumDistance: 0)
                            .onChanged { gesture in
                                guard duration > 0 else { return }
                                dragValue = min(max(0, gesture.location.x / geometry.size.width), 1) * duration
                            }
                            .onEnded { _ in
                                if let target = dragValue { player.seek(to: target) }
                                dragValue = nil
                            }
                    )
                }
            }
            .frame(height: 12)
            .overlay(alignment: .top) {
                if active && duration > 0 {
                    HStack {
                        Text(PlayerProgress.format(value))
                        Spacer()
                        Text("-" + PlayerProgress.format(max(0, duration - value)))
                    }
                    .font(.system(size: 10, weight: .medium).monospacedDigit())
                    .foregroundStyle(.secondary)
                    .offset(y: -12)
                    .allowsHitTesting(false)
                    .transition(.opacity)
                }
            }
            .accessibilityElement()
            .accessibilityLabel("进度")
            .accessibilityValue(PlayerProgress.format(value))
            .accessibilityAdjustableAction { direction in
                player.seek(to: max(0, min(duration, value + (direction == .increment ? 10 : -10))))
            }
        }
    }
}

/// System (or, failing that, the player's own) volume in the window's colours.
private struct MacVolumeSlider: View {
    @Environment(PlayerController.self) private var player
    @State private var bridge = VolumeBridge()

    var body: some View {
        WithPerceptionTracking {
            HStack(spacing: 6) {
                Image(systemName: bridge.value <= 0.001 ? "speaker.slash.fill" : "speaker.fill")
                    .font(.system(size: 10))
                    .frame(width: 14)
                CapsuleSlider(value: bridge.value, color: .primary, height: (4, 6)) { bridge.set($0, player: player) }
                    .accessibilityLabel("音量")
            }
            .foregroundStyle(.secondary)
            .background { VolumeHost(bridge: bridge).frame(width: 1, height: 1).opacity(0.01).accessibilityHidden(true) }
        }
    }
}

/// The menu bar's「控制」menu with Apple Music's shortcuts: Space plays or
/// pauses, ⌘→ / ⌘← skip. Volume stays on the system keys.
struct PlaybackCommands: Commands {
    let player: PlayerController

    var body: some Commands {
        CommandMenu("控制") {
            Button("播放／暂停") { player.togglePlay() }
                .keyboardShortcut(.space, modifiers: [])
            Button("下一首") { player.next() }
                .keyboardShortcut(.rightArrow, modifiers: .command)
            Button("上一首") { player.previous() }
                .keyboardShortcut(.leftArrow, modifiers: .command)
            Divider()
            Button(Strings.shuffle) { player.toggleShuffle() }
                .keyboardShortcut("s", modifiers: .command)
            Button("切换重复模式") { player.cycleRepeat() }
                .keyboardShortcut("r", modifiers: .command)
            Divider()
            Button("显示播放器") { player.showsFullPlayer.toggle() }
                .keyboardShortcut("f", modifiers: [.command, .shift])
        }
    }
}
