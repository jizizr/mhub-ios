import Foundation
import Testing
@testable import MHubKit

@Suite struct LyricsTests {
    @Test func wordTimedLinesWithTranslationAndBackground() throws {
        let lyrics = Lyrics.build(from: try Fixtures.decode(LyricsPayload.self, "lyrics-words.json"))
        #expect(lyrics.hasWordTiming && lyrics.isSynced)
        #expect(lyrics.lines.map(\.text) == ["有没有人曾告诉你", "(告诉你)", "我很爱你"])
        #expect(lyrics.lines[0].translation == "Has anyone ever told you")
        #expect(lyrics.lines[1].isBackground && lyrics.lines[1].translation.isEmpty)
        #expect(lyrics.lines[2].translation == "I love you so")
        #expect(lyrics.credits == ["作词：林夕"])
        #expect(lyrics.activeIndex(at: 500) == nil)
        #expect(lyrics.activeIndex(at: 4500) == 0) // background vocal keeps its main line
        #expect(lyrics.activeIndex(at: 6000) == 2)
    }

    @Test func lrcWithRepeatedStampsAndRoman() throws {
        let lyrics = Lyrics.build(from: try Fixtures.decode(LyricsPayload.self, "lyrics-lrc.json"))
        #expect(!lyrics.hasWordTiming && lyrics.isSynced)
        #expect(lyrics.lines.map(\.text) == ["晴天", "故事的小黄花", "从出生那年就飘着", "故事的小黄花"])
        #expect(lyrics.lines.map(\.start) == [500, 12_300, 20_000, 72_300])
        #expect(lyrics.lines[0].end == 12_300 && lyrics.lines[3].end == 77_300)
        #expect(lyrics.lines[1].roman == "gu shi de xiao huang hua")
        #expect(lyrics.lines[3].roman.isEmpty)
    }

    @Test func unavailableAndUnsynced() throws {
        #expect(Lyrics.build(from: try Fixtures.decode(LyricsPayload.self, "lyrics-unavailable.json")).isEmpty)
        let plain = Lyrics.build(from: LyricsPayload(available: true, plain: "第一行\n\n第二行", translation: "", words: [], roman: "", credits: []))
        #expect(!plain.isSynced && plain.lines.map(\.start) == [0, 4000])
    }

    @Test func scriptConversion() {
        #expect(LyricScript.traditional.convert("爱你") == "愛你")
        #expect(LyricScript.simplified.convert("愛你") == "爱你")
        #expect(LyricScript.original.convert("愛") == "愛")
    }
}

/// Runs the estimate cases generated from the web player (`contract/lyrics-estimate-cases.json`).
@Suite struct WordEstimateTests {
    struct Case: Decodable, CustomTestStringConvertible {
        var name: String
        var text: String
        var start: Int
        var end: Int
        var next: Int
        var expect: [[JSONValue]]
        var testDescription: String { name }
    }

    static let cases: [Case] = {
        struct File: Decodable { var cases: [Case] }
        let url = Fixtures.contract.appendingPathComponent("lyrics-estimate-cases.json")
        return (try? JSONDecoder().decode(File.self, from: Data(contentsOf: url)).cases) ?? []
    }()

    @Test func casesLoaded() { #expect(Self.cases.count >= 5) }

    @Test(arguments: cases) func run(_ c: Case) {
        let line = LyricLine(id: 0, start: c.start, end: c.end, words: [LyricWord(start: c.start, end: c.end, text: c.text)],
                             translation: "", roman: "", isBackground: false)
        let words = WordEstimate.estimate(line, nextStart: c.next).words
        #expect(words.map(\.start) == c.expect.compactMap { $0[0].int })
        #expect(words.map(\.end) == c.expect.compactMap { $0[1].int })
        #expect(words.map(\.text) == c.expect.compactMap { $0[2].string })
    }

    @Test func modesKeepRealTimingAndBackground() throws {
        let words = Lyrics.build(from: try Fixtures.decode(LyricsPayload.self, "lyrics-words.json"))
        #expect(words.applying(.estimate) == words)
        #expect(words.applying(.line).lines[0].words.count == 1)
        let lrc = Lyrics.build(from: try Fixtures.decode(LyricsPayload.self, "lyrics-lrc.json")).applying(.estimate)
        #expect(lrc.lines[0].words.map(\.text) == ["晴", "天"])
    }
}
