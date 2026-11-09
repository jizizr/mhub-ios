import Foundation

/// How long one request may wait out the server's per-client quota (HTTP 429)
/// before the error reaches the caller. Mirrors the web client's `rateLimit`
/// option; limits and cases are in `contract/rate-limit-cases.json`.
public struct RateLimitPolicy: Sendable {
    /// Total time spent waiting across retries; 0 never waits.
    public var maxWaitMs: Int
    /// Runs before each wait with the wait in ms, e.g. to tell the listener.
    public var onWait: (@Sendable (Int) -> Void)?

    public init(maxWaitMs: Int, onWait: (@Sendable (Int) -> Void)? = nil) {
        self.maxWaitMs = maxWaitMs
        self.onWait = onWait
    }

    /// Ordinary requests: short, so an interactive action still answers.
    public static let standard = RateLimitPolicy(maxWaitMs: 10_000)
    /// Next-song prefetch gives up at once; the player retries it later.
    public static let prefetch = RateLimitPolicy(maxWaitMs: 0)

    /// A song the listener asked for waits up to two minutes.
    public static func playback(onWait: (@Sendable (Int) -> Void)? = nil) -> RateLimitPolicy {
        RateLimitPolicy(maxWaitMs: 120_000, onWait: onWait)
    }

    /// Importing a playlist is background work and waits up to five minutes.
    public static func importing(onWait: (@Sendable (Int) -> Void)? = nil) -> RateLimitPolicy {
        RateLimitPolicy(maxWaitMs: 300_000, onWait: onWait)
    }
}

public enum RateLimit {
    static let minRetryMs = 1000
    /// Prefetch retry backoff; a 429 never retries sooner than its Retry-After.
    static let prefetchBackoffMs = [5000, 15000, 30000]

    /// `Retry-After` as milliseconds: delta-seconds or an HTTP date, at least a second.
    public static func retryAfterMs(_ header: String?, now: Date = .now) -> Int {
        let text = (header ?? "").trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty else { return minRetryMs }
        if text.allSatisfy(\.isASCII), text.allSatisfy(\.isNumber), let seconds = Int(text) {
            return max(minRetryMs, seconds * 1000)
        }
        guard let date = httpDate.date(from: text) else { return minRetryMs }
        return max(minRetryMs, Int((date.timeIntervalSince(now) * 1000).rounded()))
    }

    /// Whole seconds to show the listener for a wait (rounded up).
    public static func seconds(_ ms: Int) -> Int { (ms + 999) / 1000 }

    /// Delay before the next prefetch attempt after `attempt` failures.
    public static func prefetchDelayMs(attempt: Int, retryAfterMs: Int) -> Int {
        max(prefetchBackoffMs[min(max(attempt, 0), prefetchBackoffMs.count - 1)], retryAfterMs)
    }

    /// Runs `request`, waiting out 429 answers within `policy`. The wait is
    /// cancellable: cancelling the task throws `CancellationError`.
    public static func run<T: Sendable>(
        _ policy: RateLimitPolicy,
        sleep: @Sendable (Int) async throws -> Void = { try await Task.sleep(for: .milliseconds($0)) },
        _ request: () async throws -> T
    ) async throws -> T {
        var waited = 0
        while true {
            do {
                return try await request()
            } catch let APIError.rateLimited(retryAfterMs, detail) {
                guard waited + retryAfterMs <= policy.maxWaitMs else {
                    throw APIError.rateLimited(retryAfterMs: retryAfterMs, detail: detail)
                }
                policy.onWait?(retryAfterMs)
                try await sleep(retryAfterMs)
                waited += retryAfterMs
            }
        }
    }

    private static let httpDate: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "GMT")
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
        return formatter
    }()
}
