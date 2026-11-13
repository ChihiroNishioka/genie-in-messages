import Foundation

enum HoldReason: String, Codable {
    case screenLocked = "screen_locked"
    case appleEventNotStarted = "apple_event_1712"
    case rateLimited = "rate_limited"
}

struct HeldSend: Equatable {
    var replyID: String
    var chatID: Int64
    var part: SendPart
    var body: String
    var reason: HoldReason
    var attempts: Int
    var nextAttemptAt: Date
    var createdAt: Date
    var originGUID: String
}

package protocol MessageSending: Sendable {
    func send(chatID: Int64, text: String) async throws -> SendReceipt
}

package enum ScreenLockState: String, Equatable, Sendable {
    case locked
    case unlocked
    case unknown
}

package protocol ScreenLockChecking: Sendable {
    func state() async -> ScreenLockState
}

struct UnlockedScreen: ScreenLockChecking {
    func state() async -> ScreenLockState { .unlocked }
}

/// ポーラーが1回で見る、トーク一覧の読み方。
package enum ChatListRead: Equatable {
    case failed
    case parsed(ChatListParse)
}

package enum JobRouteState: Equatable {
    case ordinary
    case fallback
    case invalid
    case job

    package init(config: GenieConfig) {
        if config.jobChatIDs.isEmpty {
            self = .ordinary
        } else if config.jobWebhookURL.isEmpty {
            self = .fallback
        } else if EndpointURL.httpsOrLoopback(config.jobWebhookURL) == nil {
            self = .invalid
        } else {
            self = .job
        }
    }

    package var menuLine: String? {
        switch self {
        case .fallback:
            return "Job Engine の URL が空なので通常の webhook に送ります"
        case .invalid:
            return "Job Engine の URL が使えない形なので送りません"
        case .ordinary, .job:
            return nil
        }
    }
}

package struct EngineSnapshot: Equatable {
    package var paused: Bool
    package var cursorRowID: Int64
    package var enabledChatIDs: [Int64]
    package var haltedChatIDs: [Int64]
    package var heldCount: Int
    package var heldLockCount: Int
    package var lastError: String?
    package var replyFetchError: String? = nil
    /// 照合できずに送らなかった理由。最後のエラーとは別。
    package var holdNotice: String?
    package var screenLocked: Bool
    package var screenLock: ScreenLockState
    package var replyFetchConfigured: Bool
    package var jobWebhookConfigured: Bool = false
    package var jobRouteState: JobRouteState = .ordinary
    package var webhookConfigured: Bool
    package var configChatIDs: [Int64] = []
    package var configGroupUnresolved: Int = 0
}

package enum IngestResult: Equatable {
    case skipped
    case delivered
    case deadLettered(String)
    case duplicate
    case ignoredNotFromMe
    case ignoredNotAllowed
    case ignoredNoSignal
    case ignoredReplyMarker
    case ignoredMutation
    case ignoredSentGUID
    case ignoredFingerprint
    case ignoredReaction
    case deferredPaused
    case notJSON
    /// この watch プロセスの続きは適用しない。カーソルは進めていない。
    case blocked
    case ignoredDatabaseReset
}
