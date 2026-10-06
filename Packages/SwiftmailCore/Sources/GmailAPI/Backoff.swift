import Foundation

/// Truncated exponential backoff: 2^n seconds plus up to 1 second of jitter, capped at
/// 64 seconds, honoring `Retry-After` when present.
public enum Backoff {
    public static let maxAttempts = 5

    public static func delay(attempt: Int, retryAfter: TimeInterval? = nil, jitter: Double = Double.random(in: 0 ... 1)) -> Duration {
        if let retryAfter, retryAfter > 0 {
            return .milliseconds(Int(min(retryAfter, 64) * 1000))
        }
        let base = pow(2, Double(min(attempt, 6)))
        let seconds = min(base + jitter, 64)
        return .milliseconds(Int(seconds * 1000))
    }

    static func retryAfter(from response: HTTPURLResponse) -> TimeInterval? {
        guard let value = response.value(forHTTPHeaderField: "Retry-After") else { return nil }
        if let seconds = TimeInterval(value) {
            return seconds
        }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
        return formatter.date(from: value).map { max(0, $0.timeIntervalSinceNow) }
    }
}
