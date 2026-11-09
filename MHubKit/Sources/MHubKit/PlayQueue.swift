import Foundation

public enum RepeatMode: String, Codable, Sendable, CaseIterable {
    case off, all, one
}

/// What `next` decided.
public enum QueueAdvance: Equatable, Sendable {
    case index(Int)
    case ended
    /// At the end with AutoPlay on: fetch recommendations, append them with
    /// `appendRecommendations`, then call `next` again.
    case needsRecommendations
}

/// The play queue and its modes. Pure value logic shared in behaviour with the
/// web player and the Android app; `contract/queue-cases.json` holds the
/// cases both test suites run.
public struct PlayQueue: Codable, Sendable, Equatable {
    public private(set) var items: [Track] = []
    /// Order before shuffling; additions made while shuffled are recorded too.
    private var original: [Track]?
    public private(set) var index: Int = -1
    public private(set) var repeatMode: RepeatMode = .off
    public var shuffled: Bool { original != nil }
    public private(set) var autoplay: Bool = false

    public init() {}

    public init(items: [Track], index: Int, repeatMode: RepeatMode = .off, autoplay: Bool = false) {
        self.items = items.uniqued()
        self.index = self.items.isEmpty ? -1 : min(max(index, -1), self.items.count - 1)
        self.repeatMode = repeatMode
        self.autoplay = autoplay
    }

    public var current: Track? { items.indices.contains(index) ? items[index] : nil }
    public var isEmpty: Bool { items.isEmpty }
    public var upcoming: ArraySlice<Track> { index + 1 < items.count ? items[(index + 1)...] : [] }

    public func position(of track: Track) -> Int? { items.firstIndex { $0.id == track.id } }

    /// The item `next` would move to when the current song ends naturally,
    /// without changing anything. Used to prefetch.
    public var naturalNextIndex: Int? {
        guard !items.isEmpty else { return nil }
        if repeatMode == .one { return index >= 0 ? index : 0 }
        if index + 1 < items.count { return index + 1 }
        return repeatMode == .all ? 0 : nil
    }

    // MARK: Editing

    /// "播放全部": replaces the queue. With shuffle on, a random song starts.
    public mutating func replace(with tracks: [Track], startAt start: Int = 0, shuffle requested: Bool? = nil,
                                 using rng: inout some RandomNumberGenerator) {
        let wantsShuffle = requested ?? shuffled
        items = tracks.map(\.chosen).uniqued()
        original = nil
        guard !items.isEmpty else { index = -1; return }
        let startTrack = tracks.indices.contains(start) ? tracks[start] : items[0]
        index = position(of: startTrack) ?? 0
        if wantsShuffle {
            shuffle(keeping: Int.random(in: 0..<items.count, using: &rng), using: &rng)
            index = 0
        }
    }

    public mutating func replace(with tracks: [Track], startAt start: Int = 0, shuffle: Bool? = nil) {
        var rng = SystemRandomNumberGenerator()
        replace(with: tracks, startAt: start, shuffle: shuffle, using: &rng)
    }

    /// "立即播放": the song goes right after the current one and becomes current.
    public mutating func playNow(_ track: Track) {
        let item = track.chosen
        let after = index + 1
        if let existing = position(of: item) {
            items[existing] = item
            replaceInOriginal(item)
            move(from: existing, to: max(0, min(after, items.count - 1)))
            index = position(of: item) ?? index
        } else {
            let at = max(0, min(after, items.count))
            items.insert(item, at: at)
            original?.append(item)
            index = at
        }
    }

    /// "添加到播放队列": appends before the AutoPlay tail. Upcoming
    /// recommendations that are added again become chosen songs. Returns how
    /// many songs were added.
    @discardableResult
    public mutating func append(_ tracks: [Track]) -> Int {
        var insertion = items.count
        if let firstAuto = items.indices.first(where: { $0 > index && items[$0].isRecommendation }) {
            insertion = min(insertion, firstAuto)
        }
        var added = 0
        for track in tracks.uniqued() {
            let item = track.chosen
            if let existing = position(of: item) {
                if existing > index && items[existing].isRecommendation {
                    items[existing] = item
                    replaceInOriginal(item)
                    move(from: existing, to: max(0, min(insertion, items.count - 1)))
                    insertion += 1
                    added += 1
                }
                continue
            }
            items.insert(item, at: insertion)
            original?.append(item)
            if insertion <= index { index += 1 }
            insertion += 1
            added += 1
        }
        return added
    }

    /// "播放下一首": inserts after the current song, moving songs that are
    /// already queued. The current song itself is never moved.
    @discardableResult
    public mutating func playNext(_ tracks: [Track]) -> Int {
        let currentID = current?.id
        let next = tracks.map(\.chosen).uniqued().filter { $0.id != currentID }
        guard !next.isEmpty else { return 0 }
        let ids = Set(next.map(\.id))
        func arrange(_ list: [Track]) -> [Track] {
            var remaining = list.filter { !ids.contains($0.id) }
            let at = remaining.firstIndex { $0.id == currentID }.map { $0 + 1 } ?? 0
            remaining.insert(contentsOf: next, at: at)
            return remaining
        }
        items = arrange(items)
        if let list = original { original = arrange(list) }
        index = currentID.flatMap { id in items.firstIndex { $0.id == id } } ?? -1
        if repeatMode == .one { repeatMode = .all }
        return next.count
    }

    @discardableResult
    public mutating func remove(at position: Int) -> Track? {
        guard items.indices.contains(position) else { return nil }
        let removed = items.remove(at: position)
        original?.removeAll { $0.id == removed.id }
        if items.isEmpty {
            index = -1
        } else if position < index {
            index -= 1
        } else if index >= items.count {
            index = items.count - 1
        }
        return removed
    }

    /// Moving a song is a user choice: a moved recommendation stops being one.
    public mutating func move(from: Int, to: Int) {
        guard from != to, items.indices.contains(from), items.indices.contains(to) else { return }
        var item = items.remove(at: from)
        if item.isRecommendation {
            item.isRecommendation = false
            replaceInOriginal(item)
        }
        items.insert(item, at: to)
        if index == from { index = to }
        else if from < index && to >= index { index -= 1 }
        else if from > index && to <= index { index += 1 }
    }

    /// Refreshes a song's metadata (e.g. duration from its playback task)
    /// without changing its position or AutoPlay flag.
    public mutating func update(_ track: Track) {
        for i in items.indices where items[i].id == track.id {
            let flag = items[i].isRecommendation
            items[i] = track
            items[i].isRecommendation = flag
        }
        if let list = original, let at = list.firstIndex(where: { $0.id == track.id }) {
            let flag = list[at].isRecommendation
            original?[at] = track
            original?[at].isRecommendation = flag
        }
    }

    public mutating func clear() {
        items = []
        original = nil
        index = -1
    }

    public mutating func select(_ position: Int) {
        guard items.indices.contains(position) else { return }
        index = position
    }

    // MARK: Navigation

    public mutating func next(manual: Bool = false, using rng: inout some RandomNumberGenerator) -> QueueAdvance {
        guard !items.isEmpty else { return .ended }
        if index < 0 { index = 0; return .index(0) }
        if repeatMode == .one && !manual { return .index(index) }
        if index + 1 < items.count {
            index += 1
            return .index(index)
        }
        if autoplay { return .needsRecommendations }
        if repeatMode != .off || manual {
            if shuffled && items.count > 1 {
                shuffle(keeping: index, using: &rng)
                index = 1
            } else {
                index = 0
            }
            return .index(index)
        }
        return .ended
    }

    public mutating func next(manual: Bool = false) -> QueueAdvance {
        var rng = SystemRandomNumberGenerator()
        return next(manual: manual, using: &rng)
    }

    @discardableResult
    public mutating func previous() -> Int? {
        guard !items.isEmpty else { return nil }
        index = index > 0 ? index - 1 : items.count - 1
        return index
    }

    // MARK: Modes

    /// 全部 → 单曲 → 关闭. Repeat and AutoPlay exclude each other.
    public mutating func cycleRepeat() {
        switch repeatMode {
        case .off: repeatMode = .all
        case .all: repeatMode = .one
        case .one: repeatMode = .off
        }
        if repeatMode != .off { setAutoplay(false) }
    }

    public mutating func setRepeat(_ mode: RepeatMode) {
        repeatMode = mode
        if mode != .off { setAutoplay(false) }
    }

    public mutating func setAutoplay(_ enabled: Bool) {
        autoplay = enabled
        if enabled {
            repeatMode = .off
        } else {
            let drop = Set(items.indices.filter { $0 > index && items[$0].isRecommendation }.map { items[$0].id })
            guard !drop.isEmpty else { return }
            items.removeAll { drop.contains($0.id) }
            original?.removeAll { drop.contains($0.id) }
        }
    }

    public mutating func toggleShuffle(using rng: inout some RandomNumberGenerator) {
        if let list = original {
            let currentID = current?.id
            original = nil
            var restored = list
            if autoplay, let currentID, let at = restored.firstIndex(where: { $0.id == currentID }) {
                // Additions made while shuffled sit after the generated tail in
                // `original`; keep chosen songs ahead of recommendations.
                let upcoming = restored[(at + 1)...]
                restored = Array(restored[...at]) + upcoming.filter { !$0.isRecommendation } + upcoming.filter(\.isRecommendation)
            }
            items = restored
            index = currentID.flatMap { id in items.firstIndex { $0.id == id } } ?? (items.isEmpty ? -1 : 0)
        } else {
            guard !items.isEmpty else { return }
            shuffle(keeping: max(index, 0), using: &rng)
            index = 0
        }
        if autoplay { repeatMode = .off }
    }

    public mutating func toggleShuffle() {
        var rng = SystemRandomNumberGenerator()
        toggleShuffle(using: &rng)
    }

    /// Adds AutoPlay results to the end, skipping songs already queued.
    @discardableResult
    public mutating func appendRecommendations(_ tracks: [Track]) -> Int {
        var known = Set(items.map(\.id))
        var added = 0
        for var track in tracks where known.insert(track.id).inserted {
            track.isRecommendation = true
            items.append(track)
            original?.append(track)
            added += 1
        }
        return added
    }

    /// The latest played songs of the current platform, oldest first.
    public func autoplaySeeds(limit: Int = 10) -> [String] {
        guard let current else { return [] }
        return Array(items.prefix(max(index, 0) + 1).filter { $0.platform == current.platform }.map(\.sourceID).suffix(limit))
    }

    // MARK: Private

    private mutating func shuffle(keeping keep: Int, using rng: inout some RandomNumberGenerator) {
        guard items.count > 1 else {
            if original == nil { original = items }
            return
        }
        if original == nil { original = items }
        let safe = items.indices.contains(keep) ? keep : 0
        let first = items[safe]
        var rest = items
        rest.remove(at: safe)
        if autoplay {
            items = [first] + rest.filter { !$0.isRecommendation }.shuffled(using: &rng)
                + rest.filter(\.isRecommendation).shuffled(using: &rng)
        } else {
            items = [first] + rest.shuffled(using: &rng)
        }
    }

    private mutating func replaceInOriginal(_ item: Track) {
        guard let at = original?.firstIndex(where: { $0.id == item.id }) else { return }
        original?[at] = item
    }
}
