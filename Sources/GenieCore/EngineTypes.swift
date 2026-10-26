import Foundation

enum HoldReason: String, Codable {
    case screenLocked = "screen_locked"
    case appleEventNotStarted = "apple_event_1712"
    case rateLimited = "rate_limited"
}

struct HeldSend: Equatable {
    var replyID: String
    var chatID: Int64
    var text: String
    var reason: HoldReason
    var attempts: Int
    var nextAttemptAt: Date
}

package protocol MessageSending: Sendable {
    func send(chatID: Int64, text: String) async throws -> SendReceipt
}

package protocol ScreenLockChecking: Sendable {
    func isLocked() async -> Bool
}

struct UnlockedScreen: ScreenLockChecking {
    func isLocked() async -> Bool { false }
}

package struct EngineSnapshot: Equatable {
    package var paused: Bool
    package var cursorRowID: Int64
    package var enabledChatIDs: [Int64]
    package var haltedChatIDs: [Int64]
    package var heldCount: Int
    package var heldLockCount: Int
    package var lastError: String?
    package var screenLocked: Bool
    package var replyFetchConfigured: Bool
    package var webhookConfigured: Bool
}

package enum IngestResult: Equatable {
    case skipped
    case delivered
    case deadLettered(String)
    case duplicate
    case ignoredNotFromMe
    case ignoredNotAllowed
    case ignoredNoSignal
    case ignoredMutation
    case ignoredSentGUID
    case ignoredFingerprint
    case ignoredReaction
    case deferredPaused
    case notJSON
}
