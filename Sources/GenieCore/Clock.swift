import Foundation

package protocol GenieClock: Sendable {
    func now() -> Date
    func sleep(seconds: Double) async throws
}

package struct SystemClock: GenieClock {
    package init() {}
    package func now() -> Date { Date() }
    package func sleep(seconds: Double) async throws {
        let nanos = UInt64(max(0, seconds) * 1_000_000_000)
        try await Task.sleep(nanoseconds: nanos)
    }
}

enum ISO8601 {
    static func string(from date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: date)
    }

    static func date(from string: String?) -> Date? {
        guard let string, !string.isEmpty else { return nil }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: string) {
            return date
        }
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: string)
    }
}
