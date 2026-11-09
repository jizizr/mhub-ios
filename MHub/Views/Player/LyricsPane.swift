import MHubKit
import SwiftUI

/// Apple Music style lyrics.
///
/// - The focused line sits about a third down the pane. When it changes every
///   line springs to its new place, lines further down starting a little later,
///   which gives the cascading motion of Apple Music.
/// - Words fill from left to right with a feathered edge, rise slightly while
///   they are sung, and long held words glow.
/// - Other lines are dimmed (no blur); dragging the lyrics pauses following
///   for three seconds. Opening the pane shows the current line directly.
/// - Long instrumental gaps show three breathing dots.
/// - Tapping a line seeks to it.
struct LyricsPane: View {
    @Environment(PlayerController.self) private var player
    @Environment(AppModel.self) private var app
    @State private var heights: [Int: CGFloat] = [:]
    @State private var focus = 0
    @State private var interlude: Interlude?
    @State private var manualOffset: CGFloat = 0
    @State private var dragOffset: CGFloat = 0
    @State private var browsing = false
    @State private var releaseTask: Task<Void, Never>?
    /// False until the lines are measured: opening the lyrics shows the
    /// current line directly instead of scrolling down to it.
    @State private var settled = false
    /// Last time a line changed height; positions are final once heights stop changing.
    @State private var layoutChangedAt = Date.now

    private static let spacing: CGFloat = 30

    struct Interlude: Equatable {
        var before: Int
        var start: Int
        var end: Int
    }

    var body: some View {
        let lyrics = player.lyrics.applying(app.settings.lyricWordMode)
        Group {
            if lyrics.isEmpty {
                Text(player.lyricsState == .loading ? Strings.loadingLyrics : Strings.noLyrics)
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(.white.opacity(0.5))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if !lyrics.isSynced {
                ScrollView {
                    Text(lyrics.lines.map { app.settings.lyricScript.convert($0.text) }.joined(separator: "\n"))
                        .font(.title2.weight(.bold))
                        .foregroundStyle(.white.opacity(0.85))
                        .lineSpacing(14)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.vertical, 40)
                }
                .scrollIndicators(.hidden)
            } else {
                synced(lyrics)
            }
        }
    }

    private func synced(_ lyrics: Lyrics) -> some View {
        GeometryReader { geometry in
            let anchor = geometry.size.height * 0.3
            let top = (0..<focus).reduce(CGFloat(0)) { $0 + (heights[$1] ?? 60) + Self.spacing }
            let scroll = anchor - top
            VStack(alignment: .leading, spacing: Self.spacing) {
                ForEach(lyrics.lines) { line in
                    let distance = line.id - focus
                    LyricLineView(
                        line: line,
                        state: lineState(line, lyrics),
                        distance: browsing ? 0 : distance,
                        interlude: interlude?.before == line.id ? interlude : nil,
                        script: app.settings.lyricScript,
                        showsTranslation: app.settings.showTranslation,
                        showsRoman: app.settings.showRoman
                    )
                    .onGeometryChange(for: CGFloat.self) { $0.size.height } action: {
                        if heights[line.id] != $0 { layoutChangedAt = .now }
                        heights[line.id] = $0
                    }
                    .contentShape(.rect)
                    .onTapGesture {
                        player.seek(to: Double(line.start) / 1000)
                        endBrowsing()
                    }
                    // Long-pressing a line opens lyric sharing with that line chosen.
                    .onLongPressGesture {
                        guard !line.isBackground, let track = player.current else { return }
                        app.lyricShare = LyricShareRequest(track: track, line: line.id)
                    }
                    // Every line follows the focus with its own slightly later spring.
                    .offset(y: scroll + manualOffset + dragOffset)
                    .animation(
                        settled ? .spring(response: 0.62, dampingFraction: 0.84)
                            .delay(dragOffset != 0 ? 0 : Double(min(max(distance, 0), 8)) * 0.045) : nil,
                        value: focus
                    )
                }
                if !lyrics.credits.isEmpty {
                    Text(lyrics.credits.joined(separator: "\n"))
                        .font(.footnote)
                        .foregroundStyle(.white.opacity(0.4))
                        .offset(y: scroll + manualOffset + dragOffset)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .frame(height: geometry.size.height, alignment: .top)
            // Hidden until every line is measured, so the first visible frame
            // already has the current line in place.
            // As in Apple Music the lyrics appear once the artwork has moved:
            // placed at the current line while hidden, then faded in.
            .opacity(settled && heights.count >= lyrics.lines.count ? 1 : 0)
            .animation(.easeOut(duration: 0.26), value: settled)
            .contentShape(.rect)
            .gesture(
                DragGesture(minimumDistance: 6)
                    .onChanged { value in
                        browsing = true
                        releaseTask?.cancel()
                        dragOffset = value.translation.height
                    }
                    .onEnded { value in
                        manualOffset += value.predictedEndTranslation.height * 0.6 + value.translation.height * 0.4
                        dragOffset = 0
                        scheduleRelease()
                    }
            )
        }
        .clipped()
        .mask(LinearGradient(stops: [.init(color: .clear, location: 0), .init(color: .black, location: 0.1),
                                     .init(color: .black, location: 0.85), .init(color: .clear, location: 1)],
                             startPoint: .top, endPoint: .bottom))
        .animation(.easeInOut(duration: 0.4), value: browsing)
        .task(id: lyrics.lines.count) { await follow(lyrics) }
    }

    private func lineState(_ line: LyricLine, _ lyrics: Lyrics) -> LyricLineView.State {
        if interlude == nil, line.id == focus { return .active }
        // Background vocals light up together with their main line.
        if interlude == nil, line.isBackground, line.id == focus + 1 { return .active }
        return line.id < focus ? .past : .upcoming
    }

    /// Polls the player clock (cheap) and moves the focus when the line changes.
    private func follow(_ lyrics: Lyrics) async {
        let openedAt = Date.now
        while !Task.isCancelled {
            let now = Int(player.currentTime * 1000)
            let active = lyrics.activeIndex(at: now)
            var next = active ?? 0
            var gap: Interlude?
            let mainLines = lyrics.lines.filter { !$0.isBackground }
            if active == nil, let first = mainLines.first, first.start > 3000 {
                gap = Interlude(before: first.id, start: 0, end: first.start)
            } else if let active, let following = mainLines.first(where: { $0.id > active }) {
                let ended = lyrics.lines[active...].prefix { $0.id < following.id }.map(\.end).max() ?? lyrics.lines[active].end
                if following.start - ended > 4000, now > ended {
                    gap = Interlude(before: following.id, start: ended, end: following.start)
                    next = following.id
                }
            }
            if next != focus || gap != interlude {
                if settled {
                    withAnimation(.spring(response: 0.5, dampingFraction: 0.85)) {
                        interlude = gap
                        focus = next
                    }
                } else {
                    interlude = gap
                    focus = next
                }
            }
            if !settled, Date.now.timeIntervalSince(openedAt) > 0.6, Date.now.timeIntervalSince(layoutChangedAt) > 0.25,
               heights.count >= lyrics.lines.count {
                // Everything placed while the pane was still appearing jumped
                // into place; from now on line changes animate.
                settled = true
            }
            try? await Task.sleep(for: .milliseconds(60))
        }
    }

    private func scheduleRelease() {
        releaseTask?.cancel()
        releaseTask = Task {
            try? await Task.sleep(for: .seconds(3))
            guard !Task.isCancelled else { return }
            endBrowsing()
        }
    }

    private func endBrowsing() {
        releaseTask?.cancel()
        withAnimation(.spring(response: 0.7, dampingFraction: 0.86)) {
            manualOffset = 0
            dragOffset = 0
            browsing = false
        }
    }
}

private struct LyricLineView: View {
    enum State { case past, active, upcoming }

    @Environment(PlayerController.self) private var player
    var line: LyricLine
    var state: State
    var distance: Int
    var interlude: LyricsPane.Interlude?
    var script: LyricScript
    var showsTranslation: Bool
    var showsRoman: Bool

    var body: some View {
        let active = state == .active
        VStack(alignment: .leading, spacing: 8) {
            if let interlude {
                InterludeDots(interlude: interlude)
                    .transition(.scale(scale: 0.6, anchor: .leading).combined(with: .opacity))
            }
            ZStack(alignment: .topLeading) {
                if active {
                    // Only the sung line redraws every frame.
                    TimelineView(.animation) { _ in
                        WordFlow(words: line.words, now: Int(player.currentTime * 1000), script: script, background: line.isBackground)
                    }
                    .transition(.opacity)
                } else {
                    // Sung and upcoming lines rest dim, as in Apple Music; a
                    // finished line fades back instead of snapping.
                    WordFlow(words: line.words, now: Int.min, script: script, background: line.isBackground, resting: true)
                        .transition(.opacity)
                }
            }
            .animation(.easeOut(duration: 0.45), value: active)
            if showsRoman, !line.roman.isEmpty {
                Text(line.roman).font(.callout.weight(.semibold))
                    .foregroundStyle(.white.opacity(active ? 0.65 : 0.28))
            }
            if showsTranslation, !line.translation.isEmpty {
                Text(script.convert(line.translation)).font(.title3.weight(.semibold))
                    .foregroundStyle(.white.opacity(active ? 0.65 : 0.28))
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .scaleEffect(active ? 1 : 0.97, anchor: .leading)
        // No blur: lines away from the focus only dim a little further.
        .opacity(active ? 1 : (abs(distance) <= 2 ? 1 : 0.75) * (line.isBackground ? 0.7 : 1))
        .animation(.spring(response: 0.55, dampingFraction: 0.85), value: active)
        .animation(.easeOut(duration: 0.4), value: distance)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(script.convert(line.text))
        .accessibilityAddTraits(active ? .isSelected : [])
    }
}

/// Words of one line, wrapped like text. Each word is a dim layer under a
/// bright layer revealed by a feathered gradient as the word is sung.
private struct WordFlow: View {
    var words: [LyricWord]
    var now: Int
    var script: LyricScript
    var background: Bool
    var resting = false

    private static let dim = 0.3

    var body: some View {
        let font: Font = background ? .system(size: 22, weight: .bold) : .system(size: 32, weight: .bold)
        WrapLayout(lineSpacing: background ? 2 : 4) {
            ForEach(Array(words.enumerated()), id: \.offset) { _, word in
                let text = script.convert(word.text)
                let progress = Self.progress(word, now)
                let duration = word.end - word.start
                // Long held words glow and swell a little while sung.
                let held = duration >= 1000 && progress > 0 && progress < 1 && !resting
                let swell = held ? sin(.pi * progress) : 0
                Text(text)
                    .font(font)
                    .foregroundStyle(.white.opacity(Self.dim))
                    .overlay(alignment: .leading) {
                        if progress > 0 {
                            Text(text)
                                .font(font)
                                .foregroundStyle(.white)
                                .mask {
                                    LinearGradient(stops: Self.sweep(progress), startPoint: .leading, endPoint: .trailing)
                                }
                        }
                    }
                    .shadow(color: .white.opacity(0.55 * swell), radius: 10)
                    .scaleEffect(1 + 0.05 * swell, anchor: .bottom)
                    // Sung words float up slightly.
                    .offset(y: -2.5 * Self.ease(progress))
            }
        }
    }

    static func progress(_ word: LyricWord, _ now: Int) -> Double {
        if now >= word.end { return 1 }
        if now <= word.start { return 0 }
        return Double(now - word.start) / Double(max(1, word.end - word.start))
    }

    static func ease(_ t: Double) -> Double { 1 - pow(1 - min(max(t, 0), 1), 3) }

    /// A soft edge 30% of the word wide travelling from left to right.
    static func sweep(_ progress: Double) -> [Gradient.Stop] {
        let feather = 0.3
        let edge = progress * (1 + feather)
        return [
            .init(color: .white, location: max(0, edge - feather)),
            .init(color: .white.opacity(0), location: min(1, max(edge, 0.0001))),
        ]
    }
}

/// Three dots that fill one after another across an instrumental gap and
/// breathe while waiting, as in Apple Music.
private struct InterludeDots: View {
    @Environment(PlayerController.self) private var player
    var interlude: LyricsPane.Interlude

    var body: some View {
        TimelineView(.animation) { context in
            let now = Double(player.currentTime * 1000)
            let progress = min(max((now - Double(interlude.start)) / Double(max(1, interlude.end - interlude.start)), 0), 1)
            let breath = 1 + 0.08 * sin(context.date.timeIntervalSinceReferenceDate * 2.4)
            HStack(spacing: 10) {
                ForEach(0..<3, id: \.self) { index in
                    let fill = min(max(progress * 3 - Double(index), 0), 1)
                    Circle()
                        .fill(.white.opacity(0.3 + 0.7 * fill))
                        .frame(width: 13, height: 13)
                }
            }
            .scaleEffect(breath * (progress > 0.94 ? 1 - (progress - 0.94) * 4 : 1), anchor: .leading)
            .padding(.vertical, 6)
        }
        .accessibilityHidden(true)
    }
}

/// Left-aligned flow layout: places subviews in rows, wrapping at the width.
private struct WrapLayout: Layout {
    var lineSpacing: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? .infinity
        let rows = arrange(width: width, subviews: subviews)
        let height = rows.reduce(0) { $0 + $1.height } + lineSpacing * CGFloat(max(0, rows.count - 1))
        return CGSize(width: proposal.width ?? rows.map(\.width).max() ?? 0, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var y = bounds.minY
        for row in arrange(width: bounds.width, subviews: subviews) {
            var x = bounds.minX
            for index in row.indices {
                let size = subviews[index].sizeThatFits(.unspecified)
                subviews[index].place(at: CGPoint(x: x, y: y + row.height - size.height), proposal: .unspecified)
                x += size.width
            }
            y += row.height + lineSpacing
        }
    }

    private struct Row { var indices: [Int] = []; var width: CGFloat = 0; var height: CGFloat = 0 }

    private func arrange(width: CGFloat, subviews: Subviews) -> [Row] {
        var rows = [Row()]
        for index in subviews.indices {
            let size = subviews[index].sizeThatFits(.unspecified)
            if rows[rows.count - 1].width + size.width > width, !rows[rows.count - 1].indices.isEmpty {
                rows.append(Row())
            }
            rows[rows.count - 1].indices.append(index)
            rows[rows.count - 1].width += size.width
            rows[rows.count - 1].height = max(rows[rows.count - 1].height, size.height)
        }
        return rows
    }
}
