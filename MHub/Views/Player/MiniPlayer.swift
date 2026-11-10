import AVKit
import MediaPlayer
import MHubKit
import Perception
import SwiftUI

/// The tab bar accessory on iOS 26: the system draws its Liquid Glass capsule
/// and switches it to the inline placement when the tab bar minimizes.
@available(iOS 26.0, macCatalyst 26.0, *)
struct AccessoryMiniPlayer: View {
    @Environment(\.tabViewBottomAccessoryPlacement) private var placement

    var body: some View { WithPerceptionTracking { MiniPlayer(inline: placement == .inline) } }
}

/// The mini player's contents; `inline` drops the artist and next button.
struct MiniPlayer: View {
    @Environment(PlayerController.self) private var player
    var inline = false

    var body: some View {
        WithPerceptionTracking {
            HStack(spacing: 12) {
                ArtworkView(url: player.current?.coverURL, cornerRadius: 6)
                    .frame(width: 30, height: 30)
                VStack(alignment: .leading, spacing: 0) {
                    Text(player.current?.title ?? Strings.notPlaying)
                        .font(.subheadline.weight(.medium))
                        .lineLimit(1)
                    if !inline, let artist = player.current?.artist {
                        Text(artist).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    }
                }
                Spacer(minLength: 4)
                if player.phase == .loading && player.isPlaying {
                    ProgressView().controlSize(.small).frame(width: 34)
                } else {
                    Button(player.isPlaying ? "暂停" : Strings.play, systemImage: player.isPlaying ? "pause.fill" : "play.fill") {
                        player.togglePlay()
                    }
                    .labelStyle(.iconOnly)
                    .font(.title3)
                    .symbolReplaceTransition()
                    .frame(width: 34)
                    .disabled(player.current == nil)
                }
                if !inline {
                    Button("下一首", systemImage: "forward.fill") { player.next() }
                        .labelStyle(.iconOnly)
                        .font(.title3)
                        .frame(width: 34)
                        .disabled(player.current == nil)
                }
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 14)
            .contentShape(.rect)
            .onTapGesture { if player.current != nil { player.showsFullPlayer = true } }
        }
    }
}

/// Blurred artwork under a slowly flowing mesh of its colours.
struct PlayerBackground: View {
    var artwork: UIImage?
    var palette: [Color]

    var body: some View {
        WithPerceptionTracking {
            ZStack {
                Color.black
                    .overlay {
                        if let artwork {
                            Image(uiImage: artwork)
                                .resizable()
                                .scaledToFill()
                                .scaleEffect(1.6)
                                .blur(radius: 70)
                                .opacity(0.9)
                        }
                    }
                    .clipped()
                if !palette.isEmpty {
                    TimelineView(.animation(minimumInterval: 1 / 20)) { context in
                        WithPerceptionTracking {
                            let t = context.date.timeIntervalSinceReferenceDate / 9
                            Group {
                                if #available(iOS 18.0, macCatalyst 18.0, *) {
                                    MeshGradient(width: 3, height: 3, points: Self.points(t), colors: Self.colors(palette))
                                } else {
                                    // Before iOS 18: a slowly turning gradient of the same colours.
                                    LinearGradient(colors: palette, startPoint: UnitPoint(x: 0.5 + 0.5 * cos(t), y: 0),
                                                   endPoint: UnitPoint(x: 0.5 - 0.5 * cos(t), y: 1))
                                }
                            }
                            .opacity(0.72)
                        }
                    }
                }
                Color.black.opacity(0.22)
            }
            .ignoresSafeArea()
            .accessibilityHidden(true)
        }
    }

    private static func points(_ t: Double) -> [SIMD2<Float>] {
        func wobble(_ phase: Double, _ amount: Double) -> Float { Float(0.5 + sin(t + phase) * amount) }
        return [
            [0, 0], [wobble(0, 0.2), 0], [1, 0],
            [0, wobble(1.3, 0.25)], [wobble(2.1, 0.22), wobble(0.7, 0.22)], [1, wobble(2.9, 0.25)],
            [0, 1], [wobble(3.7, 0.2), 1], [1, 1],
        ]
    }

    private static func colors(_ palette: [Color]) -> [Color] {
        (0..<9).map { palette[$0 % palette.count] }
    }
}

/// Apple Music's volume row: a thin capsule that thickens while dragged.
///
/// It follows the system volume (hardware buttons move it too) and sets it
/// through a hidden `MPVolumeView`, the only public route to system volume.
/// Where that view has no slider (the Simulator), it changes the player's
/// own volume instead, so the control always works.
struct VolumeControl: View {
    @Environment(PlayerController.self) private var player
    @State private var bridge = VolumeBridge()

    var body: some View {
        WithPerceptionTracking {
            HStack(spacing: 12) {
                Image(systemName: "speaker.fill").font(.caption)
                CapsuleSlider(value: bridge.value) { bridge.set($0, player: player) }
                    .accessibilityLabel("音量")
                Image(systemName: "speaker.wave.3.fill").font(.caption)
            }
            .foregroundStyle(.white.opacity(0.6))
            .background { VolumeHost(bridge: bridge).frame(width: 1, height: 1).opacity(0.01).accessibilityHidden(true) }
        }
    }
}

@MainActor @Perceptible
final class VolumeBridge {
    var value: Double
    @PerceptionIgnored weak var slider: UISlider?
    @PerceptionIgnored private var observation: NSKeyValueObservation?

    init() {
        value = Double(AVAudioSession.sharedInstance().outputVolume)
        observation = AVAudioSession.sharedInstance().observe(\.outputVolume, options: [.new]) { @Sendable [weak self] session, _ in
            let volume = Double(session.outputVolume)
            Task { @MainActor in self?.value = volume }
        }
    }

    func set(_ volume: Double, player: PlayerController) {
        value = volume
        if let slider {
            slider.setValue(Float(volume), animated: false)
            slider.sendActions(for: .valueChanged)
        } else {
            player.setAppVolume(Float(volume))
        }
    }
}

/// Hosts the hidden system volume view and hands its slider to the bridge.
private struct VolumeHost: UIViewRepresentable {
    let bridge: VolumeBridge

    func makeUIView(context: Context) -> MPVolumeView {
        let view = MPVolumeView(frame: CGRect(x: 0, y: 0, width: 1, height: 1))
        DispatchQueue.main.async {
            bridge.slider = view.subviews.compactMap { $0 as? UISlider }.first
        }
        return view
    }

    func updateUIView(_ uiView: MPVolumeView, context: Context) {}
}

/// A horizontal capsule slider in the player style; also adjustable by VoiceOver.
struct CapsuleSlider: View {
    var value: Double
    var onChange: (Double) -> Void
    @State private var dragging = false

    var body: some View {
        WithPerceptionTracking {
            GeometryReader { geometry in
                WithPerceptionTracking {
                    ZStack(alignment: .leading) {
                        Capsule().fill(.white.opacity(0.2))
                        Capsule().fill(.white.opacity(dragging ? 1 : 0.75))
                            .frame(width: max(0, geometry.size.width * min(max(value, 0), 1)))
                    }
                    .frame(height: dragging ? 12 : 7)
                    .frame(maxHeight: .infinity)
                    .contentShape(.rect)
                    .gesture(
                        DragGesture(minimumDistance: 0)
                            .onChanged { gesture in
                                withAnimation(.snappy(duration: 0.15)) { dragging = true }
                                onChange(min(max(0, gesture.location.x / geometry.size.width), 1))
                            }
                            .onEnded { _ in withAnimation(.snappy) { dragging = false } }
                    )
                }
            }
            .frame(height: 28)
            .accessibilityElement()
            .accessibilityValue("\(Int((value * 100).rounded()))%")
            .accessibilityAdjustableAction { direction in
                onChange(min(max(0, value + (direction == .increment ? 0.0625 : -0.0625)), 1))
            }
        }
    }
}

/// AirPlay and Bluetooth output picker.
struct RoutePickerButton: UIViewRepresentable {
    func makeUIView(context: Context) -> AVRoutePickerView {
        let view = AVRoutePickerView()
        view.tintColor = .white.withAlphaComponent(0.85)
        view.activeTintColor = .white
        view.prioritizesVideoDevices = false
        return view
    }

    func updateUIView(_ uiView: AVRoutePickerView, context: Context) {}
}
