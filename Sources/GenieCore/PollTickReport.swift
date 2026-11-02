import Foundation

package enum ChatReadKind: Equatable, Sendable {
    case ok
    case partial
    case allRowsFailed
    case failed
    case discardedAfterStop
}

package enum ReplyPollOutcome: Equatable, Sendable {
    case fetched
    case fetchFailed
    case notConfigured
    case skippedUnchecked
    case skippedPaused
    case skippedStopped
}

package enum PollStep: Equatable, Sendable {
    case lock
    case chats(ChatReadKind)
    case holds
    case replies(ReplyPollOutcome)
}

package struct PollTickReport: Equatable, Sendable {
    package var at: Date
    package var steps: [PollStep]
    package var skippedBusy: Bool
    package var stoppedMidway: Bool
}

package enum InitialListResult: Equatable, Sendable {
    case applied
    case stopped
}

package enum ParseProblem: Equatable, Sendable {
    case partial
    case allRows
}

package enum ChatListApplyResult: Equatable, Sendable {
    case applied([ChatSummary])
    case discarded
}
