import CoreImage
import MHubKit
import Perception
import SwiftUI

/// Pick up to five lines and share them as an image card, like Apple Music
/// (docs/design.md「歌词分享」).
struct LyricsShareView: View {
    static let maxLines = 5

    @Environment(AppModel.self) private var app
    @Environment(PlayerController.self) private var player
    @Environment(\.dismiss) private var dismiss
    @Environment(\.displayScale) private var displayScale
    let request: LyricShareRequest
    @State private var selected: Set<Int> = []
    @State private var image: ShareImage?
    @State private var cardHeight: CGFloat = 0
    static let previewHeight: CGFloat = 260

    private var lines: [LyricLine] {
        player.lyrics.lines.filter { !$0.isBackground && !$0.text.trimmingCharacters(in: .whitespaces).isEmpty }
    }

    var body: some View {
        WithPerceptionTracking {
            NavigationStack {
                VStack(spacing: 0) {
                // A fixed-height preview: the card keeps its natural size (that is
                // what gets shared) and is scaled down to fit, so choosing more lines
                // never pushes the list below.
                card
                    .fixedSize(horizontal: false, vertical: true)
                    .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { cardHeight = $0 }
                    .scaleEffect(cardHeight > Self.previewHeight ? Self.previewHeight / cardHeight : 1, anchor: .top)
                    .frame(height: Self.previewHeight, alignment: .top)
                    .padding(.horizontal, 16)
                    .padding(.top, 8)
                Text(Strings.shareLyricsHint(Self.maxLines))
                    .font(.footnote).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 20).padding(.top, 10)
                ScrollViewReader { proxy in
                    WithPerceptionTracking {
                        List {
                            WithPerceptionTracking {
                                Section {
                                    ForEach(lines) { line in
                                        WithPerceptionTracking {
                                            let on = selected.contains(line.id)
                                            Button {
                                                if on { selected.remove(line.id) } else if selected.count < Self.maxLines { selected.insert(line.id) }
                                            } label: {
                                                WithPerceptionTracking {
                                                    HStack(spacing: 12) {
                                                        Image(systemName: on ? "checkmark.circle.fill" : "circle")
                                                            .foregroundStyle(on ? Color.accentColor : .secondary)
                                                        Text(app.settings.lyricScript.convert(line.text)).foregroundStyle(.primary)
                                                    }
                                                }
                                            }
                                            .id(line.id)
                                        }
                                    }
                                }
                            }
                        }
                        .onAppear {
                            if let line = request.line, lines.contains(where: { $0.id == line }) {
                                selected = [line]
                                proxy.scrollTo(line, anchor: .center)
                            }
                        }
                    }
                }
                }
                .navigationTitle(Strings.shareLyrics)
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    WithPerceptionTracking {
                        ToolbarItem(placement: .cancellationAction) {
                            Button(Strings.cancel, systemImage: "xmark") { dismiss() }
                        }
                        ToolbarItem(placement: .confirmationAction) {
                            if let image {
                                ShareLink(item: image, preview: SharePreview(Strings.shareLyrics, image: Image(uiImage: image.image))) {
                                    Label(Strings.share, systemImage: "square.and.arrow.up")
                                }
                            }
                        }
                    }
                }
                .task(id: selected) { render() }
            }
        }
    }

    private var chosen: [LyricLine] { lines.filter { selected.contains($0.id) } }

    private var card: some View {
        LyricsCard(track: request.track, artwork: player.current?.id == request.track.id ? player.artwork : nil,
                   palette: player.palette, lines: chosen, script: app.settings.lyricScript,
                   showsTranslation: app.settings.showTranslation, link: link)
    }

    private var link: URL? {
        app.settings.serverURL.flatMap { Links.shareURL(for: request.track, server: $0) }
    }

    /// The card at 1080 px wide for the share sheet.
    @MainActor private func render() {
        guard !chosen.isEmpty else { image = nil; return }
        let renderer = ImageRenderer(content: card.frame(width: 360).environment(\.colorScheme, .dark))
        renderer.scale = 3
        image = renderer.uiImage.map(ShareImage.init)
    }
}

/// A PNG for ShareLink.
struct ShareImage: Transferable {
    let image: UIImage
    static var transferRepresentation: some TransferRepresentation {
        DataRepresentation(exportedContentType: .png) { $0.image.pngData() ?? Data() }
            .suggestedFileName("lyrics.png")
    }
}

private struct LyricsCard: View {
    var track: Track
    var artwork: UIImage?
    var palette: [Color]
    var lines: [LyricLine]
    var script: LyricScript
    var showsTranslation: Bool
    var link: URL?

    var body: some View {
        WithPerceptionTracking {
            let colors = palette.isEmpty ? [Color(white: 0.24), Color(white: 0.11)] : Array(palette.prefix(2))
            VStack(alignment: .leading, spacing: 14) {
                HStack(spacing: 12) {
                    Group {
                        if let artwork {
                            Image(uiImage: artwork).resizable().scaledToFill()
                        } else {
                            Rectangle().fill(.white.opacity(0.15)).overlay(Image(systemName: "music.note").foregroundStyle(.white.opacity(0.6)))
                        }
                    }
                    .frame(width: 52, height: 52)
                    .clipShape(.rect(cornerRadius: 8))
                    VStack(alignment: .leading, spacing: 2) {
                        Text(track.title).font(.headline).lineLimit(1)
                        Text(track.artist).font(.subheadline).foregroundStyle(.white.opacity(0.7)).lineLimit(1)
                    }
                }
                .padding(.bottom, 4)
                if lines.isEmpty {
                    Text(Strings.shareLyricsEmpty).font(.title3.bold()).foregroundStyle(.white.opacity(0.6))
                }
                ForEach(lines) { line in
                    WithPerceptionTracking {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(script.convert(line.text)).font(.system(size: 24, weight: .bold))
                            if showsTranslation, !line.translation.isEmpty {
                                Text(script.convert(line.translation)).font(.callout.weight(.semibold)).foregroundStyle(.white.opacity(0.7))
                            }
                        }
                    }
                }
                HStack(alignment: .bottom) {
                    Text("MHub").font(.footnote.weight(.semibold)).foregroundStyle(.white.opacity(0.6))
                    Spacer()
                    // The song's web link, so whoever sees the card can play it.
                    if let link, let qr = QRCode.image(link.absoluteString) {
                        Image(uiImage: qr)
                            .interpolation(.none)
                            .resizable()
                            .frame(width: 54, height: 54)
                            .padding(5)
                            .background(.white, in: .rect(cornerRadius: 8))
                    }
                }
                .padding(.top, 4)
            }
            .foregroundStyle(.white)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(24)
            .background(LinearGradient(colors: colors.count > 1 ? colors : [colors[0], colors[0].opacity(0.7)],
                                       startPoint: .topLeading, endPoint: .bottomTrailing))
            .background(.black)
            .overlay(Color.black.opacity(0.18).allowsHitTesting(false).blendMode(.multiply))
            .clipShape(.rect(cornerRadius: 24))
        }
    }
}

/// A black-on-white QR code from CoreImage, one pixel per module.
enum QRCode {
    private static let context = CIContext()

    static func image(_ text: String) -> UIImage? {
        guard let filter = CIFilter(name: "CIQRCodeGenerator") else { return nil }
        filter.setValue(Data(text.utf8), forKey: "inputMessage")
        filter.setValue("M", forKey: "inputCorrectionLevel")
        guard let output = filter.outputImage, let cgImage = context.createCGImage(output, from: output.extent) else { return nil }
        return UIImage(cgImage: cgImage)
    }
}
