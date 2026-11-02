import Foundation

package struct PollSchedule: Sendable, Equatable {
    package var tickSeconds: Double
    package var chatsSeconds: Double
    package var lastChatsAt: Date?
    package var lastRepliesAt: Date?

    package static let production = PollSchedule(
        tickSeconds: 2,
        chatsSeconds: 30,
        lastChatsAt: nil,
        lastRepliesAt: nil
    )

    package func chatsDue(now: Date) -> Bool {
        guard let lastChatsAt else { return true }
        return now.timeIntervalSince(lastChatsAt) >= chatsSeconds
    }

    package func repliesDue(now: Date, interval: Double) -> Bool {
        guard let lastRepliesAt else { return true }
        return now.timeIntervalSince(lastRepliesAt) >= interval
    }
}
