import Foundation

/// 定期処理の1周。本番の常駐ループもテストも、ここを通る。
package actor GeniePoller {
    private let engine: GenieEngine
    private let reader: any ChatListReading
    private let configProvider: any ConfigProviding
    private let clock: any GenieClock
    private let stop: StopSignal
    private var schedule: PollSchedule
    private let probe: (any PollerProbe)?
    private var ticking = false
    private var pendingRefresh = false
    private var refreshInFlight = false
    private var latest: [ChatSummary] = []
    private let initial = InitialWait()

    package init(
        engine: GenieEngine,
        reader: any ChatListReading,
        configProvider: any ConfigProviding,
        clock: any GenieClock,
        stop: StopSignal,
        schedule: PollSchedule = .production,
        probe: (any PollerProbe)? = nil
    ) {
        self.engine = engine
        self.reader = reader
        self.configProvider = configProvider
        self.clock = clock
        self.stop = stop
        self.schedule = schedule
        self.probe = probe
        let initial = self.initial
        stop.onStop {
            initial.resolve(.stopped)
        }
    }

    package func tick() async -> PollTickReport {
        let at = clock.now()
        if ticking {
            return PollTickReport(at: at, steps: [], skippedBusy: true, stoppedMidway: false)
        }
        ticking = true
        defer { ticking = false }
        var steps: [PollStep] = []
        if stop.isStopped {
            return PollTickReport(at: at, steps: steps, skippedBusy: false, stoppedMidway: true)
        }
        await engine.refreshLock()
        steps.append(.lock)
        if stop.isStopped {
            return PollTickReport(at: at, steps: steps, skippedBusy: false, stoppedMidway: true)
        }
        let config = loadedConfig()
        if schedule.chatsDue(now: clock.now()) || pendingRefresh {
            pendingRefresh = false
            refreshInFlight = true
            let read = await reader.read()
            if stop.isStopped {
                refreshInFlight = false
                steps.append(.chats(.discardedAfterStop))
                return PollTickReport(at: at, steps: steps, skippedBusy: false, stoppedMidway: true)
            }
            await probe?.chatsReadReturned()
            let applied = await engine.applyChatList(read)
            switch applied {
            case .discarded:
                refreshInFlight = false
                steps.append(.chats(.discardedAfterStop))
                return PollTickReport(at: at, steps: steps, skippedBusy: false, stoppedMidway: true)
            case .applied(let chats):
                latest = chats
                refreshInFlight = false
                schedule.lastChatsAt = clock.now()
                steps.append(.chats(Self.kind(of: read)))
                await probe?.chatsApplied()
                initial.resolve(.applied)
            }
        }
        if stop.isStopped {
            return PollTickReport(at: at, steps: steps, skippedBusy: false, stoppedMidway: true)
        }
        await engine.retryHolds()
        steps.append(.holds)
        if stop.isStopped {
            return PollTickReport(at: at, steps: steps, skippedBusy: false, stoppedMidway: true)
        }
        let repliesDue = schedule.repliesDue(now: clock.now(), interval: config.replyPollIntervalSeconds)
        let repliesWanted = await engine.isReplyPollWanted()
        if repliesDue || repliesWanted {
            let outcome = await engine.pollReplies()
            steps.append(.replies(outcome))
            switch outcome {
            case .fetched, .fetchFailed, .notConfigured:
                schedule.lastRepliesAt = clock.now()
            case .skippedUnchecked, .skippedPaused, .skippedStopped:
                break
            }
        }
        return PollTickReport(at: at, steps: steps, skippedBusy: false, stoppedMidway: false)
    }

    package func run() async {
        if stop.isStopped || Task.isCancelled {
            initial.resolve(.stopped)
            return
        }
        while !stop.isStopped && !Task.isCancelled {
            _ = await tick()
            if stop.isStopped || Task.isCancelled { break }
            do {
                try await clock.sleep(seconds: schedule.tickSeconds)
            } catch {
                break
            }
            if stop.isStopped || Task.isCancelled { break }
        }
        initial.resolve(.stopped)
    }

    package func requestChatsRefresh() {
        if refreshInFlight { return }
        pendingRefresh = true
    }

    package func latestChats() -> [ChatSummary] { latest }

    package func waitForInitialChatList() async -> InitialListResult {
        await probe?.initialWaitRegistered()
        return await initial.wait()
    }

    package func initialListResolved() -> Bool { initial.isResolved }

    package func currentSchedule() -> PollSchedule { schedule }

    private func loadedConfig() -> GenieConfig {
        let loaded = (try? configProvider.load()) ?? .productDefaults
        return loaded.sanitized()
    }

    private static func kind(of read: ChatListRead) -> ChatReadKind {
        switch read {
        case .failed:
            return .failed
        case .parsed(let parsed):
            if parsed.failedLineCount > 0 && parsed.chats.isEmpty { return .allRowsFailed }
            if parsed.failedLineCount > 0 { return .partial }
            return .ok
        }
    }
}

/// 初回の待ち。先に決まった結果が勝つ。停止の知らせから同期で解ける。
final class InitialWait: @unchecked Sendable {
    private let lock = NSLock()
    private var result: InitialListResult?
    private var waiters: [CheckedContinuation<InitialListResult, Never>] = []

    var isResolved: Bool {
        lock.lock()
        defer { lock.unlock() }
        return result != nil
    }

    func resolve(_ value: InitialListResult) {
        let pending: [CheckedContinuation<InitialListResult, Never>]
        lock.lock()
        if result != nil {
            lock.unlock()
            return
        }
        result = value
        pending = waiters
        waiters = []
        lock.unlock()
        for waiter in pending {
            waiter.resume(returning: value)
        }
    }

    func wait() async -> InitialListResult {
        lock.lock()
        if let result {
            lock.unlock()
            return result
        }
        return await withCheckedContinuation { continuation in
            waiters.append(continuation)
            lock.unlock()
        }
    }
}
