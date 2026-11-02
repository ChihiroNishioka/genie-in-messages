import Foundation
import GenieCore

final class GenieController: @unchecked Sendable {
    let engine: GenieEngine
    let logURL: URL
    private let paths: ConfigPaths
    private let config: FileConfigProvider
    private let box = ProcessBox()
    private let stop: StopSignal
    private let chatPoller: GeniePoller
    private var supervisor: Task<Void, Never>?
    private var poller: Task<Void, Never>?

    init(paths: ConfigPaths) throws {
        let built = try RuntimeBuilder.make(paths: paths)
        engine = built.engine
        logURL = built.logURL
        config = built.config
        stop = built.stop
        self.paths = paths
        chatPoller = GeniePoller(
            engine: built.engine,
            reader: ImsgChatListReader(config: built.config),
            configProvider: built.config,
            clock: SystemClock(),
            stop: built.stop
        )
        if let note = built.note {
            Task { await self.engine.setLastError(note) }
        }
        start()
    }

    func requestChatsRefresh() {
        Task { await chatPoller.requestChatsRefresh() }
    }

    func latestChats() async -> [ChatSummary] {
        await chatPoller.latestChats()
    }

    func pause() async {
        await engine.setPaused(true)
        box.stopForUser()
    }

    func resume() async {
        await engine.setPaused(false)
    }

    func shutdown() {
        stop.stop()
        box.stopForUserAndWait()
        supervisor?.cancel()
        poller?.cancel()
    }

    private func start() {
        let box = self.box
        let engine = self.engine
        let config = self.config
        let stop = self.stop
        let launched = GenieRuntimeLauncher.launch(poller: chatPoller, stop: stop) {
            var delay = 1.0
            while !stop.isStopped {
                if await engine.isPaused() {
                    try? await Task.sleep(nanoseconds: 300_000_000)
                    continue
                }
                box.resetStop()
                if stop.isStopped { continue }
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
                let quitting = stop.isStopped
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
        poller = launched.poller
        supervisor = launched.supervisor
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

}

enum RuntimeBuilder {
    struct Built {
        var engine: GenieEngine
        var config: FileConfigProvider
        var logURL: URL
        var note: String?
        var stop: StopSignal
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
        let stop = StopSignal()
        let engine = try openEngine(paths: paths, config: config, log: log, stop: stop, note: &note)
        return Built(engine: engine, config: config, logURL: logURL, note: note, stop: stop)
    }

    private static func openEngine(
        paths: ConfigPaths,
        config: FileConfigProvider,
        log: FileGenieLog,
        stop: StopSignal,
        note: inout String?
    ) throws -> GenieEngine {
        do {
            return try build(paths: paths, config: config, log: log, stop: stop)
        } catch is StateError {
            try FileStateStore.quarantine(paths.stateFile)
            note = "state_reset"
            return try openAllowlist(paths: paths, config: config, log: log, stop: stop, note: &note)
        } catch is AllowlistError {
            try FileAllowlistStore.quarantine(paths.allowlistFile)
            note = "allowlist_reset"
            return try build(paths: paths, config: config, log: log, stop: stop)
        }
    }

    private static func openAllowlist(
        paths: ConfigPaths,
        config: FileConfigProvider,
        log: FileGenieLog,
        stop: StopSignal,
        note: inout String?
    ) throws -> GenieEngine {
        do {
            return try build(paths: paths, config: config, log: log, stop: stop)
        } catch is AllowlistError {
            try FileAllowlistStore.quarantine(paths.allowlistFile)
            note = "allowlist_reset"
            return try build(paths: paths, config: config, log: log, stop: stop)
        }
    }

    private static func build(
        paths: ConfigPaths,
        config: FileConfigProvider,
        log: FileGenieLog,
        stop: StopSignal
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
            log: log,
            stop: stop
        )
        probe.observe { state in
            Task { await engine.noteLock(state) }
        }
        return engine
    }
}
