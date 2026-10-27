import Foundation
import GenieCore

final class GenieController: @unchecked Sendable {
    let engine: GenieEngine
    let logURL: URL
    private let paths: ConfigPaths
    private let config: FileConfigProvider
    private let box = ProcessBox()
    private var supervisor: Task<Void, Never>?
    private var poller: Task<Void, Never>?
    private var stopped = false
    private let stateLock = NSLock()

    init(paths: ConfigPaths) throws {
        let built = try RuntimeBuilder.make(paths: paths)
        engine = built.engine
        logURL = built.logURL
        config = built.config
        self.paths = paths
        if let note = built.note {
            Task { await self.engine.setLastError(note) }
        }
        start()
    }

    func pause() async {
        await engine.setPaused(true)
        box.stopForUser()
    }

    func resume() async {
        await engine.setPaused(false)
    }

    func shutdown() {
        stateLock.lock()
        stopped = true
        stateLock.unlock()
        box.stopForUserAndWait()
        supervisor?.cancel()
        poller?.cancel()
    }

    func loadChats(reportError: Bool) async -> [ChatSummary] {
        let loaded = (try? config.load()) ?? .productDefaults
        let result = await ProcessRunner.run(
            executable: loaded.imsgExecutable,
            arguments: ImsgCommand.chatsArguments(limit: loaded.chatsLimit),
            timeout: loaded.chatsTimeoutSeconds
        )
        if result.exitCode != 0 || result.timedOut {
            await engine.noteChatsProblem(code: "chats_failed", updateMenu: reportError)
            return []
        }
        let parsed = ChatListParser.parse(ndjson: result.stdout)
        if parsed.failedLineCount > 0 {
            await engine.noteChatsProblem(code: "chats_parse_failed", updateMenu: false)
        }
        if parsed.chats.isEmpty && parsed.failedLineCount > 0 {
            return []
        }
        await engine.reconcileChats(parsed.chats)
        return parsed.chats
    }

    private func start() {
        let box = self.box
        let engine = self.engine
        let config = self.config
        supervisor = Task.detached {
            _ = await self.loadChats(reportError: true)
            var delay = 1.0
            while !self.isStopped {
                if await engine.isPaused() {
                    try? await Task.sleep(nanoseconds: 300_000_000)
                    continue
                }
                box.resetStop()
                if self.isStopped { continue }
                if await engine.isPaused() { continue }
                let cursor = await engine.snapshot().cursorRowID
                let loaded = (try? config.load()) ?? .productDefaults
                let started = Date()
                let outcome = await WatchProcess.run(
                    box: box,
                    executable: loaded.imsgExecutable,
                    arguments: ImsgCommand.watchArguments(sinceRowID: cursor)
                ) { chunk in
                    switch chunk {
                    case .line(let line):
                        let result = await engine.ingestWatchLine(line)
                        return WatchSession.shouldStopApplying(result) ? .stop : .next
                    case .tooLarge(let rowID):
                        let result = await engine.noteOversizedWatchLine(rowID: rowID)
                        return WatchSession.shouldStopApplying(result) ? .stop : .next
                    }
                }
                let pausedNow = await engine.isPaused()
                let userStop = box.wasUserStop() || pausedNow
                let quitting = self.isStopped
                await engine.noteWatchEnded(outcome, updateMenu: !userStop && !quitting)
                if userStop || quitting { continue }
                let ran = Date().timeIntervalSince(started)
                if ran > 30 {
                    delay = 1
                }
                let nanos = UInt64(delay * 1_000_000_000)
                try? await Task.sleep(nanoseconds: nanos)
                delay = min(30, max(1, delay * 2))
            }
        }
        poller = Task.detached {
            var lastReply = Date.distantPast
            var lastChats = Date()
            while !self.isStopped {
                let loaded = (try? config.load()) ?? .productDefaults
                await engine.refreshLock()
                await engine.retryHolds()
                if Date().timeIntervalSince(lastReply) >= loaded.replyPollIntervalSeconds {
                    await engine.pollReplies()
                    lastReply = Date()
                }
                if Date().timeIntervalSince(lastChats) >= 30 {
                    _ = await self.loadChats(reportError: false)
                    lastChats = Date()
                }
                try? await Task.sleep(nanoseconds: 2_000_000_000)
            }
        }
        let caffeinate = Process()
        caffeinate.executableURL = URL(fileURLWithPath: "/usr/bin/caffeinate")
        caffeinate.arguments = ["-i", "-s", "-w", String(ProcessInfo.processInfo.processIdentifier)]
        caffeinate.standardOutput = FileHandle.nullDevice
        caffeinate.standardError = FileHandle.nullDevice
        do {
            try caffeinate.run()
        } catch {
            Task { await engine.setLastError("caffeinate_failed") }
        }
    }

    private var isStopped: Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        return stopped
    }
}

enum RuntimeBuilder {
    struct Built {
        var engine: GenieEngine
        var config: FileConfigProvider
        var logURL: URL
        var note: String?
    }

    static func make(paths: ConfigPaths) throws -> Built {
        try ConfigDirectory.prepare(paths)
        let config = FileConfigProvider(url: paths.configFile)
        let loaded = try config.load()
        let logURL: URL
        if let custom = loaded.logFile?.trimmingCharacters(in: .whitespacesAndNewlines), !custom.isEmpty {
            logURL = URL(fileURLWithPath: custom)
        } else {
            logURL = paths.logFile
        }
        let log = FileGenieLog(url: logURL)
        var note: String?
        let engine = try openEngine(paths: paths, config: config, log: log, note: &note)
        return Built(engine: engine, config: config, logURL: logURL, note: note)
    }

    private static func openEngine(
        paths: ConfigPaths,
        config: FileConfigProvider,
        log: FileGenieLog,
        note: inout String?
    ) throws -> GenieEngine {
        do {
            return try build(paths: paths, config: config, log: log)
        } catch is StateError {
            try FileStateStore.quarantine(paths.stateFile)
            note = "state_reset"
            return try openAllowlist(paths: paths, config: config, log: log, note: &note)
        } catch is AllowlistError {
            try FileAllowlistStore.quarantine(paths.allowlistFile)
            note = "allowlist_reset"
            return try build(paths: paths, config: config, log: log)
        }
    }

    private static func openAllowlist(
        paths: ConfigPaths,
        config: FileConfigProvider,
        log: FileGenieLog,
        note: inout String?
    ) throws -> GenieEngine {
        do {
            return try build(paths: paths, config: config, log: log)
        } catch is AllowlistError {
            try FileAllowlistStore.quarantine(paths.allowlistFile)
            note = "allowlist_reset"
            return try build(paths: paths, config: config, log: log)
        }
    }

    private static func build(
        paths: ConfigPaths,
        config: FileConfigProvider,
        log: FileGenieLog
    ) throws -> GenieEngine {
        let loaded = try config.load()
        let secrets = FileSecretProvider(paths: paths)
        let probe = ScreenLockProbe()
        let engine = try GenieEngine(
            configProvider: config,
            initialConfig: loaded,
            stateStore: FileStateStore(paths: paths),
            allowlistStore: FileAllowlistStore(file: paths.allowlistFile),
            replySource: ConfiguredReplySource(config: config, secrets: secrets),
            sender: ImsgMessageSender(config: config),
            webhook: URLSessionWebhook(),
            secrets: secrets,
            lock: probe,
            log: log
        )
        probe.observe { state in
            Task {
                await engine.noteLock(state)
                if state == .unlocked {
                    await engine.retryHolds()
                }
            }
        }
        return engine
    }
}
