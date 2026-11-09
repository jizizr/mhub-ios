import Foundation
import Testing
@testable import MHubKit

/// Runs `contract/rate-limit-cases.json`, the 429 handling shared with Android and the web client.
@Suite(.serialized) struct RateLimitTests {
    struct Cases: Decodable {
        struct RetryAfter: Decodable, CustomTestStringConvertible {
            var name: String
            var header: String?
            var now_ms: Double
            var expect_ms: Int
            var testDescription: String { name }
        }
        struct Response: Decodable {
            var status: Int
            var retry_after: String?
            var detail: String?
        }
        struct Expect: Decodable {
            var waits: [Int]
            var outcome: String
            var retry_after_ms: Int?
            var message: String?
            var status: Int?
        }
        struct Waits: Decodable, CustomTestStringConvertible {
            var name: String
            var max_wait_ms: Int
            var responses: [Response]
            var expect: Expect
            var testDescription: String { name }
        }
        struct Seconds: Decodable { var ms: Int; var expect: Int }
        struct Prefetch: Decodable { var attempt: Int; var retry_after_ms: Int; var expect_ms: Int }
        var limits_ms: [String: Int]
        var retry_after: [RetryAfter]
        var waits: [Waits]
        var seconds: [Seconds]
        var prefetch_delay: [Prefetch]
    }

    static let cases: Cases? = {
        let url = Fixtures.contract.appendingPathComponent("rate-limit-cases.json")
        return try? JSONDecoder().decode(Cases.self, from: Data(contentsOf: url))
    }()

    @Test func casesLoaded() throws {
        let cases = try #require(Self.cases)
        #expect(cases.waits.count >= 5)
        #expect(cases.limits_ms["default"] == RateLimitPolicy.standard.maxWaitMs)
        #expect(cases.limits_ms["prefetch"] == RateLimitPolicy.prefetch.maxWaitMs)
        #expect(cases.limits_ms["playback"] == RateLimitPolicy.playback().maxWaitMs)
        #expect(cases.limits_ms["import"] == RateLimitPolicy.importing().maxWaitMs)
    }

    @Test(arguments: cases?.retry_after ?? []) func retryAfter(_ c: Cases.RetryAfter) {
        #expect(RateLimit.retryAfterMs(c.header, now: Date(timeIntervalSince1970: c.now_ms / 1000)) == c.expect_ms)
    }

    @Test func secondsAndPrefetchDelay() throws {
        let cases = try #require(Self.cases)
        for c in cases.seconds { #expect(RateLimit.seconds(c.ms) == c.expect) }
        for c in cases.prefetch_delay {
            #expect(RateLimit.prefetchDelayMs(attempt: c.attempt, retryAfterMs: c.retry_after_ms) == c.expect_ms)
        }
    }

    /// Each case runs through `MHubClient` against a mock server answering in order.
    @Test(arguments: cases?.waits ?? []) func waits(_ c: Cases.Waits) async throws {
        MockServer.responses = c.responses
        let waits = Recorder()
        let client = MHubClient(server: URL(string: "https://mock.test")!, session: MockServer.session) { await waits.add($0) }
        let notices = Recorder()
        let policy = RateLimitPolicy(maxWaitMs: c.max_wait_ms) { ms in Task { await notices.add(ms) } }
        var outcome = "ok"
        do {
            _ = try await client.createPlayback(Track(platform: "applemusic", sourceID: "1", title: "t", artist: "a"), quality: .lossless,
                                                rateLimit: policy)
        } catch let error as APIError {
            switch error {
            case let .rateLimited(retryAfterMs, _):
                outcome = "rate_limited"
                #expect(retryAfterMs == c.expect.retry_after_ms)
                #expect(error.localizedDescription == c.expect.message)
            case let .http(status, _):
                outcome = "http"
                #expect(status == c.expect.status)
            default:
                Issue.record("unexpected \(error)")
            }
        }
        #expect(outcome == c.expect.outcome)
        #expect(await waits.values == c.expect.waits)
        #expect(MockServer.requests == c.expect.waits.count + 1)
    }

    @Test func cancellingStopsTheWait() async {
        MockServer.responses = [.init(status: 429, retry_after: "60", detail: nil)]
        let client = MHubClient(server: URL(string: "https://mock.test")!, session: MockServer.session)
        let task = Task {
            try await client.createPlayback(Track(platform: "applemusic", sourceID: "1", title: "t", artist: "a"), quality: .lossless,
                                            rateLimit: .playback())
        }
        try? await Task.sleep(for: .milliseconds(200))
        task.cancel()
        let result = await task.result
        #expect(throws: CancellationError.self) { try result.get() }
        #expect(MockServer.requests == 1)
    }
}

actor Recorder {
    var values: [Int] = []
    func add(_ value: Int) { values.append(value) }
}

/// Answers every request with the next scripted response.
final class MockServer: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var responses: [RateLimitTests.Cases.Response] = [] { didSet { requests = 0 } }
    nonisolated(unsafe) static var requests = 0

    static let session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MockServer.self]
        return URLSession(configuration: config)
    }()

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let index = Self.requests
        Self.requests += 1
        let scripted = index < Self.responses.count ? Self.responses[index] : .init(status: 500, retry_after: nil, detail: "unscripted")
        var headers = ["Content-Type": "application/json"]
        if let retry = scripted.retry_after { headers["Retry-After"] = retry }
        let body: Data
        if scripted.status < 300 {
            body = (try? Fixtures.data("playback-streaming.json")) ?? Data()
        } else if let detail = scripted.detail {
            body = (try? JSONSerialization.data(withJSONObject: ["detail": detail])) ?? Data()
        } else {
            body = Data()
        }
        let response = HTTPURLResponse(url: request.url!, statusCode: scripted.status, httpVersion: "HTTP/1.1", headerFields: headers)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: body)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
