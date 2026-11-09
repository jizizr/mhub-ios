import Foundation
import Testing
@testable import MHubKit

/// Runs the queue cases shared with Android (`contract/queue-cases.json`).
@Suite struct QueueCasesTests {
    struct Case: Decodable, CustomTestStringConvertible {
        struct State: Decodable {
            var queue: [String]
            var index: Int
            var `repeat`: String?
            var autoplay: Bool?
        }
        var name: String
        var initial: State
        var ops: [[String: JSONValue]]
        var expect: [String: JSONValue]
        var testDescription: String { name }
    }

    static func track(_ token: String) -> Track {
        let recommended = token.hasSuffix("*")
        let id = recommended ? String(token.dropLast()) : token
        return Track(platform: "t", sourceID: id, title: id, artist: "", isRecommendation: recommended)
    }

    static func token(_ track: Track) -> String { track.sourceID + (track.isRecommendation ? "*" : "") }

    static let cases: [Case] = {
        let url = Fixtures.contract.appendingPathComponent("queue-cases.json")
        struct File: Decodable { var cases: [Case] }
        return (try? JSONDecoder().decode(File.self, from: Data(contentsOf: url)).cases) ?? []
    }()

    @Test func casesLoaded() { #expect(Self.cases.count >= 30) }

    @Test(arguments: cases) func run(_ testCase: Case) throws {
        var queue = PlayQueue(items: testCase.initial.queue.map(Self.track), index: testCase.initial.index,
                              repeatMode: RepeatMode(contract: testCase.initial.repeat ?? "off"),
                              autoplay: testCase.initial.autoplay ?? false)
        var result: JSONValue?
        var count: Int?
        var rng = SeededGenerator(seed: 7)
        for op in testCase.ops {
            let tracks = op["tracks"]?.array?.compactMap(\.string).map(Self.track) ?? []
            switch op["op"]?.string {
            case "replace": queue.replace(with: tracks, startAt: op["start"]?.int ?? 0, shuffle: false, using: &rng)
            case "playNow": queue.playNow(Self.track(op["track"]?.string ?? ""))
            case "append": count = queue.append(tracks)
            case "playNext": count = queue.playNext(tracks)
            case "appendRecommendations": count = queue.appendRecommendations(tracks)
            case "remove": queue.remove(at: op["index"]?.int ?? -1)
            case "move": queue.move(from: op["from"]?.int ?? -1, to: op["to"]?.int ?? -1)
            case "clear": queue.clear()
            case "next":
                switch queue.next(manual: op["manual"]?.bool ?? false, using: &rng) {
                case let .index(i): result = .number(Double(i))
                case .ended: result = .string("ended")
                case .needsRecommendations: result = .string("autoplay")
                }
            case "previous": result = queue.previous().map { .number(Double($0)) }
            case "cycleRepeat": queue.cycleRepeat()
            case "setAutoplay": queue.setAutoplay(op["enabled"]?.bool ?? false)
            case "toggleShuffle": queue.toggleShuffle(using: &rng)
            default: Issue.record("unknown op \(op)")
            }
        }
        let tokens = queue.items.map(Self.token)
        let e = testCase.expect
        if let expected = e["queue"]?.array?.compactMap(\.string) { #expect(tokens == expected) }
        if let expected = e["index"]?.int { #expect(queue.index == expected) }
        if let expected = e["repeat"]?.string { #expect(queue.repeatMode == RepeatMode(contract: expected)) }
        if let expected = e["shuffle"]?.bool { #expect(queue.shuffled == expected) }
        if let expected = e["autoplay"]?.bool { #expect(queue.autoplay == expected) }
        if let expected = e["result"] { #expect(result == expected) }
        if let expected = e["count"]?.int { #expect(count == expected) }
        if let expected = e["first"]?.string { #expect(tokens.first == expected) }
        if let expected = e["set"]?.array?.compactMap(\.string) { #expect(Set(tokens) == Set(expected) && tokens.count == expected.count) }
        if let expected = e["tail"]?.array?.compactMap(\.string) { #expect(Set(tokens.suffix(expected.count)) == Set(expected)) }
    }
}

extension RepeatMode {
    init(contract value: String) { self = RepeatMode(rawValue: value) ?? .off }
}

/// Deterministic generator so shuffle cases are reproducible.
struct SeededGenerator: RandomNumberGenerator {
    var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}

enum JSONValue: Decodable, Equatable, Sendable {
    case string(String), number(Double), bool(Bool), array([JSONValue]), object([String: JSONValue]), null

    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .null }
        else if let v = try? c.decode(Bool.self) { self = .bool(v) }
        else if let v = try? c.decode(Double.self) { self = .number(v) }
        else if let v = try? c.decode(String.self) { self = .string(v) }
        else if let v = try? c.decode([JSONValue].self) { self = .array(v) }
        else { self = .object(try c.decode([String: JSONValue].self)) }
    }

    var string: String? { if case let .string(v) = self { v } else { nil } }
    var int: Int? { if case let .number(v) = self { Int(v) } else { nil } }
    var bool: Bool? { if case let .bool(v) = self { v } else { nil } }
    var array: [JSONValue]? { if case let .array(v) = self { v } else { nil } }
}
