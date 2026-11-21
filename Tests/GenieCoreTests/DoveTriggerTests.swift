import Foundation
import XCTest
@testable import GenieCore

final class DoveFixture {
    static let group = "iMessage;+;chat000000000000000001"
    static let other = "iMessage;+;chat000000000000000002"
    let h = Harness()
    let outbound = ScriptedOutbound()
    let paths: ConfigPaths
    let provider: FileConfigProvider
    var settings: [String: Any] = [
        "group_chat_guids": [group, other],
        "dove_chat_guids": [group],
        "webhook_url": "https://example.com/webhook",
        "reply_fetch_url": "https://example.com/replies",
    ]
    var chats: [ChatSummary] = [
        .init(id: 7, title: "family", isGroup: true, guid: group),
        .init(id: 8, title: "group", isGroup: true, guid: other),
        .init(id: 42, title: "room", isGroup: true, guid: "iMessage;+;chat000000000000000003"),
    ]

    init() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        paths = ConfigPaths(root: dir, logFile: dir.appendingPathComponent("test.log"))
        provider = FileConfigProvider(url: paths.configFile)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        h.allow.ids = [42]
        h.allow.guids = [42: chats[2].guid]
        h.secrets = StaticSecret(webhook: "sample-hook", reply: nil, job: "sample-job")
    }

    deinit { try? FileManager.default.removeItem(at: paths.root) }

    func write() throws {
        try JSONSerialization.data(withJSONObject: settings).write(to: paths.configFile, options: .atomic)
    }

    func engine() throws -> GenieEngine {
        try write()
        return try GenieEngine(configProvider: provider, initialConfig: provider.load(),
            stateStore: h.store ?? h.state, allowlistStore: h.allow, replySource: h.replies,
            outboundSource: outbound, sender: h.sender, markerImage: h.markerImage, webhook: h.webhook,
            secrets: h.secrets, lock: h.lock, clock: h.clock, log: h.log, stop: h.stop)
    }

    func poller(_ engine: GenieEngine, reads: [ChatListRead]? = nil) -> GeniePoller {
        let reader = ScriptedChatLists(script: reads ?? Array(repeating: .parsed(.init(chats: chats, failedLineCount: 0)), count: 8))
        return GeniePoller(engine: engine, reader: reader, configProvider: provider, clock: h.clock, stop: h.stop)
    }

    func ingest(_ e: GenieEngine, _ text: String, id: Int = 1, chat: Int = 7, fromMe: Bool = true,
                guid: String? = nil, type: String? = nil, reaction: Bool = false) async -> IngestResult {
        await e.ingestWatchLine(watchLine(id: id, guid: guid ?? "incoming-\(id)", chat: chat,
            fromMe: fromMe, text: text, created: ISO8601.string(from: h.clock.now()), type: type,
            reaction: reaction, chatGUID: chats.first { $0.id == chat }?.guid, sender: "family@example.com", isGroup: true))
    }

    func payload(_ index: Int = 0, file: StaticString = #filePath, line: UInt = #line) throws -> [String: Any] {
        guard h.webhook.bodies.indices.contains(index) else {
            XCTFail("Missing POST", file: file, line: line)
            return [:]
        }
        return try JSONSerialization.jsonObject(with: h.webhook.bodies[index]) as? [String: Any] ?? [:]
    }

    func reply(_ text: String = "answer", chat: Int64? = 7, id: Int = 1) {
        h.replies.pages = [.init(replies: [.init(id: "reply-\(id)", chatID: chat, text: text,
            inReplyToGUID: "incoming-\(id)", createdAt: ISO8601.string(from: h.clock.now()))], nextCursor: nil)]
    }

    func advance() { h.clock.current = h.clock.now().addingTimeInterval(20) }
}

final class DoveTriggerTests: XCTestCase {
    func testDV21DatabaseSwapDiscardsFinalWebhookException() async throws {
        let f = try DoveFixture()
        f.settings["webhook_max_attempts"] = 2
        let e = try f.engine()
        _ = await f.poller(e).tick()
        let differentChat = ChatSummary(id: 7, title: "new room", isGroup: true,
                                        guid: "iMessage;+;chat000000000000000004")
        let calls = EventLog()
        f.h.webhook.results = [.success(.init(statusCode: 503)), .failure(URLError(.timedOut))]
        f.h.webhook.onPost = {
            calls.append("post")
            if calls.snapshot().count == 2 {
                _ = await e.applyChatList(.parsed(.init(chats: [differentChat], failedLineCount: 0)))
            }
        }
        defer { f.h.webhook.onPost = nil }

        let result = await f.ingest(e, "🐦 request", id: 90)

        XCTAssertEqual(f.h.webhook.bodies.count, 2)
        XCTAssertTrue(f.h.log.records.contains { $0.code == "messages_db_reset" })
        XCTAssertEqual(result, .ignoredDatabaseReset)
        XCTAssertEqual(f.h.state.state.cursorRowID, 0)
        XCTAssertTrue(f.h.state.deadLetters.isEmpty)
        XCTAssertFalse(f.h.state.state.seenGUIDs.contains("incoming-90"))
    }

    func testDV01ConfigDefaultsAndInvalidReload() async throws {
        let f = try DoveFixture()
        f.settings.removeValue(forKey: "dove_chat_guids")
        let e = try f.engine()
        _ = await f.poller(e).tick()
        let off = await f.ingest(e, "🐦 x")
        XCTAssertEqual(off, .ignoredNoSignal)
        f.settings["dove_chat_guids"] = [" \(DoveFixture.group) ", "", DoveFixture.group]
        try f.write()
        let on = await f.ingest(e, "🐦 x", id: 2)
        XCTAssertEqual(on, .delivered)
        f.settings["dove_chat_guids"] = [7]
        try f.write()
        let retained = await f.ingest(e, "🐦 x", id: 3)
        XCTAssertEqual(retained, .delivered)
        XCTAssertTrue(f.h.log.records.contains { $0.code == "config_unreadable" })
        f.settings["dove_chat_guids"] = NSNull()
        try f.write()
        let reset = await f.ingest(e, "🐦 x", id: 4)
        XCTAssertEqual(reset, .ignoredNoSignal)
    }

    func testDV02EmptyDoveConfigLeavesLampEnabled() async throws {
        let f = try DoveFixture()
        f.settings["dove_chat_guids"] = [String]()
        let e = try f.engine()
        _ = await f.poller(e).tick()

        let dove = await f.ingest(e, "🐦 request", fromMe: false)
        XCTAssertEqual(dove, .ignoredNoSignal)
        XCTAssertTrue(f.h.webhook.bodies.isEmpty)

        let lamp = await f.ingest(e, "🪔 request", id: 2, fromMe: false)
        XCTAssertEqual(lamp, .delivered)
        XCTAssertEqual(f.h.webhook.bodies.count, 1)
        XCTAssertEqual(try f.payload()["trigger"] as? String, "lamp")
    }

    func testDV03DoveNeedsGroupConfig() async throws {
        let f = try DoveFixture()
        f.settings["group_chat_guids"] = []
        f.h.allow.ids = [7]
        f.h.allow.guids = [7: DoveFixture.group]
        let e = try f.engine()
        _ = await f.poller(e).tick()
        for id in 1...2 { _ = await f.ingest(e, "🐦 x", id: id) }
        XCTAssertEqual(f.h.webhook.bodies.count, 0)
        XCTAssertEqual(f.h.log.records.filter { $0.code == "dove_chat_not_in_groups" }.compactMap(\.detail), ["1"])
        f.settings["group_chat_guids"] = [DoveFixture.group]
        try f.write()
        let allowed = await f.ingest(e, "🐦 x", id: 3)
        XCTAssertEqual(allowed, .delivered)
        f.settings["group_chat_guids"] = []
        try f.write()
        _ = await f.ingest(e, "🐦 x", id: 4)
        XCTAssertEqual(f.h.log.records.filter { $0.code == "dove_chat_not_in_groups" }.count, 2)
    }

    func testDV04DoveOnlyInDoveChats() async throws {
        let f = try DoveFixture()
        let direct = "iMessage;-;direct@example.com"
        f.chats.append(.init(id: 9, title: "direct", isGroup: false, guid: direct))
        f.h.allow.ids.insert(9)
        f.h.allow.guids[9] = direct
        f.settings["group_chat_guids"] = [DoveFixture.group, DoveFixture.other, direct]
        f.settings["dove_chat_guids"] = [DoveFixture.group, direct]
        let e = try f.engine()
        let early = await f.ingest(e, "🐦 x")
        XCTAssertEqual(early, .ignoredNoSignal)
        _ = await f.poller(e).tick()
        for chat in [8, 42, 9] {
            let result = await f.ingest(e, "🐦 x", id: chat, chat: chat)
            XCTAssertEqual(result, .ignoredNoSignal)
        }
        XCTAssertEqual(f.h.webhook.bodies.count, 0)
        let result = await f.ingest(e, "🐦 x", id: 43)
        XCTAssertEqual(result, .delivered)
        XCTAssertEqual(f.h.webhook.bodies.count, 1)
    }

    func testDV05OnlyLeadingDoveTriggers() async throws {
        let f = try DoveFixture()
        let e = try f.engine()
        _ = await f.poller(e).tick()
        for (i, text) in ["おはよう🐦", "今日は 🐦 だ", "🐦‍🔥 x", "🐦‍⬛ x"].enumerated() {
            let result = await f.ingest(e, text, id: i + 1)
            XCTAssertEqual(result, .ignoredNoSignal)
        }
        XCTAssertEqual(f.h.webhook.bodies.count, 0)
        let result = await f.ingest(e, " \u{200B}🐦質問", id: 5)
        XCTAssertEqual(result, .delivered)
        XCTAssertEqual(f.h.webhook.bodies.count, 1)
    }

    func testDV05DoveHonorsMutationReactionAndForcedSelf() async throws {
        let f = try DoveFixture()
        f.settings["self_chat_ids"] = [7]
        let e = try f.engine()
        _ = await f.poller(e).tick()
        let edit = await f.ingest(e, "🐦 x", type: "edited")
        let unsent = await f.ingest(e, "🐦 x", id: 2, type: "unsent")
        let reaction = await f.ingest(e, "🐦 x", id: 3, reaction: true)
        let echo = await f.ingest(e, "🐦 x", id: 4, fromMe: false)
        XCTAssertEqual([edit, unsent, reaction, echo], [.ignoredMutation, .ignoredMutation, .ignoredReaction, .ignoredNotFromMe])
        XCTAssertTrue(f.h.webhook.bodies.isEmpty)
        let owner = await f.ingest(e, "🐦 x", id: 5)
        XCTAssertEqual(owner, .delivered)
    }

    func testDV06RequestTextStripsVariationSelectorAndSpaces() async throws {
        let f = try DoveFixture()
        let e = try f.engine()
        _ = await f.poller(e).tick()
        let text = "🐦\u{FE0F}\u{3000} て\u{3099}す\n続き"
        _ = await f.ingest(e, text)
        let data = try f.payload()
        XCTAssertEqual((data["request_text"] as? String)?.unicodeScalars.map(\.value), "です\n続き".unicodeScalars.map(\.value))
        XCTAssertEqual((data["text"] as? String)?.unicodeScalars.map(\.value), text.precomposedStringWithCanonicalMapping.unicodeScalars.map(\.value))
    }

    func testDV07DovePayloadExactKeys() async throws {
        let f = try DoveFixture()
        let e = try f.engine()
        _ = await f.poller(e).tick()
        let family = await f.ingest(e, "🐦🪔 x", fromMe: false)
        let owner = await f.ingest(e, "🐦 x", id: 2)
        XCTAssertEqual(family, .delivered)
        XCTAssertEqual(owner, .delivered)
        let base = Set(["v", "event", "idempotency_key", "guid", "chat_id", "text", "created_at", "sender_is_me", "sender_name", "trigger", "request_text"])
        let data = try f.payload()
        XCTAssertEqual(Set(data.keys), base.union(["sender_handle"]))
        XCTAssertEqual(data["trigger"] as? String, "dove")
        XCTAssertEqual(data["request_text"] as? String, "🪔 x")
        XCTAssertEqual(data["idempotency_key"] as? String, "incoming-1")
        XCTAssertEqual(data["guid"] as? String, "incoming-1")
        XCTAssertEqual(data["chat_id"] as? Int, 7)
        XCTAssertEqual(data["sender_handle"] as? String, "email:family@example.com")
        XCTAssertEqual(Set(try f.payload(1).keys), base)
    }

    func testDV08LampPayloadOnlyAddsTriggerOnOrdinaryRoute() async throws {
        let f = try DoveFixture()
        f.settings["job_chat_ids"] = [8]
        f.settings["job_webhook_url"] = "https://example.com/job"
        let e = try f.engine()
        _ = await f.poller(e).tick()
        _ = await f.ingest(e, "🪔🐦 x")
        _ = await f.ingest(e, "🪔 x", id: 2, chat: 8)
        let base = Set(["v", "event", "idempotency_key", "guid", "chat_id", "text", "created_at", "sender_is_me", "sender_name"])
        let ordinary = try f.payload()
        XCTAssertEqual(Set(ordinary.keys), base.union(["trigger"]))
        XCTAssertEqual(ordinary["trigger"] as? String, "lamp")
        XCTAssertEqual(Set(try f.payload(1).keys), base)
    }

    func testDV09DoveIgnoresJobRoute() async throws {
        let f = try DoveFixture()
        f.settings["job_chat_ids"] = [7]
        f.settings["job_webhook_url"] = "https://example.com/job"
        let e = try f.engine()
        _ = await f.poller(e).tick()
        _ = await f.ingest(e, "🐦 x")
        _ = await f.ingest(e, "🪔 x", id: 2)
        XCTAssertEqual(f.h.webhook.urls.map(\.absoluteString), ["https://example.com/webhook", "https://example.com/job"])
        XCTAssertEqual(f.h.webhook.secrets, ["sample-hook", "sample-job"])
        f.settings["webhook_url"] = ""
        try f.write()
        let missing = await f.ingest(e, "🐦 x", id: 3)
        XCTAssertEqual(missing, .deadLettered("webhook_not_configured"))
        XCTAssertEqual(f.h.state.deadLetters.last?.kind, "webhook")
        XCTAssertEqual(f.h.webhook.urls.count, 2)
    }

    func testDV15EmptyDoveEchoNeverPosts() async throws {
        let f = try DoveFixture()
        let e = try f.engine()
        _ = await f.poller(e).tick()
        f.h.clock.current = f.h.clock.now().addingTimeInterval(300)
        for (id, text) in ["🐦", "🐦\u{FE0F}", "🐦 \u{200B}"].enumerated() {
            let result = await f.ingest(e, text, id: id + 1, fromMe: id.isMultiple(of: 2))
            XCTAssertEqual(String(describing: result), "ignoredEmptyDove")
        }
        XCTAssertEqual(f.h.webhook.bodies.count, 0)
        let missing = await f.ingest(e, "🐦 x", id: 4, guid: "")
        XCTAssertEqual(String(describing: missing), "ignoredMissingDoveGUID")
        XCTAssertEqual(f.h.webhook.bodies.count, 0)
        let valid = await f.ingest(e, "🐦 x", id: 5)
        XCTAssertEqual(valid, .delivered)
    }

    func testDV21PausedAndRetryRecheck() async throws {
        let f = try DoveFixture()
        let e = try f.engine()
        _ = await f.poller(e).tick()
        let cursor = f.h.state.state.cursorRowID
        await e.setPaused(true)
        let paused = await f.ingest(e, "🐦 x")
        XCTAssertEqual(paused, .deferredPaused)
        XCTAssertEqual(f.h.state.state.cursorRowID, cursor)
        await e.setPaused(false)
        f.h.webhook.results = [.success(.init(statusCode: 503))]
        let disabled = try JSONSerialization.data(withJSONObject: f.settings.merging(["dove_chat_guids": []]) { _, new in new })
        let file = f.paths.configFile
        f.h.clock.onSleep = { try? disabled.write(to: file, options: .atomic) }
        let result = await f.ingest(e, "🐦 x")
        XCTAssertEqual(result, .ignoredNotAllowed)
        XCTAssertEqual(f.h.webhook.bodies.count, 1)
        XCTAssertTrue(f.h.log.records.contains { $0.code == "webhook_chat_disabled" && $0.detail == "dove" })
    }

    func testDV21RetryAfter503ReusesWebhookKeys() async throws {
        let f = try DoveFixture()
        let e = try f.engine()
        _ = await f.poller(e).tick()
        f.h.webhook.results = [.success(.init(statusCode: 503)), .success(.init(statusCode: 200))]

        let result = await f.ingest(e, "🐦 request")
        XCTAssertEqual(result, .delivered)
        XCTAssertEqual(f.h.clock.slept.count, 1)
        XCTAssertEqual(f.h.webhook.idempotencyKeys, ["incoming-1", "incoming-1"])
        XCTAssertEqual(try f.payload(0)["idempotency_key"] as? String, "incoming-1")
        XCTAssertEqual(try f.payload(1)["idempotency_key"] as? String, "incoming-1")
    }

    func testDV21RestartBeforeFinishSaveReusesWebhookKeys() async throws {
        let f = try DoveFixture()
        let fileStore = FileStateStore(paths: f.paths)
        let store = FailNextSaveStateStore(store: fileStore)
        f.h.store = store
        let a = try f.engine()
        _ = await f.poller(a).tick()
        f.h.webhook.onPost = { store.failNextSave = true }

        let first = await f.ingest(a, "🐦 request")
        XCTAssertEqual(first, .delivered)
        XCTAssertTrue(f.h.log.records.contains { $0.code == "state_save_failed" })
        let saved = try fileStore.load()
        XCTAssertEqual(saved.cursorRowID, 0)
        XCTAssertTrue(saved.seenGUIDs.isEmpty)
        XCTAssertEqual(saved.routes.map(\.guid), ["incoming-1"])

        f.h.webhook.onPost = nil
        f.h.store = FileStateStore(paths: f.paths)
        let b = try f.engine()
        _ = await f.poller(b).tick()
        let replay = await f.ingest(b, "🐦 request")
        XCTAssertEqual(replay, .delivered)
        XCTAssertEqual(try fileStore.load().cursorRowID, 1)
        XCTAssertEqual(f.h.webhook.idempotencyKeys, ["incoming-1", "incoming-1"])
        XCTAssertEqual(try f.payload(0)["idempotency_key"] as? String, "incoming-1")
        XCTAssertEqual(try f.payload(1)["idempotency_key"] as? String, "incoming-1")
    }

    func testDV22RouteSaveFailurePreventsPost() async throws {
        let f = try DoveFixture()
        let store = FailNextSaveStateStore(memory: f.h.state)
        f.h.store = store
        let e = try f.engine()
        _ = await f.poller(e).tick()
        store.failNextSave = true
        let result = await f.ingest(e, "🐦 x")
        XCTAssertEqual(result, .blocked)
        XCTAssertEqual(f.h.webhook.bodies.count, 0)
        let retry = await f.ingest(e, "🐦 x")
        XCTAssertEqual(retry, .delivered)
    }

    func testDV19BirdMarkerWarningRearms() async throws {
        let f = try DoveFixture()
        f.settings["reply_marker"] = "🕊️🐦"
        let e = try f.engine()
        _ = await f.poller(e).tick()
        _ = await f.ingest(e, "🐦 x")
        XCTAssertEqual(try f.provider.load().replyMarker, ReplyComposer.markerText)
        XCTAssertEqual(f.h.log.records.filter { $0.code == "reply_marker_invalid" }.count, 1)
        f.settings["reply_marker"] = "🕊️"
        try f.write()
        _ = await f.ingest(e, "ordinary text", id: 2)
        XCTAssertEqual(try f.provider.load().replyMarker, "🕊️")
        f.settings["reply_marker"] = "🐦"
        try f.write()
        _ = await f.ingest(e, "ordinary text", id: 3)
        XCTAssertEqual(f.h.log.records.filter { $0.code == "reply_marker_invalid" }.count, 2)
    }
}
