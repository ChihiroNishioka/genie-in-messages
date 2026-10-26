import Foundation
import GenieCore

final class ProcessBox: @unchecked Sendable {
    private let lock = NSLock()
    private var process: Process?
    private var stopRequested = false

    func begin(_ process: Process) {
        lock.lock()
        self.process = process
        let stop = stopRequested
        lock.unlock()
        if stop {
            process.terminate()
        }
    }

    func terminate() {
        lock.lock()
        stopRequested = true
        let process = self.process
        lock.unlock()
        process?.terminate()
    }

    func resetStop() {
        lock.lock()
        stopRequested = false
        process = nil
        lock.unlock()
    }
}

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
        box.terminate()
    }

    func resume() async {
        await engine.setPaused(false)
    }

    func loadChats(reportError: Bool) async -> [ChatSummary] {
        let loaded = (try? config.load()) ?? .productDefaults
        let result = await ProcessRunner.run(
            executable: loaded.imsgExecutable,
            arguments: ImsgCommand.chatsArguments(limit: loaded.chatsLimit)
        )
        if result.exitCode != 0 {
            if reportError {
                await engine.setLastError("chats_failed")
            }
            return []
        }
        return ChatListParser.parse(ndjson: result.stdout)
    }

    private func start() {
        let box = self.box
        let engine = self.engine
        let config = self.config
        supervisor = Task.detached {
            var delay = 1.0
            while !self.isStopped {
                if await engine.isPaused() {
                    try? await Task.sleep(nanoseconds: 300_000_000)
                    continue
                }
                box.resetStop()
                if await engine.isPaused() { continue }
                let cursor = await engine.snapshot().cursorRowID
                let loaded = (try? config.load()) ?? .productDefaults
                let started = Date()
                let code = await WatchProcess.run(
                    box: box,
                    executable: loaded.imsgExecutable,
                    arguments: ImsgCommand.watchArguments(sinceRowID: cursor)
                ) { line in
                    _ = await engine.ingestWatchLine(line)
                }
                if await engine.isPaused() || self.isStopped { continue }
                let ran = Date().timeIntervalSince(started)
                if code == -1 {
                    await engine.setLastError("watch_start_failed")
                } else {
                    await engine.setLastError("watch_exited")
                }
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
            while !self.isStopped {
                let loaded = (try? config.load()) ?? .productDefaults
                await engine.refreshLock()
                await engine.retryHolds()
                if Date().timeIntervalSince(lastReply) >= loaded.replyPollIntervalSeconds {
                    await engine.pollReplies()
                    lastReply = Date()
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
        return try GenieEngine(
            configProvider: config,
            initialConfig: loaded,
            stateStore: FileStateStore(paths: paths),
            allowlistStore: FileAllowlistStore(file: paths.allowlistFile),
            replySource: ConfiguredReplySource(config: config, secrets: secrets),
            sender: ImsgMessageSender(config: config),
            webhook: URLSessionWebhook(),
            secrets: secrets,
            lock: ScreenLockProbe(),
            log: log
        )
    }
}
