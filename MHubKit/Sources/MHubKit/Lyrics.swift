import Foundation

public struct LyricWord: Sendable, Equatable {
    public var start: Int
    public var end: Int
    public var text: String
}

public struct LyricLine: Sendable, Equatable, Identifiable {
    public var id: Int
    /// Milliseconds.
    public var start: Int
    public var end: Int
    public var words: [LyricWord]
    public var translation: String
    public var roman: String
    /// Background vocals, shown smaller under the preceding main line.
    public var isBackground: Bool

    public var text: String { words.map(\.text).joined() }
}

/// Lyrics as the player shows them. Built the same way as the web player's
/// `buildLyricLines` and the Android `Lyrics.build`.
public struct Lyrics: Sendable, Equatable {
    public var lines: [LyricLine]
    public var credits: [String]
    /// Lines carry real timestamps (LRC or word timing).
    public var isSynced: Bool
    /// Lines carry per-word timing.
    public var hasWordTiming: Bool

    public static let empty = Lyrics(lines: [], credits: [], isSynced: false, hasWordTiming: false)

    public var isEmpty: Bool { lines.isEmpty }

    public static func build(from payload: LyricsPayload) -> Lyrics {
        guard payload.available else { return .empty }
        var lines: [LyricLine]
        var synced = true
        var wordTimed = false
        let wordLines = payload.words.compactMap { line -> LyricLine? in
            let words = line.words.map { LyricWord(start: $0.start, end: $0.end, text: $0.text) }
            guard !words.map(\.text).joined().trimmingCharacters(in: .whitespaces).isEmpty else { return nil }
            return LyricLine(id: 0, start: line.start, end: line.end, words: words, translation: "", roman: "",
                             isBackground: line.bg ?? false)
        }
        if !wordLines.isEmpty {
            lines = wordLines
            wordTimed = true
        } else if payload.plain.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            // Only a translation exists: show it as the lyrics.
            (lines, synced) = parse(payload.translation)
            return finish(lines, payload: payload, synced: synced, wordTimed: false, sides: false)
        } else {
            (lines, synced) = parse(payload.plain)
        }
        return finish(lines, payload: payload, synced: synced, wordTimed: wordTimed, sides: true)
    }

    private static func finish(_ input: [LyricLine], payload: LyricsPayload, synced: Bool, wordTimed: Bool, sides: Bool) -> Lyrics {
        var lines = input
        if sides {
            lines = merge(lines, side: payload.translation, into: \.translation)
            if !payload.roman.isEmpty { lines = merge(lines, side: payload.roman, into: \.roman) }
        }
        for i in lines.indices { lines[i].id = i }
        return Lyrics(lines: lines, credits: payload.credits, isSynced: synced, hasWordTiming: wordTimed)
    }

    /// Index of the main line playing at `ms`, or nil before the first line.
    public func activeIndex(at ms: Int) -> Int? {
        var low = 0, high = lines.count - 1, found: Int?
        while low <= high {
            let mid = (low + high) / 2
            if lines[mid].start <= ms { found = mid; low = mid + 1 } else { high = mid - 1 }
        }
        guard var index = found else { return nil }
        // Background vocals follow their main line; highlight the main line.
        while index > 0 && lines[index].isBackground && lines[index - 1].end > lines[index].start {
            index -= 1
        }
        return index
    }

    // MARK: Parsing

    private static let stamp = try! NSRegularExpression(pattern: #"\[(\d{1,3}):(\d{1,2})(?:[.:](\d{1,3}))?\]"#)

    /// Parses LRC (several timestamps per line allowed) or unsynced text.
    static func parse(_ text: String) -> ([LyricLine], synced: Bool) {
        let source = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !source.isEmpty else { return ([], true) }
        var timed: [(Int, String)] = []
        var anyStamp = false
        for raw in source.components(separatedBy: .newlines) {
            let ns = raw as NSString
            let matches = stamp.matches(in: raw, range: NSRange(location: 0, length: ns.length))
            guard !matches.isEmpty else { continue }
            anyStamp = true
            // Timestamps lead the line; the text follows the last one.
            let lastEnd = matches.last!.range.location + matches.last!.range.length
            let body = ns.substring(from: lastEnd).trimmingCharacters(in: .whitespaces)
            guard !body.isEmpty else { continue }
            for match in matches {
                let minutes = Int(ns.substring(with: match.range(at: 1))) ?? 0
                let seconds = Int(ns.substring(with: match.range(at: 2))) ?? 0
                var millis = 0
                if match.range(at: 3).location != NSNotFound {
                    let fraction = ns.substring(with: match.range(at: 3))
                    millis = Int(fraction.padding(toLength: 3, withPad: "0", startingAt: 0)) ?? 0
                }
                timed.append(((minutes * 60 + seconds) * 1000 + millis, body))
            }
        }
        if anyStamp {
            timed.sort { $0.0 < $1.0 }
            let lines = timed.enumerated().map { offset, item in
                let end = offset + 1 < timed.count ? timed[offset + 1].0 : item.0 + 5000
                return LyricLine(id: 0, start: item.0, end: end, words: [LyricWord(start: item.0, end: end, text: item.1)],
                                 translation: "", roman: "", isBackground: false)
            }
            return (lines, true)
        }
        let plain = source.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        let lines = plain.enumerated().map { offset, text in
            let start = offset * 4000
            return LyricLine(id: 0, start: start, end: start + 3800, words: [LyricWord(start: start, end: start + 3800, text: text)],
                             translation: "", roman: "", isBackground: false)
        }
        return (lines, false)
    }

    /// Attaches each side line to the nearest unused main line within a second.
    static func merge(_ lines: [LyricLine], side: String, into field: WritableKeyPath<LyricLine, String>) -> [LyricLine] {
        let sideLines = parse(side).0
        guard !sideLines.isEmpty else { return lines }
        var used = Set<Int>()
        return lines.map { line in
            guard !line.isBackground, line[keyPath: field].isEmpty else { return line }
            var best: Int?
            var distance = 1001
            for (i, candidate) in sideLines.enumerated() where !used.contains(i) {
                let delta = abs(candidate.start - line.start)
                if delta < distance { best = i; distance = delta }
            }
            var copy = line
            if let best {
                used.insert(best)
                copy[keyPath: field] = sideLines[best].text.trimmingCharacters(in: .whitespaces)
            }
            return copy
        }
    }
}

/// 原文 / 简体 / 繁體, converted with the system ICU transliterator.
public enum LyricScript: String, Codable, CaseIterable, Sendable, Identifiable {
    case original, simplified, traditional

    public var id: String { rawValue }

    public var label: String {
        switch self {
        case .original: "原文"
        case .simplified: "简体"
        case .traditional: "繁體"
        }
    }

    public func convert(_ text: String) -> String {
        switch self {
        case .original: text
        case .simplified: text.applyingTransform(StringTransform("Hant-Hans"), reverse: false) ?? text
        case .traditional: text.applyingTransform(StringTransform("Hans-Hant"), reverse: false) ?? text
        }
    }
}

/// How word highlighting is produced, the same three modes as the web player.
public enum LyricWordMode: String, Codable, CaseIterable, Sendable, Identifiable {
    /// Real word timing only; line-only lyrics highlight whole lines.
    case native
    /// Real word timing, estimated for lines that have none.
    case estimate
    /// Whole-line highlighting even when word timing exists.
    case line

    public var id: String { rawValue }

    public var label: String {
        switch self {
        case .native: "仅原生逐字"
        case .estimate: "估算逐字"
        case .line: "整行"
        }
    }
}

extension Lyrics {
    /// Applies a word mode; ports `applyWordMode` from the web player.
    public func applying(_ mode: LyricWordMode) -> Lyrics {
        guard isSynced else { return self }
        var copy = self
        switch mode {
        case .native:
            return self
        case .line:
            copy.lines = lines.map { line in
                guard line.words.count > 1 else { return line }
                var whole = line
                whole.words = [LyricWord(start: line.start, end: line.end, text: line.text)]
                return whole
            }
        case .estimate:
            copy.lines = lines.enumerated().map { index, line in
                guard !line.isBackground, line.words.count == 1 else { return line }
                let next = lines[(index + 1)...].first { !$0.isBackground }?.start
                return WordEstimate.estimate(line, nextStart: next)
            }
        }
        return copy
    }
}

/// Spreads a line-only lyric line over its sung units (web `estimateLineWords`).
/// Time is proportional to syllables, not to the whole gap before the next line.
enum WordEstimate {
    static let maxUnitMs = 600.0
    static let minUnitMs = 120.0
    static let sungShare = 0.9

    struct Unit { var text: String; var weight: Int }

    private static let syllabic = try! NSRegularExpression(pattern: #"[\p{Script=Han}\p{Script=Hiragana}\p{Script=Katakana}\p{Script=Hangul}]"#)
    private static let letter = try! NSRegularExpression(pattern: #"[\p{L}\p{N}'’]"#)
    private static let vowels = try! NSRegularExpression(pattern: "[aeiouyàáâãäåèéêëìíîïòóôõöùúûüāēīōū]+")

    private static func matches(_ regex: NSRegularExpression, _ text: String) -> Bool {
        regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil
    }

    static func syllables(_ word: String) -> Int {
        let lower = word.lowercased()
        let count = vowels.numberOfMatches(in: lower, range: NSRange(lower.startIndex..., in: lower))
        return min(4, max(1, count))
    }

    /// One unit per CJK/kana/hangul character, one per Latin word; spaces and
    /// punctuation stay with the unit before them, or lead the first one.
    static func units(_ text: String) -> [Unit] {
        var units: [Unit] = []
        var prefix = ""
        let chars = text.map(String.init)
        var index = 0
        while index < chars.count {
            let char = chars[index]
            if matches(syllabic, char) {
                units.append(Unit(text: prefix + char, weight: 1))
                prefix = ""
                index += 1
            } else if matches(letter, char) {
                var word = ""
                while index < chars.count, matches(letter, chars[index]), !matches(syllabic, chars[index]) {
                    word += chars[index]
                    index += 1
                }
                units.append(Unit(text: prefix + word, weight: syllables(word)))
                prefix = ""
            } else {
                if units.isEmpty { prefix += char } else { units[units.count - 1].text += char }
                index += 1
            }
        }
        if !prefix.isEmpty { units.append(Unit(text: prefix, weight: 0)) }
        return units
    }

    static func estimate(_ line: LyricLine, nextStart: Int?) -> LyricLine {
        let units = units(line.text)
        let weight = units.reduce(0) { $0 + $1.weight }
        guard units.count >= 2, weight > 0 else { return line }
        let limit = nextStart.flatMap { $0 > line.start ? $0 : nil } ?? line.end
        let available = Double(max(0, limit - line.start)) * sungShare
        let unit = min(maxUnitMs, max(minUnitMs, available / Double(weight)))
        var time = Double(line.start)
        var copy = line
        copy.words = units.map { item in
            let start = Int(time.rounded())
            time += unit * Double(item.weight)
            return LyricWord(start: start, end: max(start + 1, Int(time.rounded())), text: item.text)
        }
        return copy
    }
}
